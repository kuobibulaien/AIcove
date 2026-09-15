#!/usr/bin/env python3
"""Call the project Dart MCP from harnesses that only expose a shell tool.

No third-party dependencies. A batch shares one connection (including DTD state).
Only the MCP subprocess started here is stopped; attached apps are left running.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time


TOOL_DIR = Path(__file__).resolve().parent
PROJECT = TOOL_DIR.parent


class DartMcpClient:
    def __init__(self, command=None, cwd=None, timeout=120):
        self.timeout = timeout
        self.next_id = 0
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            command or [str(TOOL_DIR / "dart_mcp_server")],
            cwd=cwd or PROJECT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            start_new_session=True,
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except (ValueError, OSError) as error:
            self.messages.put(error)
        finally:
            self.messages.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"MCP request timed out: {method}")
            try:
                message = self.messages.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(f"MCP request timed out: {method}") from error
            if message is None:
                raise RuntimeError("MCP server closed stdout unexpectedly")
            if isinstance(message, Exception):
                raise RuntimeError("Invalid MCP stdout; expected JSON lines") from message
            if "method" in message:
                if "id" not in message:
                    continue
                if message["method"] == "roots/list":
                    self.send({"id": message["id"], "result": {
                        "roots": [{"uri": PROJECT.as_uri(), "name": "AIcove Flutter"}]
                    }})
                elif message["method"] == "ping":
                    self.send({"id": message["id"], "result": {}})
                else:
                    self.send({"id": message["id"], "error": {
                        "code": -32601, "message": "Unsupported client method"
                    }})
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"], ensure_ascii=False))
                return message["result"]

    def initialize(self):
        result = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {"roots": {"listChanged": False}},
            "clientInfo": {"name": "aicove-dart-mcp-client", "version": "1.0.0"},
        })
        self.send({"method": "notifications/initialized"})
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Check handshake and required tools")
    mode.add_argument("--list-tools", action="store_true", help="Print tool names and input schemas")
    mode.add_argument("--call", metavar="NAME", help="Call one tool")
    mode.add_argument("--batch", metavar="JSON", help="Call [{name,arguments},...] on one connection")
    parser.add_argument("--args", default="{}", help="JSON tool arguments for --call")
    parser.add_argument("--timeout", type=float, default=120, help="Per-request timeout in seconds")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    calls = []
    if args.call or args.batch:
        calls = json.loads(args.batch) if args.batch else [
            {"name": args.call, "arguments": json.loads(args.args)}
        ]
        if not isinstance(calls, list) or not calls or any(
            not isinstance(call, dict) or not isinstance(call.get("name"), str)
            or not isinstance(call.get("arguments", {}), dict) for call in calls
        ):
            parser.error("Expected a nonempty array of {name, arguments} tool calls")
    client = DartMcpClient(timeout=args.timeout)
    try:
        info = client.initialize()
        if args.check or args.list_tools:
            result = client.request("tools/list")
            if args.check:
                names = {tool["name"] for tool in result["tools"]}
                required = {"analyze_files", "get_runtime_errors", "hot_reload", "widget_inspector", "dtd"}
                if missing := required - names:
                    raise RuntimeError(f"Missing tools: {sorted(missing)}")
                result = {"ok": True, "server": info["serverInfo"], "toolCount": len(names),
                          "requiredTools": sorted(required), "appConnected": False}
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            for call in calls:
                result = client.request("tools/call", call)
                print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
                if result.get("isError"):
                    return 1
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, RuntimeError, TimeoutError) as error:
        print(f"Dart MCP: {error}", file=sys.stderr)
        sys.exit(1)
