# 空间网页运行（第一档）实施方案

> 状态：2026-10-17 草案，未开工。决策见 [ADR0089](../../../../../docs/项目记忆/决策记录/0089-空间里的网页用WebView运行且存档落进空间.md)；空间本身见 [ADR0087](../../../../../docs/项目记忆/决策记录/0087-Agent工作区插件.md) 与 [实施方案](../../02_前后端分离与架构规范/Agent工作区与杂活Agent实施方案.md)。

## 目标

空间里的 `.html` 点一下就在全屏页里运行（手机默认横屏）；游戏的 localStorage 落进同目录的 `<文件名>.save.json`，助手用现有文件工具就能读改。

不在第一档：边玩边联动（游戏调用助手、助手改档后当场刷新）、IndexedDB 接管、角色卡自动拆解工具、聊天里渲染 HTML。

## 现状与缺口

| 部分 | 现状 | 缺口 |
|---|---|---|
| 空间存储 | `features/workspace/data/workspace_store.dart`：`read` 返回 `(bytes, revision)`，`write` 带 `expectedRevision`／`runId`，单文件上限 32 MiB、空间配额 512 MiB | 无 |
| 路径规则 | `features/workspace/domain/workspace_path_rules.dart` | 资源请求要复用同一套校验 |
| 文件打开 | `ui/features/workspace/pages/workspace_detail_page.dart` 的 `_openEntry` 一律进 `workspace_file_page.dart`（纯文本预览，20 万字截断） | `.html` 多一个「运行」入口 |
| 导入 | 空间页没有从本机导入文件的入口；`file_picker`、`archive` 依赖已有 | 新增导入 |
| WebView | 无依赖 | 新增 `flutter_inappwebview` |
| Agent 提示 | `application/workspace_toolset.dart` 的 `workspace_open` 返回 AGENTS.md 和顶层目录 | 补一段网页与存档说明 |
| 修改记录 | 宿主写入用固定的 `hostRunId = 'host'`，不进撤销列表 | 每次游玩用独立 run，列表里要能认出来 |

## 分批

### H0 原型（先做，不通过就停）

在临时分支上加依赖，写一个最小运行页，只验证下面几件事：

1. Flutter 3.44 下 `flutter_inappwebview` 6.1.5 能否编译（Android、iOS、macOS；Windows 在 Windows 机器上至少编译通过）。不行就试 6.2 beta，再不行回来重新选型。
2. 每端用哪种地址：Apple／Windows 用自定义协议 `aicove-ws://<空间ID>/<路径>`；Android 先试自定义协议，主框架加载不了、或相对路径与 `fetch` 失效，就改用拦截假域名（如 `https://<空间ID>.ws.aicove.invalid/`）。把结论写回本节。
3. `<head>` 最前面插入的 CSP `<meta>` 能拦住 `fetch('https://example.com')` 和外链 `<script src>`。
4. `UserScript(AT_DOCUMENT_START)` 先于页面内联脚本执行（Android 要检查 `DOCUMENT_START_SCRIPT` 是否支持；不支持时改成宿主返回 HTML 时直接把替换脚本插到 `<head>` 最前面，两端共用这一种也行）。
5. `callHandler` 往返正常，主框架以外调不到。

原型代码不合入，结论和选定的版本写进本节「原型记录」。

### H1 运行页

新增文件：

- `features/workspace/webapp/webapp_resources.dart`：把请求地址解析成 `(空间ID, 相对路径)`，过路径规则，拒绝 `.aicove/`、其他空间、越界；按扩展名给 MIME（html、js、mjs、css、json、png、jpg、gif、webp、svg、mp3、ogg、wav、woff2、ttf、wasm 等）。返回 HTML 时插入 CSP 和存档脚本。
- `features/workspace/webapp/webapp_csp.dart`：CSP 文本与插入逻辑（找到 `<head>` 就插在它后面，没有就补一个 `<head>`；不解析整页 DOM）。CSP：`default-src <本空间源> data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src <本空间源> data: blob:; form-action 'none'; base-uri 'none'`。
- `ui/features/workspace/pages/workspace_webapp_page.dart`：全屏运行页。
  - `shouldOverrideUrlLoading`：只放行本空间地址；`onCreateWindow` 拒绝；`onPermissionRequest` 拒绝；下载拒绝。
  - Windows：启动时 `WebViewEnvironment.getAvailableVersion()`，为空时提示安装 WebView2，不进页面；`userDataFolder` 放 `appDataDirectory()/webview/`，自定义协议在环境里注册。
  - 方向：读页面里的 `aicove-orientation`（宿主返回 HTML 时顺便解析，缺省 `landscape`），手机上 `SystemChrome.setPreferredOrientations` 并进沉浸模式；`dispose` 时恢复到进入前的方向和状态栏。左上角一个半透明小按钮展开菜单：退出、临时转方向、重新载入。
  - 桌面端：`MoeWorkspace.open` 铺满当前窗口，菜单里加「全屏」。
