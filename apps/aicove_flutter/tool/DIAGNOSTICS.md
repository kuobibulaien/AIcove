# 用户只描述 BUG，agent 自己抓日志

2026-09-10：新增 Release 受控导出与自动电脑读取。旧 run-as 采集仍用于可调试构建；Release 使用下述读取通道或离线诊断包。日志是 agent 排查、实现和验收的默认证据入口，不是要求用户阅读的控制台。

## Release：电脑 Agent 直接采集

### Agent 排查时主动使用（2026-09-10）

排查项目的手机运行问题时，先实时抓取当前已落盘日志，再结合源码定位。包括卡顿、闪退/异常、聊天生成、分段、图片或音频问题，以及运行时改动的复现与验收。首次保全现场后，在关键复现步骤前后按需再次执行采集；保留各次独立诊断包，用运行编号与操作编号比较，避免覆盖原故障证据。当前是按需快照，不是持续流或逐帧采样，不要无目的高频轮询。

1. 检查已授权ADB设备，沿用用户已确认的目标，多设备不要猜。`adb devices` 为空时，先用 `lsof -nP -iTCP -sTCP:LISTEN | grep adb` 检查是否有其他 ADB 服务（如另一会话在 5038 端口启动的）占着设备，有就用 `ADB_SERVER_SOCKET=tcp:localhost:<端口>` 复用它（采集脚本同样继承该变量），不要关闭它，也不要让用户重插线。应用运行即自动提供通道，不要求用户打开开关、换Debug包、手动导出或逐张截图；结束排查也不关闭服务。
2. 优先使用当前会话已有的读取凭证或现有 `AICOVE_DIAGNOSTIC_TOKEN`。缺少凭证时，如果已获授权操作手机界面，Agent自行进入「设置→调试中心→诊断导出与电脑读取」读取电脑命令；这是获取凭证，不是开启服务。不要把命令中的凭证回显、提交或写入长期记忆；如果生成了含凭证的临时UI文件，使用后清理。凭证确实无法获取、设备未连接/未授权时，说明具体阻碍，仅请用户完成必要的一步。
3. 从Flutter目录执行下面的命令，检查 `summary.json` / `manifest.json` 的构建身份、记录覆盖及 `sourceCoverage`，然后沿 `operations.jsonl` 的事件、耗时、traceId/operationId分析。权限拒绝、通道不可达、截断或空结果都不等于没有发生故障。

```bash
cd apps/aicove_flutter
# 已有 AICOVE_DIAGNOSTIC_TOKEN；没有时使用页面提供的带凭证命令。
python3 tool/collect_diagnostics.py --release --since 2h --print
# 多设备添加 --device <已确认设备号>；按实际故障可扩大为 --since 7d。
# 复现后再次执行即可获取最新快照；--event / --trace 仅筛选终端展示。
```

通道不可达时先核对目标设备、应用进程及凭证，不以重装或清理作为第一步。应用确实已结束时，在当前任务授权范围内打开应用即可自动恢复；不要为了取日志先停止仍在运行的故障进程。不要绕过沙箱读取数据库或完整正文。

应用启动即自动开启读取通道，无需进入诊断页面或操作开关，没有30分钟到期。首次在「设置 → 调试中心 → 诊断导出与电脑读取」复制电脑命令，在 `apps/aicove_flutter/` 执行；本机凭据存储保存读取凭证，应用重启后原命令继续有效。macOS 已按用户要求改为应用私有文件，其他端保持原安全存储；macOS 首次切换会生成新的读取凭证，见 [ADR0032](../../../docs/项目记忆/决策记录/0032-Mac本地凭据与自动同步唤醒.md)。不要把凭证写入文档、提交或长期记忆。

```bash
# 使用手机提供的本机读取凭证；也可通过 AICOVE_DIAGNOSTIC_TOKEN 环境变量传入。
python3 tool/collect_diagnostics.py --release --token <本机读取凭证> --since 2h --print
# 多设备必须加 --device <已确认设备号>。
# --event pageLayoutReady 或 --trace <traceId> 只筛选终端展示，不裁掉包内关联证据。
```

脚本自动建立随机电脑端口到手机 `127.0.0.1:48631` 的 ADB 转发，请求结束撤销自己创建的转发，不依赖 `run-as`、root、可调试标志或新增系统权限。支持已授权的USB/无线ADB；不会开启无线调试、启动应用或更改系统设置。应用被系统暂停/结束时，需回到应用，通道会自动恢复；本功能不增加后台保活，也不承诺断电前最后事件已写盘。

