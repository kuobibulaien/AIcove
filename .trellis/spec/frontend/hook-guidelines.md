# Riverpod / Provider Guidelines

AIcove Flutter 使用 Riverpod 管理状态。这里的 “hook” 指 Trellis 模板名，不是 React Hooks。

## 使用边界

- UI 通过 provider / use case 获取状态和动作。
- Provider 不应承担大量业务编排，复杂流程下沉到 service 或 use case。
- 聊天发送、历史读取等主链路优先走已有应用层端口。

## 数据获取

- REST API 统一走 `api_client.dart`。
- AI/消息主链路走 `chat_actions.dart` 及其拆分服务。
- 外部供应商能力通过 Adapter 接入，不在 provider 中直接写供应商分支。

## 禁止模式

- UI 直接调用底层 API client。
- provider 内部写大段流程控制且无法单测。
- 绕过聊天上下文真相源规范组装模型输入。

