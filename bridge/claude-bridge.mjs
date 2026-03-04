#!/usr/bin/env node
// claude-bridge.mjs — BattleLM ↔ Claude Agent SDK bridge
//
// Protocol:
//   stdin  ← JSON line: { prompt, cwd, model, sessionId }
//   stdout → JSON lines: { type, content, ... }
//
// Lifecycle:
//   1. BattleLM spawns: /bin/zsh -lc "node claude-bridge.mjs"
//   2. BattleLM writes a JSON request to stdin, then closes stdin
//   3. Bridge streams events to stdout
//   4. Bridge exits when done

import { query } from "@anthropic-ai/claude-agent-sdk";
import { createInterface } from "readline";
import { existsSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { spawn } from "child_process";
import { homedir } from "os";

// ---------- Helpers ----------

function emit(obj) {
    process.stdout.write(JSON.stringify(obj) + "\n");
}

// ---------- 核心：复制牛马AI的 getExtendedPath() ----------
// 确保 PATH 包含所有可能的 node/claude 安装位置

function getExtendedPath() {
    const home = homedir();
    const sep = ":";
    const paths = [process.env.PATH || ""];

    // 标准系统目录
    paths.push("/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin");

    // npm / yarn / pnpm 全局目录
    paths.push(join(home, ".npm-global", "bin"));
    paths.push(join(home, ".yarn", "bin"));

    // claude 专属目录
    paths.push(join(home, ".claude", "bin"));
    paths.push(join(home, ".claude", "local"));
    paths.push(join(home, ".local", "bin"));

    // volta
    paths.push(join(home, ".volta", "bin"));

    // nvm
    if (process.env.NVM_BIN) {
        paths.push(process.env.NVM_BIN);
    }
    const nvmVersions = join(home, ".nvm", "versions", "node");
    try {
        if (existsSync(nvmVersions)) {
            for (const ver of readdirSync(nvmVersions)) {
                paths.push(join(nvmVersions, ver, "bin"));
            }
        }
    } catch { }

    // fnm
    if (process.env.FNM_MULTISHELL_PATH) {
        paths.push(process.env.FNM_MULTISHELL_PATH);
    } else if (process.env.FNM_DIR) {
        paths.push(process.env.FNM_DIR);
    } else {
        paths.push(join(home, ".fnm"));
    }

    // asdf / mise (formerly rtx)
    const asdfDir = process.env.ASDF_DATA_DIR || process.env.ASDF_DIR;
    if (asdfDir) {
        paths.push(join(asdfDir, "shims"));
        paths.push(join(asdfDir, "bin"));
    }
    paths.push(join(home, ".asdf", "shims"));
    paths.push(join(home, ".asdf", "bin"));

    // docker
    paths.push(join(home, ".docker", "bin"));

    return paths.filter(Boolean).join(sep);
}

// ---------- 查找 claude 可执行文件 ----------

function findClaudePath() {
    const home = homedir();
    const candidates = [
        join(home, ".npm-global/bin/claude"),
        join(home, ".local/bin/claude"),
        join(home, ".claude/bin/claude"),
        join(home, ".claude/local/claude"),
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ];
    // 也从 PATH 搜
    const pathDirs = (process.env.PATH || "").split(":");
    for (const dir of pathDirs) {
        if (dir) candidates.push(join(dir, "claude"));
    }
    const seen = new Set();
    for (const p of candidates) {
        if (seen.has(p)) continue;
        seen.add(p);
        if (existsSync(p)) return p;
    }
    return undefined;
}

// ---------- 查找 node 可执行文件（复制牛马AI的 findNodeExecutable）----------

function findNodeExecutable(extendedPath) {
    const pathDirs = extendedPath.split(":");
    for (const dir of pathDirs) {
        if (!dir) continue;
        try {
            const nodePath = join(dir, "node");
            if (existsSync(nodePath)) return nodePath;
        } catch { }
    }
    return "node"; // fallback
}

// ---------- 自定义 spawn 函数（复制牛马AI的 createCustomSpawnFunction）----------

function createCustomSpawnFunction(extendedPath, stderrCallback) {
    return (request) => {
        let { command } = request;
        const { args, cwd, signal, env } = request;

        // 如果 command 是 "node"，尝试解析绝对路径
        if (command === "node") {
            const resolved = findNodeExecutable(extendedPath);
            if (resolved) command = resolved;
        }

        console.error(`[CustomSpawn] ${command} ${args.join(" ")}`);

        const child = spawn(command, args, {
            cwd,
            env,
            signal,
            stdio: ["pipe", "pipe", "pipe"],
            windowsHide: true,
        });

        if (!child.stdin || !child.stdout) {
            throw new Error("Failed to spawn Claude Code process");
        }

        if (child.stderr) {
            child.stderr.on("data", (chunk) => {
                const text = chunk.toString();
                if (stderrCallback) stderrCallback(text);
            });
        }

        return child;
    };
}

// ---------- Main ----------

async function main() {
    // 读取 stdin JSON 请求
    const lines = [];
    const rl = createInterface({ input: process.stdin });

    for await (const line of rl) {
        const trimmed = line.trim();
        if (trimmed) lines.push(trimmed);
    }

    if (lines.length === 0) {
        emit({ type: "error", content: "No input received" });
        process.exit(1);
    }

    let request;
    try {
        request = JSON.parse(lines[0]);
    } catch (e) {
        emit({ type: "error", content: `Invalid JSON: ${e.message}` });
        process.exit(1);
    }

    const {
        prompt,
        cwd = process.cwd(),
        model,
        sessionId,
        maxTurns = 200,
    } = request;

    if (!prompt) {
        emit({ type: "error", content: "Missing 'prompt' field" });
        process.exit(1);
    }

    // 查找 claude 路径
    const claudePath = findClaudePath();
    if (!claudePath) {
        emit({ type: "error", content: "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code" });
        process.exit(1);
    }

    // 构建扩展 PATH（复制牛马AI的做法）
    const extendedPath = getExtendedPath();

    // 构建环境（复制牛马AI的 buildEnvironment）
    const env = { ...process.env };
    env.PATH = extendedPath;
    delete env.CLAUDECODE; // 牛马AI也删除这个

    // 构建 SDK options
    const options = {
        cwd,
        maxTurns,
        pathToClaudeCodeExecutable: claudePath,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        includePartialMessages: true,
        settingSources: ["user", "project"],
        tools: { type: "preset", preset: "claude_code" },  // 关键! SDK 会传 --tools default
        env,
        // 核心：自定义 spawn 函数（复制牛马AI的 createCustomSpawnFunction）
        spawnClaudeCodeProcess: createCustomSpawnFunction(extendedPath, (text) => {
            if (text?.trim()) {
                console.error("[Claude STDERR]", text.trim());
            }
        }),
    };

    if (model) options.model = model;
    if (sessionId) options.resume = sessionId;

    emit({ type: "info", content: `claude: ${claudePath}` });

    try {
        const stream = query({ prompt, options });

        for await (const event of stream) {
            switch (event.type) {
                case "system":
                    if (event.subtype === "init" && event.session_id) {
                        emit({
                            type: "session_init",
                            sessionId: event.session_id,
                            model: event.model || "",
                        });
                    }
                    break;

                case "assistant":
                    // 注意: text 内容已通过 stream_event (text_delta) 增量提供
                    // 不再重复发送完整文本，否则会导致 accumulatedText 翻倍
                    if (event.message?.content && Array.isArray(event.message.content)) {
                        for (const block of event.message.content) {
                            if (block.type === "thinking" && block.thinking) {
                                emit({ type: "thinking", content: block.thinking });
                            } else if (block.type === "tool_use") {
                                emit({
                                    type: "tool_use",
                                    name: block.name || "tool",
                                    id: block.id || "",
                                });
                            }
                        }
                    }
                    if (event.error) {
                        emit({ type: "error", content: event.error });
                    }
                    break;

                case "stream_event":
                    // SDK 包装 BetaRawMessageStreamEvent 在 event.event 里
                    if (event.event?.type === "content_block_delta") {
                        const delta = event.event.delta;
                        if (delta?.type === "text_delta" && delta.text) {
                            emit({ type: "text_delta", content: delta.text });
                        } else if (delta?.type === "thinking_delta" && delta.thinking) {
                            emit({ type: "thinking_delta", content: delta.thinking });
                        }
                    }
                    break;

                case "result":
                    if (event.is_error && event.result) {
                        emit({ type: "error", content: event.result });
                    }
                    emit({
                        type: "result",
                        cost: event.total_cost_usd || 0,
                        durationMs: event.duration_ms || 0,
                        inputTokens: event.usage?.input_tokens || 0,
                        outputTokens: event.usage?.output_tokens || 0,
                    });
                    break;

                case "error":
                    emit({
                        type: "error",
                        content: event.error?.message || event.error || "Unknown error",
                    });
                    break;

                case "user":
                    if (event.tool_use_result !== undefined && event.tool_use_id) {
                        const content =
                            typeof event.tool_use_result === "string"
                                ? event.tool_use_result
                                : JSON.stringify(event.tool_use_result);
                        emit({
                            type: "tool_result",
                            id: event.tool_use_id,
                            content: content.slice(0, 2000),
                        });
                    }
                    break;
            }
        }
    } catch (error) {
        emit({
            type: "error",
            content: error.message || String(error),
        });
    }

    emit({ type: "done" });
}

main().catch((err) => {
    emit({ type: "error", content: err.message || String(err) });
    emit({ type: "done" });
    process.exit(1);
});
