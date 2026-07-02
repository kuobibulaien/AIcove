# Logging Guidelines

## 记录原则

- 日志用于排查认证、同步、触发器、备份、Agent Context 面板问题。
- 关键失败要包含模块、操作、资源 id 或请求 id。
- 长期可复用的排查结论写入文档，临时日志放 `scratch/diagnostics/`。

## 敏感信息

禁止记录：

- 明文密码、token、API key。
- 未脱敏的用户隐私、聊天内容、联系人详情。
- 生产数据库完整路径或连接串。

