# Database Guidelines

## 当前状态

- 默认数据库是 SQLite，路径通常为 `cloud_backend/data/sync.db`。
- ORM 使用 SQLAlchemy。
- Agent Context Studio Phase 1 数据在 `cloud_backend/data/agent_context_admin.json`，不写数据库。

## 数据变更规则

- 改表结构、删数据、批量更新属于高风险操作，必须先确认。
- 涉及同步 v2、回收站、备份恢复时，先明确兼容策略。
- 生产环境建议配置加密 key，避免重启后无法解密历史数据。

## 禁止模式

- 在未说明迁移方案时直接改模型字段语义。
- 绕过回收站或同步范围直接删除用户数据。
- 把包含 PII 的真实数据写入文档、日志或测试 fixtures。

