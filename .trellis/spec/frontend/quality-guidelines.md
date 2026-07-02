# Flutter Quality Guidelines

## 必跑验证

代码完成后运行：

```powershell
cd apps/aicove_flutter
flutter run --no-resident
```

如果只改文档或云端，不需要运行 Flutter，但最终报告要说明未运行原因。

## 工具链卡死排查

如果 `flutter --version`、`flutter devices` 或 `flutter run` 在进入项目编译前长时间无输出，先按工具链层排查：

- 检查并清理异常残留的 `dart.exe`、`flutter`、`git.exe` 进程。
- 确认 `flutter doctor -v` 是否卡在 Windows Version / WMI、网络下载或 Gradle artifact 阶段。
- 若直接运行 `flutter_tools.dart` 也无输出超时，优先判断为 Flutter SDK / tool cache 异常；删除重装 SDK 前必须按高风险操作确认。
- 重装后重新执行 `flutter --version`、`flutter devices`、`flutter doctor -v`、`flutter pub get` 和 `flutter run --no-resident` 验证闭环。

## 测试策略

- 发现 bug 先补复现测试，再修。
- 聊天主链路、上下文组装、同步和 Agent Runtime 变更要增加或更新测试。
- UI 小改可以用运行验证加人工说明覆盖。

## 禁止模式

- 为了通过验证删除或弱化测试。
- 未说明风险就跳过手机运行验证。
- 大范围重构时不拆阶段、不列回滚点。