读取不依赖诊断页面是否打开，也不会主动反复扫描日志。每次命令读取当时已落盘的快照，终端最多展示最近200条；完整筛选与关联证据见 `operations.jsonl`。这不是持续推送或公网远程日志服务。

## Android 应用数据占用盘点（2026-09-13）

新增的本机鉴权入口 `/v1/storage` 只枚举应用内部目录的文件大小、数量、分类与修改时间，不读取文件正文、不跟随符号链接，也不接受自定义扫描路径。未知文件名以标识摘要替代。与日志导出共用凭证及忙碌控制；扫描在后台 isolate 执行，最多 200,000 个目录项／45 秒，结果注明错误、截断与逻辑大小口径。APK、外部存储和文件系统块开销不计入此总数。

```bash
# 在 apps/aicove_flutter 下；凭证沿用 AICOVE_DIAGNOSTIC_TOKEN。
python3 tool/collect_storage_inventory.py --device <设备号> --output <新的本机JSON路径>
```

旧安装包没有此入口时，不把 404 当作没有占用。专项取证可使用 `tool/storage_probe.dart` 独立 Release 入口：先保存设备原 APK，确认同签名，再覆盖安装诊断包；此入口不运行业务初始化、迁移、同步或日志清理。除了目录元数据，它只在手机内计算图片内容哈希与 SQLite 只读聚合（表／列字节数、空闲页），不导出正文、凭据或图片。相同图片不等于可以直接删除，删除前仍要核对引用。取证后恢复原 APK，校验 APK 哈希；不要把临时诊断包作为普通应用交付，构建输出须恢复为正常入口。2026-09-13 现场证据见仓库 `.codex-temp/storage-audit-20260913/`。

## 不连接 ADB：手动导出后离线分析

同一页面点击「保存诊断包」，通过系统文件选择器保存JSON，再将文件传到电脑：

```bash
python3 tool/collect_diagnostics.py --from-bundle /path/to/aicove_diagnostics_....json --since 2h --print
```

离线时间窗口相对于手机**导出时刻**，隔天分析也不会错误过滤为空。手机包与电脑通道使用同一生成器；只读过去7天内可用的 app/api/trace索引，不读数据库、payload、图片或自由文本。手机在后台isolate做字段允许列表过滤，电脑再过滤一次。旧“完整对话导出”包含的内容范围更大，不与此受控诊断包混用。

每文件最多读取尾部16MiB、总输入64MiB、单行512KiB、最多20,000条，内容编码预算12MiB；电脑接收上限16MiB。半行、坏行、超限、读取失败与缺失目录均有覆盖声明。不是原子快照，不强制冲刷各日志队列；离线证据行号指向导出内容，不冒充手机原始文件行号。上游限制在 `summary.json → coverage.sourceCoverage` 中保留。

实现入口：`DiagnosticAccessPort` → `DiagnosticAccessService` / `createDiagnosticBundle`；只绑定IPv4 loopback，以随机256位本机凭证鉴权，不开局域网/公网监听。凭证仅保存于FlutterSecureStorage，成功持久化后才开放通道；读取或绑定失败每5秒自动重试，不阻塞首屏。应用进程存活期间持续开放，不设置到期或提供关闭开关。并发导出返回忙碌，避免多次同时扫描。错误凭证、未知路径不能取日志。

## Debug 旧入口（仅用于可调试安装，Release 使用上方自动通道）

在 `apps/aicove_flutter/` 下运行：

```bash
python3 tool/collect_diagnostics.py --since 2h
# 多台手机时不能猜设备；用已确认设备号：
python3 tool/collect_diagnostics.py --device 3a845d3f --since 7d
```

默认读取唯一在线且已授权的设备。工具不安装、不启动/停止应用、不操作 UI、不清数据、不上传、不提权。正式 release 的 run-as 拒绝访问时应停下，不能尝试绕过沙箱。

输出到 `build/diagnostic-bundles/<随机编号>/`，目录0700、文件0600，不能提交或公开整个包。

## 默认排查闭环（所有 agent 执行）

