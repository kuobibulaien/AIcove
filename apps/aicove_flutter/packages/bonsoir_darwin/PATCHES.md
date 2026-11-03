# AIcove 本地补丁：广播注册有界等待

基线：pub.dev 的 `bonsoir_darwin 7.1.1` 发布归档，保留原版本、LICENSE 和其余实现。应用通过 `dependency_overrides` 使用此目录，不修改全局 pub cache，也不升级其他依赖。

## 修改范围

- `pubspec.yaml`：去掉上游 monorepo 的 `resolution: workspace`，让此包可作为独立 path 依赖。
- `BonsoirServiceBroadcast.swift`：移除同步 `DNSServiceProcessResult`，改用 `DNSServiceSetDispatchQueue(.main)`；注册完成、失败、停止或 5 秒超时时，只完成一次启动结果。失败／停止释放 DNSServiceRef，停止可重复调用；释放 TXTRecord。
- `SwiftBonsoirPlugin.swift`：`broadcast.start` 的方法结果由注册回调／超时完成，失败返回 `FlutterError`，供 Dart 的现有错误路径处理。

选择主串行队列接收异步回调，是为了与 Flutter channel、停止和超时共用同一队列，避免额外线程同步与回调对象存活管理。这里不再同步等待注册回调。Apple 要求 DNSServiceRef 在其调度队列上释放：[DNS-SD API 头文件](https://github.com/apple-oss-distributions/mDNSResponder/blob/main/mDNSShared/dns_sd.h)。

应用层 `BonjourLanDiscovery` 串行化替换／停止；旧广播的 native dispose 返回后，才提交下一次注册。Dart 对启动另设 6 秒超时，捕获错误后停止并释放半注册实例。DNSServiceRefDeallocate 没有 daemon 注销确认回执，所以无法保证 daemon 已处理注销；短暂重叠由原生 5 秒超时兜底。

## 原生验证

在仓库根目录运行：

```bash
bash apps/aicove_flutter/packages/bonsoir_darwin/tool/test_broadcast.sh
```

脚本直接编译生产的 `BonsoirServiceBroadcast.swift`、`BonsoirService.swift` 和 `Generated.swift`，只以轻量测试壳替代 Flutter channel，不启动或操作 AIcove。

1. **确定性不回调**：真实提交注册，测试壳不安装 socket 回调调度；验证启动方法立即返回、约 5 秒返回 timeout、主队列心跳持续、实例释放且结果只完成一次。
2. **启动中停止**：同样不回调，200 毫秒后停止；验证启动收到取消错误，重复停止只发一次停止事件。
3. **真实 overlap**：不注入 DNS API。旧广播注册成功并保留 10 秒，新广播以同名、同类型、同端口注册后立即释放旧广播；顺序沿用调查材料 `dnssd_handoff.c`。验证本机不回调场景约 5 秒超时，主队列仍可执行心跳。

overlap 依赖当前系统的 mDNSResponder 行为；若将来的系统修好并正常回调，这项按“应超时”写的故障复现会失败，需要更新断言。确定性不回调用例不依赖该系统缺陷。

2026-10-23 本机结果：不回调启动返回 6.70 ms、5.010 s 超时、502 次心跳；取消 0.208 s 返回；真实 overlap 启动返回 1.53 ms、5.009 s 超时、501 次心跳。三项均确认 disposed、仅完成一次。未做 iOS 编译与实际应用前后台操作验收。
