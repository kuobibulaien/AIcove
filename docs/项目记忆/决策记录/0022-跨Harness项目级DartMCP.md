---
status: accepted
date: 2026-09-12
---

# 跨 Harness 项目级 Dart MCP

## 背景

用户要求把官方 Dart MCP 变为项目级能力，供所有 harness 调用并更新项目文档。各宿主的自动发现文件不同，单一 `.mcp.json` 无法覆盖所有客户端。

## 决定

- 复用项目 SDK 和官方 stdio MCP，提供唯一启动脚本；客户端配置只适配发现格式，不复制服务实现，不改全局配置或应用业务依赖。
- Claude 与 Pi 共用根 `.mcp.json`，其它已配置宿主使用自己的项目入口；Pi 使用已有的 `pi-mcp-adapter`，项目覆盖只放 Pi 专属参数。
- 提供 Python 标准库命令行客户端，使只有 shell 工具的 harness 也能枚举和调用相同的 MCP；批次保留连接状态，不伪造原生工具注入。
- 继续保留 Mac Debug 会话脚本的管理责任和 Release 日志通道。调用命令与连接细节维护于 [DIAGNOSTICS.md](../../../apps/aicove_flutter/tool/DIAGNOSTICS.md#dart-mcp)；何时热重载／热重启、构建／安装及各类验收证据的边界唯一遵循根 [README.md 项目宪法第 7 条](../../../README.md)，AGENTS 与记忆总览只提供入口。

## 代价与回滚

需要维护少量宿主发现配置；宿主本身必须支持 stdio MCP 或允许 shell，不能保证任意远程／封闭 harness 自动读取本地文件。已有会话按宿主能力重新加载，新机器仍需项目 SDK 及对应适配器。

回滚只撤销本次新增的 `dart` 配置、两个工具脚本、`flutterw --dart` 分支和文档改动；保留其它 MCP、全局设置、用户工作树和运行中的应用。原文件局部基线位于本机 `.codex-temp/dart-mcp/before/`，不可整文件恢复覆盖后续任务。

## 验收门

分别验证配置发现、实际 stdio 握手与工具调用，再连接已有 AIcove 验证异常和组件树；不使用进程存活或工具列表代替真实应用连接。当前结果与未覆盖项见需求日志及 DIAGNOSTICS 对应章节。
