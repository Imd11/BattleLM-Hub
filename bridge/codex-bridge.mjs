#!/usr/bin/env node
// codex-bridge.mjs — BattleLM ↔ Codex Agent SDK bridge
//
// Protocol (same as claude-bridge.mjs):
//   stdin  ← JSON line: { prompt, cwd, model, sessionId }
//   stdout → JSON lines: { type, content, ... }
//
// Lifecycle:
//   1. BattleLM spawns: /bin/zsh -lc "node codex-bridge.mjs"
//   2. BattleLM writes a JSON request to stdin, then closes stdin
//   3. Bridge streams events to stdout
//   4. Bridge exits when done

import { Codex } from "@openai/codex-sdk";
import { createInterface } from "readline";
import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// ---------- Helpers ----------

function emit(obj) {
    process.stdout.write(JSON.stringify(obj) + "\n");
}

// ---------- 扩展 PATH ----------

function getExtendedPath() {
    const home = homedir();
    const sep = ":";
    const paths = [process.env.PATH || ""];

    paths.push("/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin");
    paths.push(join(home, ".npm-global", "bin"));
    paths.push(join(home, ".yarn", "bin"));
    paths.push(join(home, ".local", "bin"));
    paths.push(join(home, ".volta", "bin"));
    paths.push(join(home, ".cargo", "bin")); // codex CLI 是 Rust 写的

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

    return paths.filter(Boolean).join(sep);
}

// ---------- 查找 codex 可执行文件 ----------

function findCodexExecutable(extendedPath) {
    const home = homedir();
    const candidates = [
        join(home, ".npm-global", "bin", "codex"),
        join(home, ".local", "bin", "codex"),
        join(home, ".cargo", "bin", "codex"),
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    ];
    // 也从 PATH 搜
    const pathDirs = extendedPath.split(":");
    for (const dir of pathDirs) {
        if (dir) candidates.push(join(dir, "codex"));
    }
    const seen = new Set();
    for (const p of candidates) {
        if (seen.has(p)) continue;
        seen.add(p);
        if (existsSync(p)) return p;
    }
    return undefined;
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
        reasoningEffort,
        sessionId,
    } = request;

    if (!prompt) {
        emit({ type: "error", content: "Missing 'prompt' field" });
        process.exit(1);
    }

    const extendedPath = getExtendedPath();

    // 查找系统安装的 codex 可执行文件
    // SDK 自带的 findCodexPath() 只在 node_modules 里找 @openai/codex 包，
    // 找不到全局安装的 codex；这里手动查找并通过 codexPathOverride 传入。
    const codexPath = findCodexExecutable(extendedPath);
    if (codexPath) {
        emit({ type: "info", content: `codex: ${codexPath}` });
    }

    // 构建 Codex 客户端
    const codexOptions = {
        env: {
            ...process.env,
            PATH: extendedPath,
        },
    };
    if (codexPath) {
        codexOptions.codexPathOverride = codexPath;
    }

    const codex = new Codex(codexOptions);

    // 创建或恢复 thread
    let thread;
    if (sessionId) {
        thread = codex.resumeThread(sessionId);
    } else {
        const threadOptions = {
            workingDirectory: cwd,
            skipGitRepoCheck: true,
        };
        if (model) threadOptions.model = model;
        if (reasoningEffort) threadOptions.modelReasoningEffort = reasoningEffort;
        // Auto-approve all actions/tools (Codex CLI approval_policy="never")
        threadOptions.approvalPolicy = "never";
        thread = codex.startThread(threadOptions);
    }

    // 发送 session init
    emit({
        type: "session_init",
        sessionId: thread.id || "",
        model: model || "",
    });

    try {
        const { events } = await thread.runStreamed(prompt);

        // 跟踪每个 item 已发送的文本长度，用于计算增量 delta
        const itemTextSent = new Map();

        for await (const event of events) {
            // 调试：打印原始事件到 stderr（不影响 stdout JSON 协议）
            console.error("[codex-bridge] event:", JSON.stringify(event));

            switch (event.type) {
                case "thread.started":
                    if (event.thread_id) {
                        emit({
                            type: "session_init",
                            sessionId: event.thread_id,
                            model: "",
                        });
                    }
                    break;

                case "item.started":
                    // item 开始，初始化已发送长度
                    if (event.item) {
                        itemTextSent.set(event.item.id, 0);
                    }
                    break;

                case "item.updated":
                    // 增量更新：text 字段是累积的完整文本，只发送新增的 delta 部分
                    if (event.item) {
                        const item = event.item;
                        if (item.type === "agent_message" && item.text) {
                            const sent = itemTextSent.get(item.id) || 0;
                            if (item.text.length > sent) {
                                const delta = item.text.slice(sent);
                                emit({ type: "text_delta", content: delta });
                                itemTextSent.set(item.id, item.text.length);
                            }
                        } else if (item.type === "command_execution" && item.aggregated_output) {
                            // 命令执行输出也增量显示
                            const key = item.id + "_cmd";
                            const sent = itemTextSent.get(key) || 0;
                            if (item.aggregated_output.length > sent) {
                                const delta = item.aggregated_output.slice(sent);
                                emit({ type: "text_delta", content: delta });
                                itemTextSent.set(key, item.aggregated_output.length);
                            }
                        }
                    }
                    break;

                case "item.completed":
                    // 完成的 item — 发送未发送的剩余文本（如果有）
                    if (event.item) {
                        const item = event.item;
                        if (item.type === "agent_message" && item.text) {
                            const sent = itemTextSent.get(item.id) || 0;
                            if (item.text.length > sent) {
                                const delta = item.text.slice(sent);
                                emit({ type: "text_delta", content: delta });
                            }
                        } else if (item.type === "function_call" || item.type === "command_execution") {
                            emit({
                                type: "tool_use",
                                name: item.type === "command_execution" ? (item.command || "shell") : (item.name || "tool"),
                                id: item.call_id || item.id || "",
                            });
                        } else if (item.type === "function_call_output") {
                            const content = typeof item.output === "string"
                                ? item.output
                                : JSON.stringify(item.output);
                            emit({
                                type: "tool_result",
                                id: item.call_id || "",
                                content: content.slice(0, 2000),
                            });
                        }
                    }
                    break;

                case "turn.completed":
                    emit({
                        type: "result",
                        cost: 0,
                        durationMs: 0,
                        inputTokens: event.usage?.input_tokens || 0,
                        outputTokens: event.usage?.output_tokens || 0,
                    });
                    break;

                case "turn.failed":
                    emit({
                        type: "error",
                        content: event.error?.message || "Turn failed",
                    });
                    break;

                case "error":
                    emit({
                        type: "error",
                        content: event.error?.message || event.message || "Unknown Codex error",
                    });
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
