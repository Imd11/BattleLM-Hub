#!/usr/bin/env node
// qwen-bridge.mjs — BattleLM ↔ Qwen Code CLI bridge
//
// Protocol (identical to claude-bridge.mjs):
//   stdin  ← JSON line: { prompt, cwd, model }
//   stdout → JSON lines: { type, content, ... }
//
// Qwen CLI stream-json output is Claude-compatible:
//   {"type":"system","subtype":"init","session_id":"..."}
//   {"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}
//   {"type":"result","result":"..."}
//
// This bridge re-emits them as the simplified BattleLM protocol:
//   {"type":"text_delta","content":"..."}
//   {"type":"done"}

import { createInterface } from "readline";
import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { spawn } from "child_process";
import { homedir } from "os";

function emit(obj) {
    process.stdout.write(JSON.stringify(obj) + "\n");
}

// ---------- PATH 扩展（复制自 claude-bridge.mjs）----------

function getExtendedPath() {
    const home = homedir();
    const sep = ":";
    const paths = [process.env.PATH || ""];

    paths.push("/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin");
    paths.push(join(home, ".npm-global", "bin"));
    paths.push(join(home, ".yarn", "bin"));
    paths.push(join(home, ".local", "bin"));
    paths.push(join(home, ".volta", "bin"));

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

    if (process.env.FNM_MULTISHELL_PATH) {
        paths.push(process.env.FNM_MULTISHELL_PATH);
    } else if (process.env.FNM_DIR) {
        paths.push(process.env.FNM_DIR);
    } else {
        paths.push(join(home, ".fnm"));
    }

    const asdfDir = process.env.ASDF_DATA_DIR || process.env.ASDF_DIR;
    if (asdfDir) {
        paths.push(join(asdfDir, "shims"));
        paths.push(join(asdfDir, "bin"));
    }
    paths.push(join(home, ".asdf", "shims"));
    paths.push(join(home, ".asdf", "bin"));
    paths.push(join(home, ".docker", "bin"));

    return paths.filter(Boolean).join(sep);
}

// ---------- 查找 qwen 可执行文件 ----------

function findQwenPath(extendedPath) {
    const home = homedir();
    const candidates = [
        join(home, ".npm-global/bin/qwen"),
        join(home, ".local/bin/qwen"),
        "/usr/local/bin/qwen",
        "/opt/homebrew/bin/qwen",
    ];
    for (const dir of extendedPath.split(":")) {
        if (dir) candidates.push(join(dir, "qwen"));
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
    } = request;

    if (!prompt) {
        emit({ type: "error", content: "Missing 'prompt' field" });
        process.exit(1);
    }

    // 构建扩展 PATH
    const extendedPath = getExtendedPath();
    const qwenPath = findQwenPath(extendedPath);

    if (!qwenPath) {
        emit({ type: "error", content: "Qwen CLI not found. Install: npm install -g @qwen-code/qwen-code@latest" });
        process.exit(1);
    }

    emit({ type: "info", content: `qwen: ${qwenPath}` });

    // Qwen CLI stream-json + include-partial-messages 模式（逐 token 流式）
    const args = ["-p", prompt, "--output-format", "stream-json", "--include-partial-messages", "--yolo"];
    if (model) args.push("--model", model);

    return new Promise((resolve, reject) => {
        const child = spawn(qwenPath, args, {
            cwd,
            env: { ...process.env, PATH: extendedPath },
            stdio: ["pipe", "pipe", "pipe"],
        });

        let buffer = "";

        child.stdout.on("data", (chunk) => {
            buffer += chunk.toString();
            let newlineIdx;
            while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
                const line = buffer.slice(0, newlineIdx).trim();
                buffer = buffer.slice(newlineIdx + 1);

                if (!line) continue;
                try {
                    const obj = JSON.parse(line);

                    switch (obj.type) {
                        case "system":
                            if (obj.subtype === "init" && obj.session_id) {
                                emit({
                                    type: "session_init",
                                    sessionId: obj.session_id,
                                    model: obj.model || "",
                                });
                            }
                            break;

                        // --include-partial-messages 产生的逐 token 增量事件
                        case "stream_event":
                            if (obj.event?.type === "content_block_delta") {
                                const delta = obj.event.delta;
                                if (delta?.type === "text_delta" && delta.text) {
                                    emit({ type: "text_delta", content: delta.text });
                                } else if (delta?.type === "thinking_delta" && delta.thinking) {
                                    emit({ type: "thinking_delta", content: delta.thinking });
                                }
                            }
                            break;

                        case "assistant":
                            // 有 stream_event 增量后，assistant 块里的 text 不再重复发送
                            // 只处理 tool_use 等非文本内容
                            if (obj.message?.content && Array.isArray(obj.message.content)) {
                                for (const block of obj.message.content) {
                                    if (block.type === "tool_use") {
                                        emit({
                                            type: "tool_use",
                                            name: block.name || "tool",
                                            id: block.id || "",
                                        });
                                    }
                                }
                            }
                            break;

                        case "result":
                            break;

                        case "error":
                            emit({ type: "error", content: obj.error || obj.message || "unknown" });
                            break;
                    }
                } catch {
                    // Non-JSON line, ignore
                }
            }
        });

        child.stderr.on("data", (chunk) => {
            const text = chunk.toString().trim();
            if (text) console.error("[Qwen STDERR]", text);
        });

        child.on("close", (code) => {
            emit({ type: "done" });
            resolve();
        });

        child.on("error", (err) => {
            emit({ type: "error", content: err.message });
            emit({ type: "done" });
            resolve();
        });
    });
}

main().catch((err) => {
    emit({ type: "error", content: err.message || String(err) });
    emit({ type: "done" });
    process.exit(1);
});