1. **先保全现场。** 收到手机运行异常反馈，先在已授权设备上抓取现有日志，再考虑复现、重启、编译安装或清理。默认最近2小时；没找到时先自行检查设备、时间和覆盖范围，必要时扩大到7天，不先要求用户重现或手动导出。保留原故障包，不覆盖它。
2. **核对证据是否可用。** 先读 `summary.json` 和 `manifest.json`，检查安装构建、运行编号、源码匹配、覆盖时间、截断与缺失。不能将当前工作树当作手机正在运行的源码。设备断开或未授权时，只请用户完成连接这一项必要动作，不绕过权限。
3. **沿同一次操作还原过程。** 按候选 `evidence` 读取 `operations.jsonl` 对应行，沿 `traceId`、`operationId`、`parentOperationId`、`messageId` 和页面实例查询；对照执行前后状态与执行/跳过的原因，区分请求返回、业务投递、界面布局和实际播放。取消或旧轮次拒绝不自动等于 BUG。
4. **提出可验证的原因。** 结合对应源码给出“事实→推断→缺少的证据”，内部记录引用故障包路径及 `operations.jsonl:行号`。不把相近时间的另一轮错误当作本次原因；日志或代码能回答的问题不交给用户。确有缺口才问一个必要问题，未知自由文本或原始消息需要另行最小范围授权。
5. **用同一现象验收修复。** 先写复现测试再修，之后核对新运行的构建身份和相关事件，确认期望状态确实发生，而不只看测试变绿或异常日志消失。真实模型请求等仍遵守既有授权边界；无法实测就明确标为未验收。日志不足时在批准范围内补采集点再验证，不能补造历史证据。

### 日志也辅助日常开发与交付

涉及运行时行为的新功能/修复，检查关键操作能否被关联、等待与跳过是否有原因、失败/取消是否有记录；复用现有 Port 和受控字段，不为排查新增逐帧写盘或敏感正文。对用户报告只给结论、关键证据与验收状态，不要求用户理解编号或阅读整包日志。

建议内部排查记录使用以下最小结构（不把聊天正文复制进记录）：

```text
现象：用户原话或忠实摘要
现场：设备、buildId、appRunId、诊断包路径及覆盖缺口
证据：operations.jsonl:行号 → 同一操作的状态变化/裁决原因
判断：已确认事实；候选原因；仍需验证的部分
验收：复现测试、修复后构建与相关事件、未完成项
```

## 项目 Flutter SDK（2026-09-12）

当前项目基线为 **Flutter 3.44.6 stable / Dart 3.12.2**，`pubspec.yaml` 设置最低版本，`pubspec.lock` 固定解析结果。保留旧 SDK，不修改机器全局 PATH。

在 `apps/aicove_flutter/` 中以 `tool/flutterw` 代替本文及其它文档命令中的 `flutter`；脚本默认调用 `$HOME/dev-sdks/flutter-3.44.6`，其它安装位置用 `AICOVE_FLUTTER_SDK` 指定。它会同时设置子进程的 PATH 和 FLUTTER_ROOT，避免 Dart 与 Flutter 来自不同 SDK。

```bash
cd apps/aicove_flutter
tool/flutterw --version
tool/flutterw pub get
tool/flutterw test
# 自定义 SDK 安装位置：
# AICOVE_FLUTTER_SDK=/path/to/flutter-3.44.6 tool/flutterw --version
```

`mac_debug_session.py start` 默认使用同目录 `flutterw`；`--flutter` 仍可显式覆盖。旧 SDK 创建的 Debug 会话不能热重载升级，切换前按下节停止旧会话再启动。不要同时在同一 checkout 用不同 SDK 跑 `pub get`／测试／构建；这会改写 `.dart_tool/package_config.json`，导致新引擎加载旧 framework。并发验收使用独立源码副本及独立生成目录，不终止其他会话的任务。

需要直接运行同一套 SDK 的 Dart 时用 `tool/flutterw --dart <参数>`；此入口同时设置 `DART_SDK` 与 `FLUTTER_SDK`，避免 MCP 被其它工具遗留的环境变量指向旧 SDK。Dart MCP 复用此入口及既有 SDK／影子 SDK 选择逻辑。

本次继续使用 CocoaPods，通过 `flutter.config.enable-swift-package-manager: false` 在项目内关闭 SDK 默认的 Swift Package Manager 自动迁移；不改全局 Flutter 配置。Lucide 的兼容补丁见 [`third_party/lucide_icons/README.md`](../third_party/lucide_icons/README.md)。

