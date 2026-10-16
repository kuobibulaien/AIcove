# 0083 Windows 关闭窗口：首次询问，可常驻托盘

- 状态：accepted（2026-10-15 用户提出：首次关闭时让用户选完全退出还是后台继续）
- 日期：2026-10-15
- 关联：ADR0079（主动回复判断与执行拆分）

## 背景

桌面端的主动回复、主动来电都靠应用进程里的定时器（`AnalyzerScheduler`、`AutoReplyTriggerController`）。Windows 点关闭就结束进程，主动回复随之停止；也没有托盘图标可以把应用留在后台。

## 决定

1. **托盘选型**：引入 `tray_manager`（与现有 `window_manager` 同一作者，0.5.3）。图标用 `assets/icons/tray/app_icon.ico`（复制自 Windows runner 图标）。左键单击托盘显示窗口，右键菜单「显示 AIcove／退出」。
2. **拦截关闭**：`WindowsCloseGuard`（`ui/shared/widgets/windows_close_guard.dart`）只在 Windows 生效，启动时 `setPreventClose(true)`。关闭按钮、Alt+F4 都进入 `onWindowClose`。
3. **首次询问并记住**：设置项 `windows_close_behavior`（ask／tray／exit，默认 ask，本机设置不同步）。为 ask 时弹「关闭 AIcove」：完全退出／后台运行，选择写回设置；点弹窗外关闭则窗口不关。可在「设置 · 通用设置 · 关闭窗口时」改。
4. **退出路径**：销毁托盘 → `setPreventClose(false)` → `windowManager.destroy()`。

## 代价

- 新增一个原生插件依赖，Windows 原生侧未在本机编译验证（Mac 构建通过）。
- 只解决「关窗口不退进程」；开机自启、系统睡眠后定时器补偿不在本次范围。
- Mac／Linux 行为不变。

## 验收门

Windows 实机：首次关闭弹窗、选后台运行后托盘出现且主动回复照常触发、托盘右键退出能结束进程、设置里改为完全退出后直接退出。
