# DSHM Android 运行时实现分析

## Evidence snapshot

- DSHM：`RochelimitDawn/DSHM`，检查提交 `74968dcf84a6115b386362ff6d309184f58ceba5`。
- 官方 DSH：`deepseek-ai/deepseek-harness`，检查提交 `141eb6fef83422698aef7a981029e843e8161534`，版本 `0.1.0-rc.8`，Node 要求 `^22.19.0 || >=24.0.0`。
- DSHM 当前运行时仍固定在 DSH `0.1.0-rc.6`，说明 Android 兼容层和上游版本必须成对发布，不能假定 npm 升级后继续可用。

## 核心结论

DSHM 没有把 Harness 重写成 Kotlin，也没有通过远程服务器代理 Harness。它在 Android 应用沙箱里装配 Termux 风格的 arm64/bionic 用户空间，用 Android 可执行的 Node.js 启动官方 `@deepseek-ai/dsh`，再让浏览器访问本机 `127.0.0.1:3080`。

```text
Kotlin / Compose 壳
  -> RuntimeManager
    -> Termux arm64 prefix + Node + DSH
      -> node dsh/lib/bin.js web --port 3080
        -> Harness WebUI / Cordis 插件树
          -> 云端模型 API
```

## 运行时构建

`runtime-builder/build_runtime.sh` 在 Linux CI 上完成：

1. 下载 Termux `bootstrap-aarch64.zip`，重建 `SYMLINKS.txt` 中的链接。
2. 从 Termux 仓库解析并解包 `nodejs`、`ripgrep`、`git`、`bash` 及依赖闭包。
3. 在宿主机执行 `npm install --prefix <prefix>/lib @deepseek-ai/dsh@<pinned-version>`。
4. 安装 pnpm，供 `dsh plugin --profile web` 使用。
5. 使用 Android NDK/bionic 交叉编译 `node-pty`；失败时允许 PTY 降级。
6. 对已安装的 DSH 构建产物应用 Android 兼容补丁。
7. 收集 proot、loader、libtalloc、android-shmem 和依赖动态库。
8. 输出 `runtime.zip`、`metadata.json`、`native-libs.tar.gz`，元数据包含版本、架构、体积、SHA-256 和下载地址。

## Android 可执行文件落点

Android SELinux 不允许从普通 `filesDir` 执行二进制。DSHM 把可执行文件放进 `jniLibs/arm64-v8a`，并伪装成共享库名称：

- `node` -> `libnode.so`
- `bash` -> `libbash.so`
- `sh` -> `libsh.so`
- `rg` -> `librg.so`
- `proot` -> `libproot.so`

Gradle 设置 `jniLibs.useLegacyPackaging = true`，让这些文件安装后解包到 `applicationInfo.nativeLibraryDir`；`filesDir/bin` 只保存指向该目录的符号链接。运行时通过绝对路径执行这些文件。

## 启动与环境

DSHM 的实际启动命令为：

```text
<nativeLibraryDir>/libnode.so
  --expose-internals
  <filesDir>/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js
  web --port 3080
```

关键环境变量：

- `PREFIX=<filesDir>/usr`
- `HOME=<filesDir>/home`
- `DSH_HOME=<filesDir>/dsh-home`
- `PATH=<filesDir>/bin:<nativeLibraryDir>:<prefix>/bin:...`
- `LD_LIBRARY_PATH=<nativeLibraryDir>:<prefix>/lib`
- `DSH_RG_PATH`、`DSH_BASH_PATH`、`DSH_SH_PATH`
- `PNPM_NODE`、`PNPM_CJS`
- 可选 `DSH_SUBSYSTEM_ARGV`、`DSH_SUBSYSTEM_ENV`、`DSH_ROOT_ARGV`

启动前会检查 Node 和 DSH 入口、修正凭据文件权限，启动后轮询 `127.0.0.1:<port>`。前台 Service 持有 Node 进程并使用常驻通知，返回 `START_STICKY`。

## DSH Android 兼容补丁

`patch_runtime.js` 当前处理的关键差异：

