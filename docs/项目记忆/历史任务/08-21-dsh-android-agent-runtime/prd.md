# AIcove 2.0：以 DeepSeek Harness 为核心的 Agent 运行时

## Goal

把 AIcove 的 Agent 底层升级为官方 DeepSeek Harness：先让 Android 客户端在设备本地运行 DSH，再把聊天、主动消息、记忆、多模态和后台 Agent 分阶段迁移成 Cordis 插件或宿主能力，最终退役平行的自研 Agent 核心。总体方案见 `apps/aicove_flutter/docs/02_前后端分离与架构规范/AIcove2.0_DSH驱动底层架构改造方案.md`。

## Confirmed Facts

- DSHM 已证明 Android 可以通过 Termux arm64 用户空间、Node.js 和兼容补丁运行原版 `@deepseek-ai/dsh`。
- Harness 编排、会话、插件、文件和 Shell 工具需要在设备本地运行；模型推理允许继续调用云端 API。
- 权限能力不以“最少权限”为目标，可以提供无 Root、ADB 增强和 Root 三档，并在低权限设备上自动降级。
- 本项目当前客户端是 Flutter，已有 Agent Runtime、Provider、插件和 Android 前台保活能力，不能把现有产品能力一次性丢失。
- AIcove 2.0 是最终全量替换目标，但实施采用可回滚的聊天垂直切片起步，不做一次性大爆炸切换。

## Requirements

- R1：Android 客户端必须启动真实的官方 DeepSeek Harness，不以仿写 Agent loop 冒充 Harness 兼容。
- R2：运行时必须包含 Harness 所需的 Node.js、Shell、文件搜索、Git、插件安装和持久化目录能力。
- R3：权限能力按运行时探测分级：应用沙箱基础档、ADB/系统授权增强档、Root 完整档；高档不可用时自动回落到低档。
- R4：Root 和 ADB 权限是可选增强能力，不能成为应用首次启动和基本对话的硬依赖。
- R5：Harness 生命周期、安装进度、日志、健康状态和权限能力必须能被 Flutter UI 管理与展示。
- R6：现有 Aicove 的联系人、聊天记录、模型渠道、主动消息、记忆、TTS、图片和表情包能力必须有明确的保留或迁移路径。
- R7：Harness/Cordis 插件与 Aicove 现有 Dart 插件不得长期形成两套互不相通的公共插件模型。
- R8：设备兼容采用能力检测和降级，不按单一品牌、Root 状态或固定 ROM 写死。
- R9：运行时、插件和权限状态需要可升级、可校验、可回滚，升级失败不能破坏已有会话与工作区。
- R10：Android 之外的平台必须有明确策略；不支持纯本地 DSH 时要显式降级，不能伪装成同构 Runtime。
- R11：DSH 内部协议不得直接泄漏到 Flutter；所有交互必须经过版本化 `aicove.bridge.v1`。
- R12：DSH SessionEvent 与 Drift product message 的所有权、绑定、投影、分支和恢复语义必须先形成 ADR，再修改数据库 schema。

## Acceptance Criteria

- [x] 第一阶段采用“真实 DSH + 现有 Flutter UI + 一个设备能力 + 旧链路回滚”的聊天垂直切片。
- [ ] 一台无 Root 的 arm64 Android 设备可以安装运行时、启动 Harness，并通过本地端口完成一次真实 Agent 对话与工具调用。
- [ ] 同一构建能识别并展示基础、ADB 增强、Root 三档能力；缺失高档权限时基础功能仍可用。
- [ ] Harness 重启或应用升级后，会话、配置、插件和工作区保持可用。
- [ ] 至少一个现有 Aicove 能力通过正式桥接或 Harness 插件接入，而不是复制一条独立调用链。
- [ ] Flutter 能展示安装、启动、停止、健康、日志和权限档位，并能恢复异常状态。
- [ ] 形成 Android 架构、权限矩阵、迁移顺序、验证方案和回滚方案；实现前由用户审核。
- [x] 形成 AIcove 2.0 总体架构改造文档并加入正式文档索引。

## 自主决策

- Android 先行，iOS 作为独立可行性课题：两端进程与可执行代码限制差异太大，强行共用底层会模糊边界。
- 采用“能力集合”而非单一 `isRoot` 布尔值：ADB、Shizuku、Root 和普通沙箱提供的权限并非严格线性包含关系。
- Flutter 只做产品宿主与管理界面，Harness 运行时由 Android 原生层管理：避免 Dart 生命周期直接持有长期 Node 进程。
- 优先对接官方 DSH 插件协议，Aicove 特有能力通过桥接插件进入 Harness：减少长期维护两套 Agent 核心。
- 在许可证方案确认前按 clean-room 方式参考 DSHM 架构，不直接复制其 GPL-3.0 源码：避免过早锁定整个客户端的分发许可。
- AIcove 2.0 最终只保留 DSH Agent 核心；双轨仅是迁移与回滚机制，不是长期产品架构。

## Out of Scope

- 当前规划阶段不修改生产功能代码、不发布 APK、不申请设备实际 Root/ADB 权限。
- 当前任务不承诺 iOS 与 Android 使用同一种本地运行时实现。

## Architecture Decision Gate

- 进入数据 schema 实施前，确认并接受“DSH SessionEvent 是 Agent 执行真相源、Drift raw message 是产品消息真相源”的双域分工，随后把对应 ADR 从 `proposed` 改为 `accepted`。
