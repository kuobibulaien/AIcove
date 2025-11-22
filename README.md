# MyGril - AI Girlfriend App

## 项目简介
MyGril 是一个基于 Flutter 开发的跨平台 AI 伴侣应用，旨在提供像真实恋人一样的聊天体验。

## 主要功能
- **多模态交互**: 支持文本、图片、语音消息。
- **自主消息**: AI 可以根据上下文主动发起对话。
- **本地优先**: 聊天记录存储在本地，保护隐私。
- **多模型支持**: 兼容 OpenAI 及其他兼容 API。

## 目录结构
- `apps/mygril_flutter`: Flutter 客户端代码
- `cloud_backend`: Python 后端代码 (仅负责认证和同步)

## 快速开始 (Windows)
1. 运行 `start.ps1` 初始化环境。
2. 进入 `apps/mygril_flutter` 运行 `flutter run`。

## 更新日志
- **2025-11-20**: 完成了主动回复功能的闭环实现。
    - 新增 `ContextAnalyzer`：在每次对话后分析上下文，智能规划未来的触发器（应用 SRP 原则）。
    - 新增 `AutoReplyService`：监听触发器事件并调用 AI 主动发起对话。
    - 优化 `ChatActions`：集成触发逻辑，支持无用户输入的 AI 主动发消息。
    - 架构遵循 KISS 原则，复用现有 `AutoReplyTriggerController`，避免过度设计后台服务。
- **2025-11-20**: 优化了聊天界面语音气泡 UI。
    - 实现动态宽度：语音条长度随音频时长自动伸缩（80px-220px）。
    - 视觉升级：重构波形动画，移除多余边框，使气泡更清爽现代。
    - 遵循 KISS 原则：在 `AudioPlayerWidget` 内部直接计算布局，避免过度封装。
- **2025-11-20**: 优化了启动脚本 `start.ps1` 的依赖下载逻辑。
    - 恢复默认源优先：移除了强制使用 CN 镜像的配置，确保首选尝试官方源。
    - 增强回退机制：在 `Run-FlutterPubGet` 中实现了"默认 -> TUNA -> Legacy"的三级回退策略，确保在网络不佳时自动切换到国内镜像。
    - 遵循 KISS 原则：通过简单的环境变量控制实现源切换，避免复杂的配置逻辑。