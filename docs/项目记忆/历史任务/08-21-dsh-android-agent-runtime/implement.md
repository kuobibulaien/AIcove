# AIcove 2.0 实施计划

总设计：`apps/aicove_flutter/docs/02_前后端分离与架构规范/AIcove2.0_DSH驱动底层架构改造方案.md`。

实施采用“兼容性 Spike -> 可回滚垂直切片 -> 数据/权限/插件迁移 -> 默认切换 -> 旧核心退役”，最终目标是全量 DSH 驱动，不长期维护双 Agent 核心。

## 0. 兼容性基线

- [ ] 固定官方 DSH、Node、Termux、NDK、Shizuku API、libsu 版本与许可证清单。
- [ ] 建立 runtime builder，产出 arm64 bundle、原生库、清单、哈希和签名。
- [ ] 对 DSH Android patch set 增加逐项匹配断言和 smoke test。
- [ ] 记录 Runtime 体积、冷启动、常驻内存、耗电和崩溃恢复基线；未通过门禁时停止下游迁移。

## 1. Android runtime host

- [ ] 配置 `jniLibs` 可执行文件打包和 ABI 门禁。
- [ ] 实现 RuntimeInstaller A/B 安装、校验、空间检查和回滚。
- [ ] 实现 RuntimeSupervisor、前台 Service、日志和健康探测。
- [ ] 定义 Flutter MethodChannel/EventChannel 契约及 Dart adapter。

## 2. DSH Aicove profile

- [ ] 构建 `aicove` Cordis profile 和 `@aicove/dsh-bridge` 插件。
- [ ] 实现 agent/session 创建、输入、取消、流式事件和 replay RPC。
- [ ] 把 DSH SessionEvent 稳定映射为 Aicove `AgentOutputEvent`。
- [ ] 实现 `aicove.bridge.v1` 握手、feature negotiation、断线 replay 与主版本拒绝。

## 3. 权限后端

- [ ] AppBackend：Termux/proot bash、文件和工作区。
- [ ] ShizukuBackend：Binder 生命周期、授权、UserService/AIDL、UID/能力探测。
- [ ] RootBackend：libsu shell/RootService、授权和取消。
- [ ] CapabilityRouter：按能力、用户模式和失败原因选择/回退后端。

## 4. 可回滚聊天垂直切片

- [ ] 先使用隔离测试对话，不修改现行数据库真相源规则。
- [ ] 让一个 feature flag 下的 `StandardChatAgentRuntime` 调用 DSH adapter。
- [ ] 保留现有 Flutter 聊天 UI、DB 写入、流式展示和取消操作。
- [ ] 至少桥接一个现有能力，优先选择时间工具或 TTS 输出事件。
- [ ] 保留旧 `ChatSendUseCase` 回退路径。

## 5. 数据绑定与投影

- [ ] 接受 DSH/Drift 双域真相源 ADR，并同步修订旧上下文规范。
- [ ] 设计并迁移 session binding、agent run、projection receipt、message-event link schema。
- [ ] 实现首次 seed、幂等 replay、崩溃恢复和 runtime rollback 兼容读取。
- [ ] 实现编辑/重发对应的 DSH session fork；删除继续保持产品 UI 语义。

## 6. 插件与 Agent 迁移

- [ ] 定义 Dart DeviceCapability 与 Cordis Plugin 的边界。
- [ ] 依次迁移模型渠道、上下文、记忆、TTS、图片、表情包、主动消息。
- [ ] 后台 Agent 和前台 ChatAgent 都通过 DSH session/preset 运行。
- [ ] 旧 Agent loop 无调用者后再单独规划删除。

## 7. 默认切换与旧核心退役

- [ ] 新对话默认启用 DSH，旧对话按 binding 渐进迁移。
- [ ] 完成核心能力回滚演练、数据导出和观察期。
- [ ] 冻结旧 Agent loop；确认无调用者后另立删除任务。
- [ ] 更新根架构文档、用户帮助、故障恢复和平台兼容说明。

## Validation

- [ ] Runtime unit tests：manifest、签名、Zip Slip、空间不足、A/B 回滚。
- [ ] Android instrumentation：API 24/29/30/33/35，至少 arm64 真机 + x86_64 UI-only emulator。
- [ ] DSH smoke：启动、健康、真实模型请求、bash、fs、session resume、plugin load。
- [ ] 权限矩阵：App-only、proot、Shizuku shell UID、Root UID、授权撤销、重启后失效。
- [ ] Flutter tests：状态流、事件映射、重复 replay 幂等、旧链路 fallback。
- [ ] 项目交付：`flutter pub get`、静态检查、测试、`flutter run --no-resident`、窄/宽屏验收。

## Risk and rollback points

- DSH 上游升级：runtime 版本独立回退，不随 APK 自动覆盖数据。
- 权限后端：任何增强能力异常都回落 AppBackend。
- 数据迁移：首版不删除或重写旧消息；binding 可禁用。
- 插件迁移：逐个 feature flag 切换，禁止一次性移除 Dart 能力。
