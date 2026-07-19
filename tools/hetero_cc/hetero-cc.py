#!/usr/bin/env python3
"""异模型 Claude Code 子代理启动器。

从 cc-switch 数据库读取指定供应商配置，以完全隔离的方式启动一个 headless
Claude Code 子进程（进程级环境变量 + 独立 CLAUDE_CONFIG_DIR），不触碰主配置。

隔离原理（缺一不可）：
1. 供应商的 env（ANTHROPIC_BASE_URL / AUTH_TOKEN / 模型别名映射）只注入子进程；
2. CLAUDE_CONFIG_DIR 指向 ~/.hetero-cc/<供应商>/ 的独立目录——没有官方 OAuth
   凭据可回落，子进程只能走环境变量指定的端点（否则会静默回落到主账号，见
   scratch/diagnostics/ 相关记录：2026-07-07 曾因此出现假阳性）。

用法：
  hetero-cc.py <供应商名> <prompt 或 @方案文件> [选项]

选项：
  --cwd <dir>            施工工作目录（默认当前目录）
  --model <name>         覆盖模型（默认用供应商配置里的别名映射）
  --timeout <sec>        超时秒数，默认 600
  --json                 输出 --output-format json（含真实 modelUsage 记账）
  --permission-mode <m>  acceptEdits(默认) | bypassPermissions | default | plan
  --dry-run              只打印将执行的命令与注入的 env 键名，不实际启动
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

DB_PATH = Path.home() / ".cc-switch" / "cc-switch.db"
ISOLATED_ROOT = Path.home() / ".hetero-cc"


def load_provider_env(name: str) -> dict:
    if not DB_PATH.exists():
        sys.exit(f"错误：找不到 cc-switch 数据库 {DB_PATH}")
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    row = conn.execute(
        "SELECT settings_config FROM providers WHERE name=? AND app_type='claude'",
        (name,),
    ).fetchone()
    conn.close()
    if not row:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        names = [r[0] for r in conn.execute(
            "SELECT name FROM providers WHERE app_type='claude'")]
        conn.close()
        sys.exit(f"错误：供应商 '{name}' 不存在。可用：{', '.join(names)}")
    cfg = json.loads(row[0])
    env = cfg.get("env", {})
    if "ANTHROPIC_BASE_URL" not in env:
        sys.exit(f"错误：供应商 '{name}' 配置中没有 ANTHROPIC_BASE_URL，无法隔离调用")
    return env


def ensure_isolated_config(provider: str) -> Path:
    cfg_dir = ISOLATED_ROOT / provider
    cfg_dir.mkdir(parents=True, exist_ok=True)
    marker = cfg_dir / ".claude.json"
    if not marker.exists():
        marker.write_text('{"hasCompletedOnboarding": true}\n')
    return cfg_dir


def main() -> None:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("provider")
    ap.add_argument("prompt", help="prompt 文本，或 @路径 读取方案文件")
    ap.add_argument("--cwd", default=".")
    ap.add_argument("--model", default=None)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--permission-mode", default="acceptEdits",
                    choices=["acceptEdits", "bypassPermissions", "default", "plan"])
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    prompt = args.prompt
    if prompt.startswith("@"):
        plan_file = Path(prompt[1:])
        if not plan_file.is_file():
            sys.exit(f"错误：方案文件不存在 {plan_file}")
        prompt = plan_file.read_text()

    provider_env = load_provider_env(args.provider)
    cfg_dir = ensure_isolated_config(args.provider)

    env = dict(os.environ)
    env.update(provider_env)
    env["CLAUDE_CONFIG_DIR"] = str(cfg_dir)
    # 主账号凭据类变量一律清除，防止回落
    for k in ("ANTHROPIC_API_KEY",):
        if k not in provider_env:
            env.pop(k, None)

    cmd = ["claude", "-p", prompt, "--permission-mode", args.permission_mode]
    if args.model:
        cmd += ["--model", args.model]
    if args.json:
        cmd += ["--output-format", "json"]

    if args.dry_run:
        shown = cmd.copy()
        shown[2] = f"<prompt {len(prompt)} 字符>"
        print("命令:", " ".join(shown))
        print("工作目录:", str(Path(args.cwd).resolve()))
        print("CLAUDE_CONFIG_DIR:", env["CLAUDE_CONFIG_DIR"])
        print("注入的供应商 env 键:", ", ".join(sorted(provider_env)))
        print("超时:", args.timeout, "秒")
        return

    try:
        r = subprocess.run(cmd, cwd=args.cwd, env=env, timeout=args.timeout)
        sys.exit(r.returncode)
    except subprocess.TimeoutExpired:
        sys.exit(f"错误：施工超时（{args.timeout} 秒），按失败处理，请核对 git 基线")
    except FileNotFoundError:
        sys.exit("错误：找不到 claude 命令，请确认 PATH")


if __name__ == "__main__":
    main()
