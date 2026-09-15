---
status: accepted
date: 2026-09-05
---

# 诊断证据与 Agent 自动抓取

## 背景

用户明确：日志主要方便 agent 排查，日常遇到 BUG 只描述现象，让 agent 自行抓取；同意《自动排障诊断方案》按阶段交付。ADR0005 的低频前端入口保留，但仅中文摘要、阶段完成与错误类型不足以解释静默拒绝、重试与分段动画故障。

## 决定

- 第一批继续通过 FrontendDiagnosticsPort/Service 复用 AppLogger；schema2 envelope 补 appRunId、来源序号/单调时间、Android构建身份和写入健康。DiagnosticFacts 只接受数值/布尔状态及枚举原因；child 固定异步父子关联，消息/最终raw映射可沿 trace 回查。
- 只在分段结构、动画裁决变化、TTS阶段或应用裁决记录，不逐token/逐帧写文件，不改变生成/滚动/播放规则。流中瞬态更新与收尾持久化分开标记。
- Android Gradle 自动生成源码输入指纹、逐文件哈希清单和构建结束一致性检查，通过内部 MethodChannel 获取；不新增导出组件或系统权限。明确不跟踪热重载，也不是包含所有SDK/JDK环境的可复现构建保证。
- `tool/collect_diagnostics.py` 默认只读已授权ADB调试包；字段允许列表过滤旧应用/网络/trace索引，不读取聊天DB、模型payload、URL/授权头，不保存自由文本日志。输出有限大小、私有权限的 manifest/summary/operations 包；从时间窗补全父子操作，旧网络记录没有明确traceId时不按重试共用turnId强行关联。
- 受控错误说明/码+有界代码栈；未知自由文本仍省略且明确标记，不能承诺自动识别自然语言里的所有病患正文。正文复现需另行最小范围授权。

## 代价与边界

故障前后缓冲、帧摘要、统一磁盘预算、原生退出信息、正式release受控导出和远程连接仍属后续批次。当前读取活跃文件不是原子快照，最后半行/写盘失败/过滤缺段须说明。手机不在线或未授权就不能远程读私有日志。全局AppLogger旧存储仍有开销，不能因采集异步就宣称无性能影响。

## 验收门

真实ChatActions离线分段在360/1000px产生的动画裁决与widget实际一致；真实TTS resolver成功/owner拒绝保留原轮关联；采集器验证脱敏、实际trace/index目录、Android列式ls输出、半行/容量、跨运行隔离与父子闭包；真机验证构建身份落盘和只读拉取；全量Flutter测试与相关静态检查。候选证据不是自动裁决的根因。
