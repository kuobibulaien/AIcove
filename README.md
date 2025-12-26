# MyGril - AI Girlfriend App

# 项目宪法（每次写代码都必须遵守；如做不到先停下来问）
## 0) 只动允许的目录
- 允许修改：`apps/mygril_flutter/`（前端）、`cloud_backend/`（后端）
- 根目录其他文件夹多为参考资料：默认不改（见 `readme.md`）

## 1) 目录地图（像“零件箱 vs 房间”）
- 公共零件箱：`apps/mygril_flutter/lib/src/core/`
  - 主题/颜色/间距：`lib/src/core/theme/`（优先用 tokens，不要页面里手写颜色）
  - 公共组件：`lib/src/core/widgets/`（先查 docs/公共组件总览.md 再决定要不要新写）
  - 通用工具：`lib/src/core/utils/`
  - 通用模型：`lib/src/core/models/`
- 功能房间：`apps/mygril_flutter/lib/src/features/<feature>/`
  - 业务模型：`domain/`
  - 数据与服务：`data/`
  - 页面与组件：`presentation/`
- 备注：如果发现 `lib/core/` 和 `lib/src/core/` 并存，默认以 `lib/src/` 为主，新增代码别往 `lib/core/` 放。

## 2) UI/主题强约束（禁止“单页作品”）
- 颜色/字体/间距/圆角：只能用现有 Theme/tokens（`lib/src/core/theme/`）
- 按钮/弹窗/提示：优先复用现有公共组件（见 `docs/公共组件总览.md`）
- 提示统一用 MoeToast（不要到处自己写 SnackBar/Toast）

## 3) 宽屏/窄屏必须同步
- 断点与页面骨架以 `界面布局图.md` 为准（900px）
- 改页面时要说明：窄屏/宽屏是否都适配，哪里需要联动修改

## 4) 数据流/状态管理
- 统一使用 Riverpod（不要混用多套状态管理）
- UI 不直接发请求：页面只负责展示与触发 action；请求放 data/service/provider

## 5) API 调用与错误处理
- 后端 REST：优先走 `lib/src/core/api_client.dart`
- AI/消息相关：优先遵循 `API_ARCHITECTURE.md` 的术语与分层；实现以现有代码为准
- 错误提示/重试逻辑要统一，别每个页面各写一套

## 6) 复用规则（防止越写越散）
- 发现“重复代码 ≥ 2 处”：先抽到 `core/widgets` 或 `core/utils`，再实现需求

## 7) 交付检查清单（避免基础操作遗漏）
- 依赖是否安装：`flutter pub get`
- 后端是否启动（需要接口时）
- 本次改动后至少编译/运行一次；并说明怎么验证（窄/宽屏各看一眼）

# 项目背景信息
项目目标：开发一个ai对话app（安卓端优先），使ai像真实恋人一样发消息陪伴用户。
项目进度：项目需要多平台部署，部署后独立运行，所有AI调用在Flutter端完成，后端仅负责用户认证和数据同步。
项目实现思路：暂定技术栈为前端flutter跨平台部署。核心思路是调用工具生成多模态信息，同时能自主调用工具实现主动消息触发，使得ai能像一个真实的异地伴侣一样发送消息，解决传统单个大模型只能生成文本和不稳定多模态信息的痛点。

资源文档库：apps\mygril_flutter\docs
（生成的说明文档也写到这个文件夹里，这个文件夹是文档库）
其中apps\mygril_flutter\docs\施工进度\项目推进中.md  用于保存施工进度。日期加事件的简要记录，同时备注对未来开发和排查有用的信息。如有变更则修改以往记录。一切以项目实际情况优先。
## 目录结构
- `apps/mygril_flutter`: Flutter 客户端代码
- `cloud_backend`: Python 后端代码 (仅负责认证和同步)

## 快速开始 (Windows)
1. 运行 `start.ps1` 初始化环境。
2. 进入 `apps/mygril_flutter` 运行 `flutter run`。


