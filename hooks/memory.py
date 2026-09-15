#!/usr/bin/env python3
"""项目记忆 hook：所有 agent 共用的一个脚本。

  memory.py start  [--agent NAME]   会话开始：把 docs/项目记忆/README.md 与最近需求注入上下文
  memory.py prompt [--agent NAME]   用户提问：从 stdin 读 hook JSON，把原话追加到 docs/项目记忆/需求日志.md

stdin 为各平台 hook 的 JSON 载荷（Claude Code / Codex 同一格式；Pi 由 .pi/extensions/memory.ts 构造）。
stdout 为 JSON：{"hookSpecificOutput": {"hookEventName": ..., "additionalContext": ...}}，
Claude Code 与 Codex 都按此格式把 additionalContext 加进上下文；Pi 扩展自行读取该字段。
"""

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MEMORY_DIR = ROOT / "docs" / "项目记忆"
README = MEMORY_DIR / "README.md"
REQ_LOG = MEMORY_DIR / "需求日志.md"
STATE_DIR = Path.home() / ".cache" / "aicove-memory"

MAX_PROMPT_CHARS = 4000
MIN_PROMPT_CHARS = 4
RECENT_ENTRIES = 3

# 各平台塞进用户消息里的非用户文本，记录前剥掉
NOISE_TAGS = ("system-reminder", "ide_selection", "ide_opened_file", "command-message", "command-args", "task-notification")


def _utf8_streams() -> None:
    for name in ("stdin", "stdout", "stderr"):
        stream = getattr(sys, name, None)
        if stream and hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def _read_stdin_json() -> dict:
    if sys.stdin is None or sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def _emit(event_name: str, context: str) -> None:
    payload = {"hookSpecificOutput": {"hookEventName": event_name, "additionalContext": context}}
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _recent_entries(limit: int) -> str:
    if not REQ_LOG.exists():
        return ""
    text = REQ_LOG.read_text(encoding="utf-8")
    body = text.split("\n## 历史回溯", 1)[0]
    entries = re.split(r"\n(?=### \d{4}-\d{2}-\d{2})", body)
    entries = [e.strip().removesuffix("---").strip() for e in entries if e.strip().startswith("### ")]
    return "\n\n".join(entries[-limit:])


def cmd_start(agent: str) -> int:
    if not README.exists():
        return 0
    parts = [
        f"<project-memory agent=\"{agent}\" source=\"docs/项目记忆/README.md\">",
        README.read_text(encoding="utf-8").strip(),
    ]
    recent = _recent_entries(RECENT_ENTRIES)
    if recent:
        parts.append("\n## 最近需求（需求日志末几条）\n\n" + recent)
    parts.append(
        "\n提醒：本次若有实际改动，会话结束前按上面「写入规则」把需求日志的「结果：」行改成一句简短结果（纯问答不必补）；"
        "架构级决定写决策记录，非平凡 bug 写经验教训。"
    )
    parts.append("</project-memory>")
    _emit("SessionStart", "\n".join(parts))
    return 0


def _clean_prompt(text: str) -> str:
    for tag in NOISE_TAGS:
        text = re.sub(rf"<{tag}\b[^>]*>.*?</{tag}>", "", text, flags=re.S)
    text = re.sub(r"<command-name>.*?</command-name>", "", text, flags=re.S)
    return text.strip()


def _should_skip(text: str) -> bool:
    if len(text) < MIN_PROMPT_CHARS:
        return True
    if text.startswith("/") and "\n" not in text:
        return True
    if text.startswith("<") and text.endswith(">") and "\n" not in text:
        return True
    return False


def _dedup_hit(text: str) -> bool:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    marker = STATE_DIR / (hashlib.sha1(str(ROOT).encode()).hexdigest()[:12] + ".last")
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
    try:
        if marker.exists() and marker.read_text().strip() == digest:
            return True
        marker.write_text(digest)
    except Exception:
        pass
    return False


def cmd_prompt(agent: str) -> int:
    data = _read_stdin_json()
    prompt = data.get("prompt") or data.get("user_prompt") or data.get("input") or ""
    if not isinstance(prompt, str):
        return 0
    text = _clean_prompt(prompt)
    if _should_skip(text) or _dedup_hit(text):
        return 0
    if len(text) > MAX_PROMPT_CHARS:
        text = text[:MAX_PROMPT_CHARS] + f"\n…（已截断，原文 {len(text)} 字）"

    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    entry = f"\n### {stamp} · {agent}\n{text}\n结果：（待补）\n"

    if REQ_LOG.exists():
        content = REQ_LOG.read_text(encoding="utf-8")
        head, sep, tail = content.partition("\n## 历史回溯")
        if sep:
            head = head.rstrip("\n").removesuffix("---").rstrip("\n")
            content = head + "\n" + entry + "\n---\n" + sep + tail
        else:
            content = content.rstrip("\n") + "\n" + entry
    else:
        content = "# 需求日志\n" + entry
    REQ_LOG.write_text(content, encoding="utf-8")
    return 0


def main() -> int:
    _utf8_streams()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("start", "prompt"))
    parser.add_argument("--agent", default=os.environ.get("MEMORY_AGENT", "unknown"))
    args = parser.parse_args()
    try:
        return cmd_start(args.agent) if args.mode == "start" else cmd_prompt(args.agent)
    except Exception as exc:  # hook 永远不能拖垮宿主
        print(f"[memory.py] {exc}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
