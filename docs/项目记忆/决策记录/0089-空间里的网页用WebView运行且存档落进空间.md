# 0089 空间里的网页用 WebView 运行，存档落进空间

- 状态：第 1、2、3、5 条已由 [ADR0105](0105-空间网页用系统浏览器加本机服务运行.md) 取代（2026-10-22，改用系统浏览器＋本机服务，不再引入 `flutter_inappwebview`）；第 4 条存档格式与第 6 条导入保留。原状态：accepted（2026-10-17 用户确认第一档范围：空间里的 HTML 用 WebView 打开、横屏、localStorage 落到空间存档文件供助手读写；新增核心依赖 `flutter_inappwebview` 以 H0 原型通过为前提）
- 日期：2026-10-17
- 关联：ADR0087（Agent 工作区插件：存储、条件提交、撤销、同步）、ADR0088（杂活 Agent 使用工作区文件工具）、ADR0073（AIcove 助手）、ADR0046／0071（聊天里不渲染卡片 HTML，本 ADR 不改）、ADR0064（插件界面只开放声明式描述，本 ADR 不改）、ADR0086（应用数据目录）

## 背景

不少酒馆角色卡自带一整套 HTML＋CSS＋JS，有的就是一个完整的小游戏。ADR0046／0071 定下聊天里不渲染卡片 HTML，这类卡在 AIcove 里只能丢掉。ADR0087 之后有了空间（工作区）：Agent 能读写的一块文件区，带条件提交、撤销和成员同步。

用户希望：一个独立的 HTML 放进空间后，点一下就能横屏玩；游戏的数据对助手近乎裸露，助手能直接读、改。

### 核实的平台支持（2026-10-17）

| 插件 | Android | iOS | macOS | Windows | 结论 |
|---|---|---|---|---|---|
| `webview_flutter` 4.14.1（官方） | ✓ | ✓ | ✓ | ✗ | 缺 Windows，不选 |
| `flutter_inappwebview` 6.1.5（Apache-2.0） | ✓ | ✓ | ✓ | ✓（WebView2） | 选用 |

`flutter_inappwebview` 的文档写明：内嵌 `InAppWebView`、自定义协议回调 `onLoadResourceWithCustomScheme`、JS 调宿主 `addJavaScriptHandler`、文档开始前注入 `UserScript(AT_DOCUMENT_START)`，四端都支持。另有几处需要注意：

- **Windows**：依赖系统的 WebView2 Runtime。Win11 自带，Win10 可能没装，要用 `WebViewEnvironment.getAvailableVersion()` 检查；默认用户数据目录在 exe 旁边，要改到 `appDataDirectory()` 下；自定义协议在 `WebViewEnvironment.customSchemeRegistrations` 里注册，不走 `resourceCustomSchemes`。构建机需要 NuGet CLI。
- **Android**：`AT_DOCUMENT_START` 依赖 `WebViewFeature.DOCUMENT_START_SCRIPT`，不支持时插件只能「尽快注入」，不保证先于页面脚本执行。
- **版本**：稳定版 6.1.5 约两年前发布，主线（6.2 beta）要求 Flutter ≥3.32。本项目是 Flutter ≥3.44.6，稳定版能否直接编译、要不要用 beta，由 H0 原型决定。

来源：<https://pub.dev/packages/flutter_inappwebview>、<https://inappwebview.dev/docs/webview/in-app-webview/>、<https://inappwebview.dev/docs/webview/javascript/communication>、<https://inappwebview.dev/docs/webview/javascript/user-scripts>、<https://pub.dev/packages/webview_flutter>

## 决定

### 1. 定位：空间文件的一种打开方式

- 空间里的 `.html`／`.htm` 文件多一个「运行」入口，在**独立的全屏页面**里打开。聊天气泡里仍然不渲染 HTML，ADR0046／0071 不变。
- 这不是插件界面扩展，ADR0064「插件界面只开放声明式描述」不变：网页只能画自己的页面，碰不到 AIcove 的界面。
- 第一档只负责「跑起来、存档落盘」。把角色卡拆成网页、下载 CDN 依赖到本地，由 Agent 用现有文件工具完成，本 ADR 不新增 Agent 工具。

### 2. 资源只从本空间读，不起本地 HTTP 服务

- 页面和它引用的 CSS、JS、图片、音频，都由宿主拦截请求、从**这个 HTML 所在的空间**读出来返回。路径过 ADR0087 的路径规则，不能越出空间，也不能读 `.aicove/`。
- 地址形式按各端能拦截的方式定（Apple／Windows 用自定义协议，Android 视原型结果可能改用拦截假域名），由 H0 原型确定。对外原则只有一条：**同一空间内相对路径能用，空间外什么都拿不到**。
- 不起 `127.0.0.1` 本地服务：本机其他 App 也能访问这个端口，等于把空间文件暴露出去。

### 3. 默认断网，只开一座窄桥

- 宿主返回 HTML 时，在 `<head>` 最前面插入一条 CSP（内容安全策略：浏览器自带的「这个页面能从哪里加载东西」的规则）：只允许本空间的地址和 `data:`、`blob:`，允许内联脚本和 `eval`（小游戏常用），禁止一切外网请求。CSP 一旦生效，页面脚本无法放宽。
- 顶层跳转到别的地址、`window.open`、下载、文件选择、相机／麦克风等权限请求，一律拒绝。
- 页面能调用的宿主接口只有：保存存档、报告就绪、写调试日志。桥只对主框架、只对本空间地址开放。网页拿不到 API Key、主数据库、其他空间和聊天记录。
- 网页内容一律当不可信数据。助手读到的 HTML 和存档内容同样是数据，不是指令。