## Mac 持续调试会话（日常 Dart 迭代，2026-09-12）

何时热重载、热重启、重新构建或安装，以及 MCP／外观／性能的验收边界，统一按根 [README.md 项目宪法第 7 条](../../../README.md)。本节只说明现有 Mac Debug 会话的具体操作。

统一使用 [mac_debug_session.py](mac_debug_session.py) 管理会话。`start` 自动复用当前项目目录已有的会话；首次启动才运行 `flutter run -d macos --debug --machine`。状态与独立运行日志保存在当前目录的 `build/mac-debug-session/`，不同 checkout 不共用文件；同一目录的命令加锁串行执行。不要同时手动启动同目录的 Flutter 或绕过脚本操作会话。

```bash
cd apps/aicove_flutter
# 已有会话就复用，无需先执行 status；返回本次会话的 pid、log 路径
python3 tool/mac_debug_session.py start
# 改完 Dart 后按需二选一：通常用 reload；需重跑 main/初始化逻辑时用 restart
python3 tool/mac_debug_session.py reload
# python3 tool/mac_debug_session.py restart
# 应用内受控日志继续用采集器
python3 tool/collect_diagnostics.py --from-dir "$HOME/Library/Containers/com.example.aicoveFlutter/Data/Documents/logs" --since 2h --print
```

- 脚本校验 PID、进程启动时间、Flutter 命令及工作目录；收到 `app.started` 才确认就绪。重载通过本地 FIFO 向 Flutter 官方机器协议发送 `app.restart`，只接受匹配本次请求编号且 `result.code == 0` 的响应。旧日志、其它请求和“Restarted application”文案均不能证明本次成功；后者在本机 Flutter 的失败路径也会输出。协议成功只代表重载操作成功，运行时异常、布局与外观仍按相应验收要求判断。
- 默认启动等待上限 300 秒、其它操作 60 秒，可用 `--timeout 秒数` 调整。启动失败或超时保留日志；超时后重复 `start` 继续等待同一进程。重载超时后用 `python3 tool/mac_debug_session.py wait` 继续确认，不重复发送请求；收到明确失败响应后可直接修复并重试。仅查看状态时用 `status`，不会启动应用。
- 运行时异常、断言与 `debugPrint` 在命令返回的 `log` 路径中，机器模式通常包装为 `app.log` 事件；需要持续观察时对该路径执行 `tail -f`，结束 tail 不影响会话。这是原始调试日志，可能包含正文或本机调试连接凭证，不提交或整份贴出；受控分享继续用采集器。
- **收工不默认结束会话。** 只有原生／依赖变化需要重新构建、切换目标版本（Profile／Release）、或用户明确要求时才执行 `python3 tool/mac_debug_session.py stop`，并说明原因。停止会保留日志，后续 `start` 创建新日志；如需 `flutter clean`，先停止会话并保全需要的日志，再清理包含会话记录的 `build/`。脚本不会接管旧 `/tmp/aicove_debug.pid` 或手动启动的会话，迁移前先核对并结束旧会话，不直接删除 PID 文件后另起进程。
- 热重载不重建 native，也不更新构建指纹；不能用它证明设备上的 Dart 版本与工作树一致（见下文「采集与版本边界」）。交付验收仍按根 `README.md` 项目宪法第 7 条重新构建目标版本。
- 这个会话是 Debug 模式，不用它下性能结论；卡顿、动画用 `--profile` 单独构建并读取帧耗时。
- 脚本不包含窗口激活或鼠标键盘操作；首次启动 Flutter 仍可能展示应用窗口，不能把后台进程理解为首次启动也绝不影响前台。界面核验按 AGENTS「Mac 调试与界面验收：默认不抢前台」执行。
- 容器路径以实际 bundle id 为准；找不到时用 `ls ~/Library/Containers | rg -i aicove` 确认，不要猜。
- 官方 Dart MCP 已通过项目配置接入，连接与使用见下节；本节会话脚本继续负责现有 Mac Debug 会话的启动和串行重载。
- 本节协议按本机 Flutter 源码核对，脚本以隔离模拟进程验证；尚未启动真实 AIcove 验证完整会话。离线回归命令：`python3 -B -m unittest discover -s tool -p 'test_mac_debug_session.py'`。

<a id="dart-mcp"></a>