- `workspace_detail_page.dart`：`.html`／`.htm` 行点击直接运行，行尾加「查看源码」进原来的文本预览。

### H2 存档

- `features/workspace/webapp/webapp_save.dart`（纯 Dart，可离线测试）：
  - `decode(bytes) → Map<String, String>`：读 `aicove.webapp.save.v1`，对象／数组值用 `jsonEncode` 还原成字符串，字符串原样返回；文件不存在就是空表；格式不对时**不覆盖**，提示「存档格式无法识别」，并以只读方式开局。
  - `encode(Map<String, String>) → bytes`：值能 `jsonDecode` 成 Map／List、且再 `jsonEncode` 后与原文完全相同，就展开；否则存字符串。用两格缩进输出，方便助手阅读和编辑。
  - 注意：Dart 的 `jsonEncode` 与 JS 的 `JSON.stringify` 对数字（如 `1.0`、`1e21`）的格式不同。判定「能展开」的那一步放在 JS 里做（页面这一侧才有原始字符串），Dart 只按 JS 给出的标记写文件；还原时由 JS 一侧 `JSON.stringify`。这样两端不会因为数字格式不同而改变原值。
- `features/workspace/webapp/webapp_storage_shim.js`（作为资源字符串内嵌）：
  - 用 `Object.defineProperty(window, 'localStorage', …)` 换成一个实现了 `getItem`／`setItem`／`removeItem`／`clear`／`key`／`length` 的对象，并用 Proxy 支持 `localStorage.foo = 'x'` 这类写法。
  - 每次修改记一个脏标记；停止改动 2 秒后、`visibilitychange` 变为 hidden 时、`pagehide` 时，调用 `callHandler('aicove_save', 快照)`。快照里每个值附带「是否展开」的标记。
  - 总大小（按 UTF-16 码元×2 估算）超过 5 MiB 时，`setItem` 抛 `DOMException('…', 'QuotaExceededError')`。
- 运行页一侧：
  - 每次打开生成一个 run，`webapp:<UUID>`；修改记录里显示为「运行 game.html · N 次存档」。
  - 写盘带上次读到的 revision；成功后更新 revision。`WorkspaceException` 为 revision 不符时，停止后续写盘，弹窗二选一：「载入新存档并重开」（重读、重开页面）／「保留游戏里的进度」（用当前 revision 再写一次）。
  - App 进入后台（`AppLifecycleState.paused`）和关闭运行页时，先 `evaluateJavascript` 触发一次立即保存并等它返回（最多等 1 秒），再离开。
- `workspace_toolset.dart`：`workspace_open` 的返回里，空间内只要有 `.html` 就追加一段说明：用户可以运行这些网页；存档在同目录的 `<文件名>.save.json`，并附格式；改存档在用户下次打开时生效；网页默认断网，依赖要放进空间。

### H3 导入

- 空间详情页右上角加「导入」：单个或多个文件、ZIP。ZIP 用 `archive` 解包，每个条目过路径规则，任何一个不合规就整体拒绝并列出原因。写入走 `WorkspaceStore.write`，一次导入一个 run（`import:<UUID>`），可撤销。
- 单文件超过 32 MiB、总量超过配额时，明确失败，不导入一半。

## 测试与验证

| 层次 | 内容 | 方式 |
|---|---|---|
| 离线单测 | 存档编解码往返（字符串、数字字符串、对象、数组、带空格的 JSON 文本、中文、空串、格式错误）；资源路径越界／`.aicove/`／其他空间；CSP 插入（有 `<head>`、无 `<head>`、大写标签、BOM）；方向 meta 解析；ZIP 路径校验 | `tool/flutterw test` |
| 原型与集成 | H0 五项；H1 断网、跳转、弹窗；H2 落盘时机与冲突弹窗 | Mac 调试版跑一个测试网页（带 localStorage 计数器、外链 fetch、相对路径图片），不抢前台；Android 用模拟器或真机交给用户 |
| 预览 | 运行页菜单、详情页「运行／查看源码」、导入入口 | 源码渲染预览图 |

测试网页放在 `test/fixtures/webapp/`，同时作为验收样例。

## 依赖与回滚

- 新增依赖只有 `flutter_inappwebview`。四端原生配置：Android 无需额外权限（不开网络访问之外的东西）；iOS／macOS 无需额外 entitlement；Windows 构建机装 NuGet CLI。
- 回滚：运行入口和依赖整体去掉即可。存档文件就是普通空间文件，留下也不影响其他功能。

## 原型记录

（H0 完成后填写：选定版本、各端地址形式、文档开始脚本方案、遇到的坑。）