### 4. localStorage 落进空间里的存档文件

- 存档文件放在 HTML 同目录，叫 `<文件名>.save.json`（例：`game.html` → `game.save.json`）。一个空间里放几个游戏也互不干扰。助手用现有的 `read`／`edit`／`write` 就能读改。
- 页面加载前，宿主把存档内容嵌进一段文档开始脚本，用它**替换 `window.localStorage`**：一个同步读写的内存仓库，初始值来自存档。游戏代码不用改。`sessionStorage` 保持浏览器原样（关页即丢）。
- 存档格式（让助手读得懂，同时保证原样还原）：

  ```json
  {
    "format": "aicove.webapp.save.v1",
    "localStorage": {
      "settings": "dark",
      "player": { "level": 7, "gold": 1200 }
    }
  }
  ```

  localStorage 的值本来都是字符串。如果某个值是 JSON 对象或数组，并且 `JSON.stringify(JSON.parse(值)) === 值`，就展开成对象存，助手能直接改字段；其他情况一律按原字符串存。读回时，对象和数组用 `JSON.stringify` 还原成字符串，字符串原样返回。只展开对象和数组，所以「存的是字符串还是展开的 JSON」不会混淆。
- **什么时候写盘**：页面停止改动约 2 秒后写一次；页面隐藏、App 退到后台、关闭运行页时立即写一次。写入经 ADR0087 的提交协调器，带 `expected_revision`。同一次游玩的所有写入归在同一个 run 下，在「修改记录」里可以整次撤销。
- **容量**：存档最多 5 MiB（与常见浏览器的 localStorage 上限一致）。超过时 `setItem` 抛 `QuotaExceededError`，行为和浏览器相同。
- **助手和游戏同时改**：第一档约定助手的修改在下次打开时生效。游戏开着的时候，存档如果被别处改了（助手、撤销、同步入站），写盘会因为 revision 不符而失败。这时运行页暂停写盘，弹出两个选项：「载入新存档并重开」或「保留游戏里的进度并覆盖」。不静默覆盖任何一方。
- 存档是普通空间文件，跟着 ADR0087 的成员同步走，不另设同步。

### 5. 横屏与全屏

- 手机上打开运行页时锁定方向、隐藏系统状态栏，退出时恢复原样。默认横屏。
- HTML 可以用 `<meta name="aicove-orientation" content="landscape|portrait|auto">` 声明方向，Agent 拆卡时顺手写上即可。运行页菜单里能临时转方向，不回写文件。
- 桌面端在当前窗口全屏铺开运行页，可切换系统全屏，不涉及方向。

### 6. 把网页放进空间

- 空间页新增「导入文件」：可选单个 HTML、多个文件，或一个 ZIP（解包到所选目录）。导入走提交协调器，记在一个宿主 run 下，可以撤销。
- 助手也可以直接用文件工具写出 HTML。`workspace_open` 返回的说明里要写明：`.html` 可由用户运行，存档在同目录的 `<文件名>.save.json`，以及上面的格式。

## 代价

- 新增核心依赖 `flutter_inappwebview`。稳定版维护节奏偏慢，四端原生配置都要动；Windows 构建需要 NuGet，Win10 用户可能要另装 WebView2。
- 只接管了 localStorage。用 IndexedDB 的游戏（例如基于 localforage 的 RPG Maker MZ 存档）进度留在 WebView 自己的存储里：助手看不到，不同步，在自定义协议下能不能用也要看平台。
- 默认断网会让依赖 CDN 的网页打不开，要靠 Agent 先把依赖下载到空间里。
- 「边玩边联动」（游戏里调用助手、助手改完游戏当场刷新）不在第一档。
- WebView 自身的内存占用和启动耗时要实测，手机端尤其明显。
- App Store 审核指南 4.7 对 HTML5 小程序／小游戏的口径未逐条核实，上架前要专项确认。

## 验收门

1. **H0 原型**（不通过就停下，回来重新选型）：Mac 与 Android 上，自定义地址加载空间里带相对路径 CSS／JS／图片的页面；CSP 能拦住 `fetch('https://…')`；文档开始脚本先于页面脚本替换 localStorage；JS 调宿主能拿到返回值；Flutter 3.44 下 Android、iOS、macOS 编译通过，Windows 至少编译通过。
2. **资源边界**：`../`、绝对路径、`.aicove/`、其他空间 ID 的请求全部失败；外网请求、顶层跳转、弹窗、权限请求全部被拒。
3. **存档往返**（离线测试）：字符串、数字字符串、JSON 对象和数组、带空格的 JSON 文本、中文、空字符串，读回后与原值逐字节一致；超过 5 MiB 时抛 `QuotaExceededError`。
4. **落盘时机**：停止改动后写一次；退后台和关闭时立即写；一次游玩只产生一个 run，撤销后存档回到开局前。
5. **并发修改**：游戏开着时用文件工具改存档，下一次写盘报冲突、弹出两个选项，任何一方的内容都不丢。
6. **横屏**：手机进入后横屏、退出后恢复；`aicove-orientation` 的三个值都生效。
7. **导入**：单文件、多文件、ZIP 解包后的路径都通过路径规则，导入能撤销。