## 项目级 Dart MCP（2026-09-12）

### 统一入口与客户端配置

服务名统一为 `dart`。所有入口最终执行 [`tool/dart_mcp_server`](dart_mcp_server)，通过 `flutterw --dart mcp-server` 使用项目 SDK，工作目录固定为当前副本的 Flutter 工程。服务使用 stdio（标准输入输出），每个 harness 自行持有一个 MCP 子进程，不需要常驻端口或共享后台服务器。stdout 仅供 MCP 协议使用，不在启动脚本中打印提示或加载交互式 shell 配置。

以仓库根目录打开项目或启动 harness。配置没有写死 `/path/to/home` 路径：终端入口通过 Git 定位当前仓库，编辑器入口使用 `${workspaceFolder}`；复制仓库／创建 worktree 后指向各自的脚本。SDK 位置覆盖沿用上节 `AICOVE_FLUTTER_SDK`。

| Harness | 仓库内配置 | 加载说明 |
|---|---|---|
| Codex CLI／桌面／IDE | `.codex/config.toml` | 受信任项目加载；已有任务需重新加载 MCP 或开启新会话，配置不会自动注入本次旧工具列表 |
| Claude Code | `.mcp.json`、`.claude/settings.json` | 已仅启用项目 `dart` 服务；新机器仍遵守客户端的工作区信任机制 |
| Pi | `.mcp.json`、`.pi/settings.json`、`.pi/mcp.json` | 项目声明 `pi-mcp-adapter`，Pi 专属覆盖启用直接工具；已有会话用 `/reload`。本机复用已安装的 adapter 2.31.0，未改全局 `parallel-search` |
| Gemini CLI | `.gemini/settings.json` | 项目级 `mcpServers`，重新加载 MCP 或会话后使用 |
| Cursor | `.cursor/mcp.json` | 从根目录打开项目，加载工作区 MCP |
| VS Code／Copilot | `.vscode/mcp.json` | 从根目录打开项目，通过 `MCP: List Servers` 查看／启动 |
| Antigravity CLI | `.agents/mcp_config.json` | 使用官方项目 MCP 配置入口 |
| OpenCode | `opencode.json` | 项目级 local MCP，已启用 |

支持 stdio MCP 的其它 harness 可导入根 `.mcp.json`，或将 `bash /当前仓库/apps/aicove_flutter/tool/dart_mcp_server` 配成项目工具。没有原生 MCP、忽略项目配置或通过 Host 注入独立配置的 harness，使用下面的命令行客户端；不能把写入一个配置文件描述成任意宿主都已自动加载。

### 连接已有应用与日常调用

**代码修改后的操作顺序**：在 Flutter 工程内执行 `python3 tool/mac_debug_session.py reload`（需重新初始化时用 `restart`）；只在收到匹配本次请求的成功响应后，读取下面的 MCP 异常／组件树并检查目标行为。已有 pending 请求先执行 `wait`，超时或失败不当作修改已生效，也不绕过管理脚本再发 MCP 重载。MCP 工具不会监视文件并自动应用源码。

**只读取当前状态**时，直接从以下连接步骤开始，不运行重载命令。重新加载 harness 的 MCP 配置只影响工具连接，与 Flutter 热重载、应用安装是三件独立的事。验证范围仍以根 [README.md 项目宪法第 7 条](../../../README.md)为准。

1. 先查看 `dart` 的实际工具列表。SDK 版本决定工具和参数；本机当前默认返回 13 个工具，不按上游最新 README 猜测工具名称。
2. 源码分析根目录使用当前副本的 `apps/aicove_flutter`。客户端支持 MCP roots 时提供该目录；否则调用 `roots`，参数 `{"command":"add","uris":["file:///当前仓库/apps/aicove_flutter"]}`。
3. 调用 `dtd`，参数 `{"command":"listDtdUris"}`；核对返回的 Workspace Root、进程和 SDK，选择当前副本的 DTD。不要选择另一个 agent 的构建副本。
4. 在**同一个 MCP 连接**中用 `dtd` 的 `connect` 连接选定 URI，再用 `listConnectedApps` 核对 `aicove_flutter` 和目标设备。多应用时后续调用显式传入 `appUri`。
5. 读取异常用 `get_runtime_errors`，首次排查保持 `clearRuntimeErrors: false`；组件树用 `widget_inspector`，参数 `{"command":"get_widget_tree","summaryOnly":true,"appUri":"实际应用 URI"}`。不为读取树打开选择模式、清空错误或抢前台。

