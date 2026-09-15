# Android Linux 环境与权限能力分层

## 关键模型

“Linux 环境”和“Android 权限”是两个正交维度，不应压成一个 Root 开关。

### Linux 用户空间

| 环境 | 提供内容 | 不提供内容 |
|---|---|---|
| Termux prefix | Node、bash、git、rg、基础 Unix 工具 | 完整发行版目录与 apt 生态 |
| proot Debian/Ubuntu | apt、标准 Linux rootfs、fake root | Android 内核 Root、绕过 SELinux、访问其他应用私有数据 |

### Android 执行身份

| 后端 | 身份 | 获得方式 | 主要边界 |
|---|---:|---|---|
| App sandbox | 应用 UID | 无额外授权 | 仅应用私有目录和用户授予的文档/媒体范围 |
| Shizuku/Sui | shell UID 2000 或 root UID 0 | 非 Root 通过 ADB/无线调试启动 Shizuku；Root 可由 Sui/Shizuku 启动 | ADB 权限随 Android/ROM 变化，shell 不能读取其他应用 `/data/user/0` |
| Root | UID 0 | Magisk/KernelSU/APatch 等 `su` 授权 | 仍受 SELinux、Root 管理器策略和 ROM 差异影响 |

## ADB 口径

Android 应用不能像申请相机一样申请一个通用“ADB 权限”。可实现的路径有两类：

1. 用户用电脑或 Android 11+ 无线调试启动 Shizuku，Aicove 通过 Shizuku Binder/UserService 获得 shell UID 能力。
2. Aicove 自己实现并由 ADB 启动一个 shell-UID daemon；这等于重做 Shizuku 的启动、授权、Binder、版本和重启机制，首版没有必要。

因此规划采用 Shizuku API，界面名称使用“ADB/Shizuku 增强”，不能误导成永久系统权限。非 Root Shizuku 每次重启设备后通常需要重新启动；Android 11 以下通常需要电脑。

## 推荐能力集合

运行时探测后返回能力集合，而不是只返回档位：

```text
runtime.node
runtime.pty
linux.termux
linux.proot
android.app_shell
android.shizuku_shell
android.root_shell
android.package_ops
android.settings_ops
android.cross_app_files
storage.shared_workspace
background.foreground_service
```

UI 可以把能力集合归纳成“基础 / ADB 增强 / Root”，但调度层按具体能力选择工具后端。

## 执行后端建议

- `AppProcessBackend`：在 Aicove UID 下运行 Termux/proot，承接默认 DSH workspace、bash 和文件工具。
- `ShizukuBackend`：使用 Shizuku UserService + AIDL，执行 Android 系统命令和允许的 Binder 操作；UID 通过 `Shizuku.getUid()` 验证。
- `RootBackend`：使用 libsu core/service 管理 Root shell 或 RootService，避免手写脆弱的 `su` 进程协议。
- `CapabilityRouter`：按工具声明和用户执行模式选择后端，失败时只向下回落，不静默向上请求权限。

DSH Node 进程保持应用 UID。特权命令通过后端转发，不把整个本地 Web 服务和插件树直接提升到 Root。

## Node 与 Android 原生层通信

Node/Cordis 插件不能直接调用 Flutter MethodChannel 或 Android Binder。建议 Android 原生层启动仅监听 `127.0.0.1` 的 JSON-RPC bridge：

- 每次安装生成 256-bit token，使用 mode 600 文件保存，并通过环境变量只交给 DSH 子进程。
- Cordis 插件把特权请求发给 bridge；bridge 再路由到 app、Shizuku 或 libsu 后端。
- 请求必须包含能力名、工作目录、超时、最大输出和取消 ID；禁止只传不受约束的任意反射调用。
- 日志不记录 token、凭据或完整敏感命令参数。

后续若 loopback 攻击面不可接受，再把 transport 换成文件型 Unix domain socket；上层 RPC 契约不变。

## 向下兼容建议

- 不为 Harness 功能抬高整个 Flutter App 的 `minSdk`；在运行时入口做能力门禁。
- Termux 完整包当前支持 Android 7+，所以 Harness MVP 以 Android 7 / API 24 为运行时下限。
- 首版只交付 `arm64-v8a` Harness；其他 ABI 保持 Aicove UI 可运行但显示“本设备暂不支持本地 Harness”。
- Android 11+ 可在本机完成 Shizuku 无线调试启动；更低版本用电脑 ADB 或 Root；都没有时退回 App sandbox + proot。
- Root、Shizuku、PTY、proot 都分别探测和展示，不把某项失败误判为整个 Harness 不可用。

## Primary sources

- Shizuku API：<https://github.com/RikkaApps/Shizuku-API/blob/master/README.md>
- Shizuku 启动指南：<https://shizuku.rikka.app/guide/setup/>
- libsu：<https://github.com/topjohnwu/libsu>
- Termux Android 支持范围：<https://github.com/termux/termux-app>

