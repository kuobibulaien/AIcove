# 项目概览

## 项目目的
MyGril 是一个 AI 对话应用，目标是让 AI 像真实恋人一样发消息陪伴用户。该应用采用多平台部署策略，部署后独立运行，所有 AI 调用在 Flutter 端完成，后端仅负责用户认证和数据同步。

## 技术栈
- **前端框架**: Flutter (SDK 3.22+)
- **状态管理**: Riverpod (`flutter_riverpod: ^2.5.1`)
- **路由**: GoRouter (`go_router: ^14.2.0`)
- **HTTP 客户端**: http (^1.2.2) 和 dio (^5.4.0)
- **本地存储**: shared_preferences (^2.3.2), sqflite (^2.3.0), flutter_secure_storage (^9.0.0)
- **音频**: just_audio (^0.9.39), audio_session (^0.1.21)
- **文件/图片选择**: file_picker (^8.0.3), image_picker (^1.0.7)
- **其他**: uuid (^4.2.1), flutter_slidable (^3.1.0), crop_your_image (^2.0.0)

## 目标平台
- Android（优先）
- Windows
- Web（集成到 FastAPI 的 `/app` 路径）

## 项目架构
采用分层架构，主要目录结构：
- `lib/src/core/`: 核心功能（API、配置、主题、工具类、通用组件）
- `lib/src/features/`: 功能模块（chat、emoji、plugins、settings、sync、tts、logs）
- `lib/main.dart`: 应用入口

## 核心特性
- 多模态信息生成（文本、语音、图片）
- 主动消息触发机制
- 云同步功能
- TTS（文字转语音）支持
- 表情符号系统
- 自动回复触发器