现有 Mac 会话继续由 `mac_debug_session.py` 管理启动、停止及串行重载；它有 pending 请求时先按本文件流程等待，不能绕过脚本再发一次 MCP 热重载。MCP 的 `hot_reload`／`hot_restart` 可用于另行明确由该 harness 管理的独立调试会话；后者会重置 Dart 状态。不要为接 MCP 重启、重装或另开同一 checkout 的应用。

运行时检查需要应用开放调试服务；界面树通常使用 Debug。Release 手机问题继续走日志采集通道；MCP 不替代 Profile 性能证据、实际外观及设备验收。DTD／应用 URI 含本机连接凭证，组件树可能含聊天正文；不写入项目文档、不提交完整协议日志。

### 无原生 MCP 的通用调用与自检

[`tool/dart_mcp_client.py`](dart_mcp_client.py) 仅依赖 Python 3 标准库，直接调用同一个官方 MCP；支持握手自检、工具列表、单次调用和共享连接的批次。以下命令从仓库根目录运行：

```bash
# 只验证服务器握手和关键工具；不会启动或重载 AIcove
python3 apps/aicove_flutter/tool/dart_mcp_client.py --check
# 查看当前版本的工具名称和参数
python3 apps/aicove_flutter/tool/dart_mcp_client.py --list-tools
# 列出已有调试服务（输出仅留本机）
python3 apps/aicove_flutter/tool/dart_mcp_client.py --call dtd --args '{"command":"listDtdUris"}'
# 用上一步的真实 URI 替换占位符；连接状态仅在这一个批次内保留
python3 apps/aicove_flutter/tool/dart_mcp_client.py --batch '[{"name":"dtd","arguments":{"command":"connect","uri":"实际 DTD URI"}},{"name":"dtd","arguments":{"command":"listConnectedApps"}},{"name":"get_runtime_errors","arguments":{"clearRuntimeErrors":false}}]'
```

多应用批次须为异常／组件树调用提供真实 `appUri`。单次调用结束后客户端关闭自身的 MCP 子进程，不停止连接的 AIcove；因此分开执行两次 `--call` 不会保留 DTD 连接。每个请求默认超时 120 秒，可用 `--timeout` 调整；工具返回错误时退出码非零，批次不继续执行后续调用。工具可执行真实操作，继续遵守项目任务授权范围。

### 本次验证与边界

- 7 份原生启动配置分别完成真实 MCP 握手、工具枚举和 `roots` 调用；Codex 配置由 CLI 实际解析，Claude `mcp get dart` 显示 Project／Connected。
- Pi 使用本机 adapter 的配置加载器和其 MCP SDK 完成工具枚举、`roots` 调用，确认 `directTools` 生效且全局 `parallel-search` 保留；未启动额外模型对话。
- MCP 已后台连接当前 AIcove Mac Debug，读取到真实组件树，`get_runtime_errors` 返回 `No runtime errors found.`；没有发送热重载、清空异常或启动新应用，原 pending reload 保留。
- Gemini、Cursor、VS Code、Antigravity、OpenCode 已验证配置命令的协议连接，未逐个打开宿主 UI 验证工具展示；当前旧 Codex 任务未热注入工具，已经通过通用客户端完成真实调用。未验证手机、Release 或热重载效果。
- 本机验证证据见 `.codex-temp/dart-mcp/verification.md`（仓库根目录，本机产物，不提交）。

