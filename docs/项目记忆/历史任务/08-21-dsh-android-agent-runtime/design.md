# AIcove 2.0 DSH Agent Runtime 技术设计（草案）

## Status

规划中。第一阶段已确定为可回滚聊天垂直切片；数据真相源分工仍需在 schema 实施前接受 ADR。完整总体设计以 `apps/aicove_flutter/docs/02_前后端分离与架构规范/AIcove2.0_DSH驱动底层架构改造方案.md` 为准，本文保留实现摘要。

## Architecture

```text
Flutter Aicove
  UI / Contact / Drift / Delivery / Device Capability
             |
             | MethodChannel: install/start/status/log/permission
             | WebSocket JSON-RPC: agent/session/stream/tool bridge
             v
Android Harness Host (Kotlin foreground service)
  RuntimeInstaller | RuntimeSupervisor | CapabilityResolver
  AppBackend | ShizukuBackend | RootBackend
             |
             | ProcessBuilder + authenticated localhost bridge
             v
Termux arm64 runtime
  Node 22 + pnpm + bash + rg + git + optional proot rootfs
             |
             v
Official @deepseek-ai/dsh + versioned Android patch set
  aicove profile + @aicove/dsh-bridge Cordis plugin
```

## Runtime distribution

- Runtime builder 放在 `apps/aicove_flutter/android/runtime-builder/`，保持在项目宪法允许修改的 Flutter 目录内。
- CI 构建固定 DSH、Node、Termux bootstrap、NDK 和 patch-set 版本。
- 原生可执行文件放入 APK `jniLibs/arm64-v8a`，大体积 JS/Linux 用户空间作为单独签名 runtime bundle。
- runtime manifest 包含 bundle version、DSH version、Node ABI、Android API floor、ABI、文件清单、SHA-256 和 Ed25519 签名。
- 安装使用 A/B 两个运行时槽：新版本解压、自检成功后切换 active pointer；失败回退旧槽。
- `DSH_HOME`、workspace、凭据和 session 数据不放在版本槽内，升级时保留。

## Android host

新增独立 `HarnessRuntimeService`，而不是让 Flutter Activity 持有 Node 进程：

- 前台通知显示安装、启动、运行、异常和停止。
- `RuntimeSupervisor` 负责一次只运行一个 DSH 实例、捕获 stdout/stderr、健康探测、退出码和受控重启。
- `RuntimeInstaller` 负责下载、签名/哈希校验、空间检查、安全解压、A/B 切换和回滚。
- Flutter 通过 `HarnessRuntimeContract` 获取状态流，不直接调用 `ProcessBuilder`。
- 现有 `PersistentGuardService` 与 Harness Service 最终合并为一个可解释的前台运行服务，首个垂直切片可先并存以降低改动风险。

## DSH profile and bridge

不把 DSH WebUI 当作 Aicove 的主 UI。创建 `aicove` profile：

- 复用官方 dsh-base 的 agent loop、session、tools、compaction、skills、subagent 等能力。
- 安装 `@aicove/dsh-bridge` Cordis 插件，提供版本化的 `aicove.bridge.v1` 协议。
- Flutter 创建/恢复联系人对应的 DSH session，发送 inbox input，订阅流式 session events。
- 插件把 DSH `SessionEvent` 投影为稳定的 `AgentOutputEvent`，屏蔽上游内部 RPC 变化。
- 可保留官方 Web profile 作为诊断入口，但它不是产品主链路。

## Capability routing

权限与 Linux 用户空间分开探测：

```text
Linux: Termux -> optional proot distro
Privilege: app UID -> optional Shizuku shell UID -> optional root UID
```

- 默认 DSH workspace/bash/fs 使用 AppBackend，确保无任何增强权限也能运行。
- ShizukuBackend 通过 UserService/AIDL 提供 shell-UID 命令和系统 Binder 能力。
- RootBackend 使用 libsu shell/RootService。
- DSH 插件注册显式的 Android capability tools；用户启用“完整控制模式”后，bash provider 才可整体路由到更高权限后端。
- 每次调用记录实际 backend、UID、SELinux context、退出码和降级原因；不记录密钥。

## Bridge protocols

### Flutter -> Android

MethodChannel/EventChannel：

- `runtime.install/update/rollback/uninstall`
- `runtime.start/stop/restart/status/logs`
- `capabilities.probe/request/openSettings`
- `workspace.select/grant/status`

### Flutter -> DSH

WebSocket JSON-RPC：

- `agent.createOrResume`
- `agent.send/cancel`
- `session.subscribe/replay/fork`
- `settings.get/set`
- `plugin.list/install/enable/disable`

### DSH -> Android/Flutter capabilities

本机认证 RPC：

- `exec.run/cancel`
- `device.capabilities`
- `aicove.memory.search/writeCandidate`
- `aicove.output.tts/image/sticker/notification`
- `aicove.conversation.deliver`

每个协议都有独立版本号和 feature negotiation，避免 DSH runtime 与 APK 升级时直接崩溃。

## Data ownership（架构决策门）

推荐：

- DSH SessionEvent log 是 Agent 执行与模型可见历史的真相源。
- Drift DB 是联系人、产品消息、多模态投递和同步的真相源。
- 显式 binding + projection cursor 保证幂等，不做隐式双向全量同步。

旧聊天首次迁移只 seed 一次；之后编辑、重发、删除通过 bridge 创建 DSH 分支/事件，再更新 Drift 投影。

## Compatibility

- Flutter App 继续保持现有 Android 支持面；Harness 功能在 Android API 24+、arm64-v8a 上启用。
- Android 11+ 可在设备内启动 Shizuku；更低版本需要电脑 ADB 或 Root；均不可用时退回 AppBackend。
- `node-pty`、proot、Shizuku、Root 分别降级；核心对话不依赖其中任何一个。
- 上游 DSH 每次升级都先在 runtime CI 运行 Android smoke matrix，patch 断言不匹配即阻止发布。

## Rollback

- 功能旗标保留旧 `StandardChatAgentRuntime -> ChatSendUseCase` 链路，直到 DSH 垂直切片验收完成。
- Runtime A/B 槽允许回退上一版 DSH。
- DSH session 与 Drift binding 可禁用但不删除；旧 DB 消息不做破坏性迁移。
- Root/Shizuku 后端失败立即回落 AppBackend，不能导致 Harness 服务退出。

## Open design decision

1. 在 Phase 2 数据 migration 前，正式接受 DSH log 与 Drift DB 的双域真相源分工，并同步修订现行聊天上下文规范。
