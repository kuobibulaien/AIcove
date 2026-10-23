---
status: accepted
date: 2026-10-22
---

# 0106：macOS 关闭应用沙盒，shell 命令免确认

关联：ADR0098 第 4、6 条（`workspace_shell`）、ADR0093（AIcove酱全权限）、ADR0073（授权模式）。取代 ADR0098 第 4 条「每条命令都要真人确认」与「macOS 受沙盒限制」两点。

## 背景

用户问：Pi 能直接用系统 shell，AIcove 为什么只能在沙盒里跑？

- Pi 是终端里启动的命令行程序，权限就是当前登录用户的权限（不是 root）。
- AIcove 的 macOS 两份 entitlements 都写了 `com.apple.security.app-sandbox`（Flutter 模板默认）。沙盒会遗传给子进程，`workspace_shell` 的命令只能访问应用容器，依赖 Xcode 命令行工具的 `git`、`python3` 等用不了。
- macOS 版通过 GitHub 发布 dmg，不上 Mac App Store；只有上架 Mac App Store 才强制沙盒（App Review Guidelines 2.4.5(i)）。

## 决定

1. **macOS 关闭应用沙盒**：Debug 与 Release entitlements 去掉 `com.apple.security.app-sandbox`，其余条目不动。以后若要上架 Mac App Store，需要重新开沙盒，命令改由沙盒外的辅助程序执行。
2. **shell 免确认**：用户选择与 Pi 一致——命令直接执行，没有审核模型，也不弹确认。
   - `workspace_shell` 不再标 `requiresHumanApproval`；AIcove酱 的风险档由 major 改为 reversible（闸门直接放行；用户打开「每次都问我」时逐条确认，拒绝即不执行）。
   - `WorkspaceShell.run` 仍只接受经过本次运行闸门放行的调用（`allowed` 或 `approved`），闸门外直接调用一律拒绝。
   - 装配范围不变：仍只有桌面端、内核执行器上的 AIcove酱 有 shell；后台杂活 Agent、普通工具模式角色、脚本内调用依然拿不到。
   - 命令改动不可撤销、`.aicove/` 快照还原、改动登记索引等 ADR0098 机制不变。
3. **macOS 数据搬家**：不在沙盒里后，`path_provider` 返回的目录换了位置（Documents 变成用户自己的 `~/Documents`，Application Support 变成 `~/Library/Application Support/<bundle id>`）。
   - 未沙盒的 macOS 和 Windows／Linux 一样，把应用数据放在 Application Support，不放进 `~/Documents`。
   - 首次启动由 `AppDataMigration` 把容器 `~/Library/Containers/<bundle id>/Data/` 下的 `Documents`（数据库与已知文件夹）和 `Library/Application Support/<bundle id>`（全部条目）搬过去，并改写偏好设置与数据库里存的旧绝对路径；数据库搬不动就本次继续用容器里的旧位置。
   - 偏好设置（`NSUserDefaults`）由 `MainFlutterWindow.swift` 在 Flutter 启动前从容器的 plist 拷一次；新位置已有 `flutter.` 开头的键时不覆盖。读不到容器文件时下次启动重试。
   - 判断依据是环境变量 `APP_SANDBOX_CONTAINER_ID`：沙盒进程一定有，非沙盒进程没有。

## 其他系统（调查结论，本轮不改）

| 系统 | 现状 | 能否做到 Pi 那样 | 说明 |
|---|---|---|---|
| Windows | 未打包的 Win32 程序（我们用 GitHub Actions 发 zip），本来就没有沙盒，`workspace_shell` 已走 PowerShell，以当前用户中等完整性级别运行 | 已经可以 | 不提权（UAC 管理员需另行弹窗）；若将来改成 MSIX，full-trust 包仍是普通用户权限，只是 AppData 写入可能被虚拟化 |
| 安卓 | 每个应用是独立 Linux 用户＋SELinux 沙盒，所有应用都一样，关不掉 | 不能 | 能调 `/system/bin/sh` 和系统自带的 toybox 小工具；targetSdk ≥ 29 起不能执行应用数据目录里的文件（W^X），自带程序只能打包进 APK 的原生库目录；访问整个存储需「所有文件访问」权限（Google Play 审核严格）。Termux 靠停在 targetSdk 28 并离开 Play 商店绕开 |
| iOS | 系统沙盒，应用进程不能创建子进程（fork／posix_spawn 失败），App Store 指南 2.5.2 禁止下载并执行改变功能的代码 | 不能 | 只能在本进程里解释执行（现有 `workspace_run_js` 的 QuickJS 就是这条路），读写限于自己的容器和用户选中的文件 |

所以手机端维持 ADR0098 的做法：只有 `workspace_run_js`，没有 shell。

## 代价

- 关掉沙盒后，AIcove 能读写当前用户能访问的所有文件；shell 又不确认，模型一条错误命令（例如删除文件、上传数据）会直接执行且无法撤销。防线只剩「每次都问我」开关和模型本身。
- 不能上架 Mac App Store。
- 首次升级要搬数据（同一磁盘上是改名，不复制）；容器里不认识的文件留在原处。
- 未签名／临时签名的构建访问旧容器时，macOS 可能弹「想访问其他 App 的数据」，用户拒绝则本次搬不了、下次再试。

## 验收

1. 离线（已过）：shell 无确认直接执行；「每次都问我」逐条询问且拒绝不执行；闸门外调用不执行；搬家的路径定位、文件搬运、偏好与数据库路径改写都有测试。全量测试与改动前对比无新增失败（剩余 21 个失败改动前就有：缺本地酒馆预设、`tmp_repro` 等）。测试统一由 `test/flutter_test_config.dart` 固定使用文档目录，与运行测试的电脑是否有沙盒无关。
2. Mac 实机演练（已过，2026-10-22）：Release 构建换成独立 bundle id `com.example.aicoveSandboxQA`，先以带沙盒的签名启动（`sandbox_check`=1，生成容器数据，并人为放入旧路径的数据库行、偏好和文件），再以当前 entitlements 签名启动：`sandbox_check`=0；数据库、`local_credentials`、日志等搬到 `~/Library/Application Support/<bundle id>`；12 个偏好键导入且旧路径被改写；数据库里旧路径被改写；`~/Documents` 没有写入；容器里搬空的目录被删除；第二次启动不再搬也无报错。没有出现系统的「访问其他 App 数据」弹窗。演练数据已删除，未碰用户真实数据。
3. 待用户验收：真实数据首次升级（8 GB 左右，同盘改名）；在 AIcove酱 里让它运行 `git --version`、`python3 --version`、`ls ~` 等命令，确认能用系统工具且不弹确认。
