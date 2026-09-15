/**
 * 项目记忆扩展（Pi）：与 Claude Code / Codex 共用 hooks/memory.py。
 *
 * - 会话内第一次提问时，把 docs/项目记忆/README.md 与最近需求注入上下文（一次即可）。
 * - 每次提问把用户原话追加到 docs/项目记忆/需求日志.md。
 *
 * 脚本失败或 python3 不存在时静默，不影响 Pi。
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const SCRIPT = join("hooks", "memory.py");

function runMemory(cwd: string, mode: "start" | "prompt", payload?: object): string | undefined {
  if (!existsSync(join(cwd, SCRIPT))) return undefined;
  try {
    const res = spawnSync("python3", [SCRIPT, mode, "--agent", "pi"], {
      cwd,
      input: payload ? JSON.stringify(payload) : "",
      encoding: "utf8",
      timeout: 10_000,
    });
    if (res.status !== 0 || !res.stdout) return undefined;
    const parsed = JSON.parse(res.stdout);
    return parsed?.hookSpecificOutput?.additionalContext;
  } catch {
    return undefined;
  }
}

export default function (pi: any) {
  let injected = false;

  pi.on("session_start", () => {
    injected = false;
  });

  pi.on("before_agent_start", (event: any, ctx: any) => {
    const cwd: string = ctx?.cwd || process.cwd();
    const prompt = typeof event?.prompt === "string" ? event.prompt : "";
    if (prompt.trim()) runMemory(cwd, "prompt", { prompt });

    if (injected) return;
    const context = runMemory(cwd, "start");
    if (!context) return;
    injected = true;
    return {
      message: {
        customType: "project-memory",
        content: context,
        display: false,
      },
    };
  });
}
