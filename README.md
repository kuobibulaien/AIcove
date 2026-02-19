# AIcove - AI Girlfriend App

# 项目宪法（每次写代码都必须遵守；如做不到先停下来问）
## 0) 只动允许的目录
- 允许修改：`apps/aicove_flutter/`（前端）、`cloud_backend/`（后端）
- 根目录其他文件夹多为参考资料：默认不改（见 `readme.md`）

## 1) 目录地图（像“零件箱 vs 房间”）
- 前端 UI 层：`apps/aicove_flutter/lib/src/ui/`
  - 主题/颜色：`apps/aicove_flutter/lib/src/ui/theme/`（优先用 tokens，不要页面里手写颜色）
  - 公共组件：`apps/aicove_flutter/lib/src/ui/shared/`（含 widgets, effects, animations）
  - 页面路由：`apps/aicove_flutter/lib/src/ui/features/<feature>/pages/`
- 后端业务层：`apps/aicove_flutter/lib/src/features/<feature>/`
  - 业务模型：`domain/`
  - 数据与服务：`data/`
  - 状态管理：`providers/` 或 `*_providers.dart`
- 公共核心：`apps/aicove_flutter/lib/src/core/` (utils, logic)
- 备注：如果发现 `lib/core/` 和 `lib/src/core/` 并存，默认以 `lib/src/` 为主。

## 2) UI/主题强约束（禁止"单页作品"）
- 颜色/字体/间距/圆角：只能用现有 Theme/tokens（`apps/aicove_flutter/lib/src/ui/theme/tokens.dart`）
- 按钮/弹窗/提示：优先复用 Moe 系列公共组件（见 `apps/aicove_flutter/docs/公共组件总览.md`）
- 统一导入：`import 'package:aicove_flutter/src/ui/shared/widgets/index.dart'`
- 提示统一用 MoeToast（不要到处自己写 SnackBar/Toast）

## 3) 宽屏/窄屏必须同步
- 断点与页面骨架以 `apps/aicove_flutter/界面布局图.md` 为准（900px）
- 改页面时要说明：窄屏/宽屏是否都适配，哪里需要联动修改

## 4) 数据流/状态管理
- 统一使用 Riverpod（不要混用多套状态管理）
- UI 不直接发请求：页面只负责展示与触发 action；请求放 data/service/provider

## 5) API 调用与错误处理
- 后端 REST：优先走 `apps/aicove_flutter/lib/src/core/api_client.dart`
- AI/消息相关：优先看聊天入口 `apps/aicove_flutter/lib/src/features/chat/chat_actions.dart`；架构说明见 `apps/aicove_flutter/API_ARCHITECTURE.md`（以当前实现为准）
- 错误提示/重试逻辑要统一，别每个页面各写一套

## 6) 复用规则（防止越写越散）
- 发现"重复代码 ≥ 2 处"：先抽到 `apps/aicove_flutter/lib/src/ui/shared/widgets/` 或 `apps/aicove_flutter/lib/src/core/utils/`，再实现需求
- **主动抽象**：写新功能时，如果某段逻辑/组件明显可复用（如通用按钮、格式化工具、数据转换），应直接写成公共类，而非等重复后再抽取
- **入库登记**：新建的公共组件/工具类必须登记到 `apps/aicove_flutter/docs/公共组件总览.md`，格式参照已有条目（名称、文件路径、用途说明）

## 7) 交付检查清单（避免基础操作遗漏）
- 依赖是否安装：`flutter pub get`
- 后端是否启动（需要接口时）
- 本次改动后至少编译/运行一次；并说明怎么验证（窄/宽屏各看一眼）

# 项目背景信息
项目目标：开发一个ai对话app（安卓端优先），使ai像真实恋人一样发消息陪伴用户。
项目进度：项目需要多平台部署，部署后独立运行，所有 AI 调用在 Flutter 端完成；后端以认证/数据同步为主，并提供备份、云触发器、云记忆、额度等云端数据能力。
项目实现思路：暂定技术栈为前端flutter跨平台部署。核心思路是调用工具生成多模态信息，同时能自主调用工具实现主动消息触发，使得ai能像一个真实的异地伴侣一样发送消息，解决传统单个大模型只能生成文本和不稳定多模态信息的痛点。

资源文档库：`apps/aicove_flutter/docs/`（含索引文件 `apps/aicove_flutter/docs/README.md`）
- 文档索引：`apps/aicove_flutter/docs/README.md`
- 施工进度：`apps/aicove_flutter/docs/施工进度/项目推进中.md` - 日期+事件的简要记录
- 公共组件：`apps/aicove_flutter/docs/公共组件总览.md`（小白版）、`apps/aicove_flutter/docs/前端公共组件库.md`（完整版）
在动手之前必须先了解本项目相应的公共组件！！！
- 后端服务：`apps/aicove_flutter/docs/后端公共服务库.md`
## 目录结构
- `apps/aicove_flutter`: Flutter 客户端代码
- `cloud_backend`: Python 后端代码（以认证/云同步为主，也包含备份/触发器/云记忆/额度等云端数据能力）

## 快速开始 (Windows)
1. 运行 `start.ps1`（会自动安装后端依赖、可选构建 Web，并启动后端服务）。
2. 开发调试：进入 `apps/aicove_flutter` 运行 `flutter run`（需要后端接口时，保持第 1 步的服务在跑）。


