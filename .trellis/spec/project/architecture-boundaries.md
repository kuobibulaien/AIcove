# 架构边界

## Flutter 分层

```text
UI / Page
  -> Application UseCase
    -> Port / Contract / Interface
      -> Infrastructure Adapter
        -> Service / Repository / API / DB
```

## 命名约定

| 类型 | 命名 |
|---|---|
| 应用层端口 | `*Port` |
| 运行时契约 | `*Contract` / `*Runtime` / `*Channel` |
| 外部供应商适配 | `*Adapter` |
| 具体实现 | `*Service` / `*Repository` |

## 必须抽象的情况

1. UI 跨层调用业务能力。
2. 外部供应商能力：模型、TTS、生图、Embedding、云端 API。
3. Agent 能力：先有 `AgentDefinition`、`ContextProfile`、装配权限、输出契约和投递通道。
4. 同一能力被 2 个以上 feature 使用。

## 禁止模式

- UI 直接拼 API 请求或直接操作数据库。
- 聊天发送链路绕过 `chat_actions.dart` / 应用层端口。
- 新增 Agent 时只加 prompt，不定义上下文、工具策略和输出契约。