1. `node-pty` 改为懒加载，原生模块缺失时只降级 PTY，不阻止 Harness 启动。
2. 文件搜索允许用 `DSH_RG_PATH` 替换桌面版 `@vscode/ripgrep` 二进制。
3. Windows 专用 `koffi` FFI 在 Android 上替换为不执行的兼容 stub，避免静态导入阶段崩溃。
4. Android 不支持系统原生文件打开器时返回可理解的路径提示。
5. 会话、附件和文件原子创建中被 SELinux 拒绝的 hard-link 改为 `rename` 或排他 `copyFile`。
6. Bash 与 sandbox 插件改用 native library 目录中的可执行文件。
7. Android 没有 bubblewrap/Landlock 时将 DSH 本地 sandbox runner 降级为 none；安全边界退回 Android 应用沙箱。
8. Bash、sandbox、terminal 可以用 `proot argv` 包裹进入 Debian/Ubuntu rootfs。
9. proot 的 loader、临时目录、guest PATH/HOME 通过专用环境变量修正。
10. Root 模式用 `su -c` 包裹 Bash 命令。
11. DSH 插件安装改为用 Node 绝对路径执行 `pnpm.cjs`，避免 app 数据目录 noexec。

这些补丁直接匹配编译后的上游文件内容，是版本敏感做法。Aicove 应把补丁变成带断言的版本化 patch set，并尽可能用正式 Cordis provider 替代对编译产物的字符串替换。

## Linux 用户空间与权限

- 基础模式：Termux bash 在应用 UID 下执行。
- proot 模式：下载 Debian/Ubuntu rootfs，使用 fake-root Linux 用户空间；可以获得 apt 和标准目录结构，但 Android 内核权限仍是应用 UID。
- Root 模式：仅 DSH Shell 命令通过 Magisk/KernelSU `su` 以 UID 0 执行；Node/Harness 服务本身仍在应用 UID 下。

## 插件

DSHM 没有另造插件协议，而是执行：

```text
node <dsh-bin> plugin --profile web add <tgz-or-git-spec>
```

移动端导航也是普通 DSH/Cordis Web 插件。插件安装失败按 best-effort 处理，不阻止核心服务启动。含桌面原生模块、安装脚本或不支持 bionic 的插件仍需单独适配。

## 更新与恢复

- 运行时通过 Release `metadata.json` 在线获取，下载后校验 SHA-256。
- 解压前检查空间并停止旧进程，解压到临时目录后再替换正式 prefix。
- App 版本和运行时版本分开；纯 App 升级可保留运行时、会话和工作区。
- 当前校验是 SHA-256 完整性校验，不是发布者签名验证；Aicove 应增加签名清单和上一版可回滚槽位。

## 已知限制

- DSHM APK 只构建 `arm64-v8a`，`minSdk=33`；这不是 Termux 运行时的理论下限，Termux 当前完整包支持 Android 7+。
- DSHM 的 Android 适配停留在 DSH rc.6，而官方当前检查版本是 rc.8。
- `node-pty` 是 best-effort，失败会损失持久终端能力。
- Web 服务监听 loopback，但 Android 各应用共享网络命名空间；若没有认证，其他本机应用理论上也可探测端口。
- DSHM 是 GPL-3.0；官方 DSH 是 MIT。直接复制 DSHM 源码会引入分发许可义务。

## Primary sources

- <https://github.com/RochelimitDawn/DSHM/blob/74968dcf84a6115b386362ff6d309184f58ceba5/runtime-builder/build_runtime.sh>
- <https://github.com/RochelimitDawn/DSHM/blob/74968dcf84a6115b386362ff6d309184f58ceba5/runtime-builder/patch_runtime.js>
- <https://github.com/RochelimitDawn/DSHM/blob/74968dcf84a6115b386362ff6d309184f58ceba5/android/app/src/main/java/com/siliconleap/app/runtime/RuntimeManager.kt>
- <https://github.com/RochelimitDawn/DSHM/blob/74968dcf84a6115b386362ff6d309184f58ceba5/android/app/src/main/java/com/siliconleap/app/runtime/TermuxEnv.kt>
- <https://github.com/deepseek-ai/deepseek-harness/blob/141eb6fef83422698aef7a981029e843e8161534/docs/architecture.md>

