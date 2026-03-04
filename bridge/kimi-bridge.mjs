#!/usr/bin/env node
// kimi-bridge.mjs — BattleLM ↔ Kimi Agent SDK bridge
//
// Protocol (identical to claude-bridge.mjs):
//   stdin  ← JSON line: { prompt, cwd, model }
//   stdout → JSON lines: { type, content, ... }

import { createSession } from "@moonshot-ai/kimi-agent-sdk";
import { createInterface } from "readline";
import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";

function emit(obj) {
    process.stdout.write(JSON.stringify(obj) + "\n");
}

// ---------- 复制自 claude-bridge.mjs 的 PATH 扩展 ----------

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

// ---------- 查找 kimi 可执行文件 ----------

function findKimiPath() {
    const home = homedir();
    const candidates = [
        join(home, ".local/bin/kimi"),
        join(home, ".npm-global/bin/kimi"),
        "/usr/local/bin/kimi",
        "/opt/homebrew/bin/kimi",
    ];
    const pathDirs = (process.env.PATH || "").split(":");
    for (const dir of pathDirs) {
        if (dir) candidates.push(join(dir, "kimi"));
    }
    const seen = new Set();
    for (const p of candidates) {
        if (seen.has(p)) continue;
        seen.add(p);
        if (existsSync(p)) return p;
    }
    return undefined;
}

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
    } = request;

    if (!prompt) {
        emit({ type: "error", content: "Missing 'prompt' field" });
        process.exit(1);
    }

    // 构建扩展 PATH
    const extendedPath = getExtendedPath();
    process.env.PATH = extendedPath;

    // 查找 kimi 可执行文件
    const kimiPath = findKimiPath();
    if (!kimiPath) {
        emit({ type: "error", content: "Kimi CLI not found. Install: curl -fsSL https://kimi.com/install.sh | bash" });
        process.exit(1);
    }

    emit({ type: "info", content: `kimi: ${kimiPath}` });

    let session;
    try {
        const sessionOpts = {
            workDir: cwd,
            yoloMode: true,
            executable: kimiPath,
            env: { ...process.env, PATH: extendedPath },
        };
        if (model) sessionOpts.model = model;

        session = createSession(sessionOpts);

        const turn = session.prompt(prompt);

        for await (const event of turn) {
            switch (event.type) {
                case "ContentPart":
                    if (event.payload?.type === "text" && event.payload.text) {
                        emit({ type: "text_delta", content: event.payload.text });
                    } else if (event.payload?.type === "think" && event.payload.think) {
                        emit({ type: "thinking_delta", content: event.payload.think });
                    }
                    break;

                case "ToolCall":
                    if (event.payload?.function?.name) {
                        emit({
                            type: "tool_use",
                            name: event.payload.function.name,
                            id: event.payload.id || "",
                        });
                    }
                    break;

                case "ToolResult":
                    emit({ type: "tool_result", id: event.payload?.tool_call_id || "" });
                    break;

                case "ApprovalRequest":
                    if (turn.approve) {
                        try {
                            await turn.approve(event.payload?.requestId || "", "approve");
                        } catch { }
                    }
                    break;

                default:
                    break;
            }
        }
    } catch (error) {
        emit({
            type: "error",
            content: error.message || String(error),
        });
    } finally {
        if (session) {
            try { await session.close(); } catch { }
        }
    }

    emit({ type: "done" });
}

main().catch((err) => {
    emit({ type: "error", content: err.message || String(err) });
    emit({ type: "done" });
    process.exit(1);
});