配置格式依据：[Dart MCP](https://github.com/dart-lang/ai/blob/main/pkgs/dart_mcp_server/README.md)、[Codex](https://developers.openai.com/codex/mcp/)、[Claude Code](https://code.claude.com/docs/en/mcp)、[Pi adapter](https://github.com/nicobailon/pi-mcp-adapter)、[Gemini CLI](https://geminicli.com/docs/tools/mcp-server/)、[Cursor](https://cursor.com/docs/context/mcp)、[VS Code](https://code.visualstudio.com/docs/copilot/customization/mcp-servers)、[Flutter AI 接入（含 Antigravity）](https://docs.flutter.dev/ai/get-started)、[OpenCode](https://opencode.ai/docs/mcp-servers/)。客户端升级后以实际配置加载结果和工具列表复核。

## 采集与版本边界

- 收集 `logs/app_*.jsonl`、`logs/api_*.jsonl`、`logs/trace/index_*.jsonl`，**不读数据库和 payload 目录**。旧文件经电脑内存允许列表过滤，只保留事件身份、状态和数值；不落地自由文本日志、模型正文、URL、授权头。
- 从请求时间窗出发，最多扫描七天，补全同 trace/同运行内父子操作；没有明确 traceId 的旧网络日志只是时间候选，不能按共用 turnId 硬绑重试。
- 每文件最多读取末尾16MiB，总输入64MiB，单行512KiB；规范化记录最多20,000条/16MiB，超限明确报告。候选摘要仅保留最近200个，附总数和截断标记。
- 这是活跃文件的只读采集，不是原子快照：半行、序号缺口、读取中断等会报告。旧日志无运行身份时也会明确计数。
- Android Gradle 自动计算 lib/tool Dart/资源/主要Android构建源码与依赖锁文件指纹，嵌入 BuildConfig。每次 native 构建在 `build/diagnostics/<buildId>.json` 留下逐文件哈希，并检查构建结束时输入是否变化。该文件不含源码正文。
- 诊断服务记录实际 native buildId、Flutter模式、应用版本、设备/系统、屏幕与刷新率；这是**Android源码构建快照，不是完整可复现构建证明**。SDK/外部编译环境不在该指纹内；hot reload/restart 不重建 native，不能用它证明热重载后的 Dart 版本。
- 采集器报告本机是否还持有对应构建清单，以及清单中的文件与当前工作树是否相同。清单丢失、构建中改码、热重载等不能冒充“设备就是当前代码”。

## 第一批证据与尚未覆盖

已覆盖：运行/来源序号；固定异步父子操作；真实分段物化、投影提交、临时raw→最终raw映射；动画裁决的 pending/previouslyBuilt/用户控制状态；TTS开始/结果/拒绝/回调/持久化；AppLogger已知写入成功、失败计数；队列丢弃。

错误细节安全策略：已知 StateError、Timeout、RangeError、PlatformException 的受控说明/码和最多64个代码位置。**未知自由文本错误信息仍省略并标记**，不承诺自动脱敏任意自然语言里的病患正文；原生帧/设备绝对路径不在代码位置列表中。

未实现：故障前60秒/后15秒冻结、全日志统一磁盘配额、帧摘要、原生退出原因、公网/局域网远程通道。这些属于后续批次；当前不能保证所有偶发视觉 BUG 或断电前最后事件可还原。

## 历史窗口冷加载（2026-09-06）

`historyColdLoad` 的同一 operation 有 start/end；只在实际缓存缺失读取时记录，并发进入共用一次读取，热命中不重复打点。失败使用该 operation 的 `historyFailed`，保留原异常传播。该任务可由联系人预读触发，也可被多次进退共享；按同运行、conversationId与时序关联，不能硬认成某个页面的独占任务。

- `queueMs`：进入会话串行队列到实际开始的等待；不包含在该 operation 的 elapsedMs 内。
- `rawReadMs` / `blockReadMs`：原始消息/内容块读取阶段，包含开库、共享连接等待、结果传回与映射，不是纯 SQLite 执行耗时。`decodeMs` / `projectionMs` / `installMs` 分别为结构解析、前端投影、内存快照安装。
- `rawReadCount` 含判断是否还有历史的哨兵（通常21），`rawCount` 是实际处理窗口（通常20）；`blockCount` / `projectedCount` 是对应块/投影数量，不等于可见气泡数。
- `rawPayloadChars` / `blockDataChars` 只记录已读取字符串的UTF-16长度，不采集内容，也不是文件字节数。20条raw可能仍携带数千万字符，LIMIT不能限制数据体积。

查询索引由 `AppDatabase.beforeOpen` 幂等补齐，仍是schema v16：`messages_active_conversation_time`、`message_blocks_active_message_order`。首次创建有一次性开销；两条索引在事务内建立，锁冲突释放事务后最多重试6次（总延迟上限3.15秒，不含执行时间），非锁错误直接上抛。旧v16可继续打开，回滚时先回退本轮索引维护代码，再仅移除这两个索引；不改字段、不删除记录、不降低user_version。

## 离线验证

```bash
python3 -m unittest discover -s tool -p 'test_collect_diagnostics.py'
flutter test --no-pub test/features/observability/diagnostic_evidence_test.dart test/ui/features/chat/widgets/diagnostic_segment_evidence_test.dart
flutter test --no-pub test/core/database/chat_entry_indexes_test.dart test/features/chat/services/chat_cold_load_diagnostics_test.dart
```

`--from-dir <已有日志目录>` 可离线验证采集器；不访问手机，时间按电脑当前时区解释无时区的旧日志。

## 历史体积统计与计时语义（2026-09-10）

- 冷加载结束的state新增固定分类字符串长度：payloadReplyChars（原始回复）、payloadProcessedChars、payloadThoughtChars、payloadPluginEventChars、payloadPluginContentChars、payloadAudioResultChars、payloadToolArgsChars（工具调用）、payloadToolResultChars、payloadProjectionChars、payloadSupplementChars、payloadOtherChars。只遍历已经解码的对象，不再次jsonEncode/jsonDecode，不记录动态字段名/值。数值为UTF-16字符串值长度，不含键名/JSON语法，不等于磁盘或内存字节。
- 单窗口共用最多12,000节点、16层深度预算；payloadScanNodes与payloadScanTruncated说明覆盖范围。截断后各分类是下界，不作为完整占比。maxRawPayloadChars为处理窗口内最大单条完整raw JSON字符串长度。
- payloadStatsMs单独计统计耗时，不混进decodeMs/projectionMs；开关关闭或热命中不执行扫描。统计输出仍在现有32字段上限内。冷加载端到端elapsedMs>=500才标warning，不用旧消息累计时间判断动画卡顿。
- animationDecision现在以viewport作为operationId和时钟，旧消息操作放parentOperationId，保留trace/turn；state.viewportClock=true标识新语义。UI显示“播放/跳过入场动画·视口创建后”，不是动画执行耗时。旧记录保留技术详情中的elapsedMs，摘要不再把它标成动画用时。
- 页面historyReady/pageLayoutReady显示“进入后”；pageLeft显示“停留”；pageLeftBeforeLayout显示“已等待”。其他里程碑明确“累计”。冷加载详情分离读取、块读取、解析、显示转换、安装、统计与排队；旧日志缺项显示未采集。
- 原始数据/schema/消息生成逻辑不变。回滚本批统计/格式化/动画诊断关联代码即可，历史日志保持可读。此批未加入逐帧轨迹，不能据此声明所有动画已流畅。

回归：history_payload_stats_test.dart、log_frontend_summary_test.dart、chat_cold_load_diagnostics_test.dart、diagnostic_segment_evidence_test.dart及既有observability测试；日志UI覆盖360/1000px、1.2/1.8字号。

### 历史显示读取优化后的指标（2026-09-10）

`displayRead=true`表示前端专用读取：已有显示快照时只取该快照，其他行保持完整载荷。`rawPayloadChars`及字段分类统计表示本次窗口参与解析的载荷，不再代表对应数据库原始行总量，也不含分页哨兵；不能用它推算数据库缩小了多少。`displayFallbackCount`是无法反序列化显示快照、重新读取完整raw的条数。

`backgroundDecode=true`表示本次大载荷解析/字段统计/显示转换通过原生worker执行；`workerMs`是任务往返时间，包含阶段工作，不要再与decodeMs/projectionMs相加。256Ki字符以下及Web直接解析；这些指标都不等同帧时间。原始查询、上下文和备份没有裁剪，旧版可直接读回原数据。

### 快速返回转场的终端证据（2026-09-10）

已注入FrontendDiagnosticsPort的路由（含主入口、聊天与新角色Page）在程序返回中断尚未完成的横向入场时，通过现有前端诊断通道追加event=`routePopInterrupted`，state只含entryProgress（controller进度0–1）、exitDurationMs（计划退出时长）。诊断启用时另用debugPrint镜像一条`RouteTransition`数值日志到Release logcat；AppLogger本身仅在Debug输出控制台。未注入诊断的helper路由仍执行修复，但不输出该事件。可在已授权设备上用当前PID的`adb logcat -d --pid=<PID> -v brief`筛选`[RouteTransition]`，无需截图或数据库权限。该行证明修复分支触发，不证明真机逐帧位移；连续性和最初32ms位移由路由几何回归验证。没有该行也可能是入场已完成、手势返回、未实际返回或logcat被轮转，不能直接判为失败。
