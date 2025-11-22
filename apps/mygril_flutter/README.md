# MyGril Flutter 前端

本目录存放 Flutter 前端源码与构建产物。目标平台：Web（集成到 FastAPI 的 `/app` 路径）、Android、Windows。

## 环境准备

1. 安装 Flutter SDK（稳定版，3.22+）
2. 安装平台依赖：
   - Android：Android Studio + SDK + 平台工具
   - Windows：Visual Studio（含 C++ 桌面开发）

## 初始化项目（首次）

建议在本目录内直接创建 Flutter 工程并覆盖默认模板：

```bash
cd apps/mygril_flutter
flutter create .
```

执行后会生成 `android/`、`windows/`、`web/` 等平台目录。随后执行依赖安装：

```bash
flutter pub get
```

> 说明：仓库已包含 `lib/` 与 `pubspec.yaml` 的定制内容，`flutter create .` 会保留现有文件，不会覆盖。

## 运行与调试

Web（开发调试）：

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

Android：

```bash
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Windows：

```bash
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8000
```

> `API_BASE_URL` 也可缺省，默认 `http://localhost:8000`。

## 构建 Web 并集成 FastAPI

```bash
flutter build web --release --dart-define=API_BASE_URL=/
# 产物输出到 build/web
# FastAPI 已在 backend/app/main.py 自动尝试挂载 apps/mygril_flutter/build/web 到 /app
```

构建完成后启动后端：

```bash
cd backend
bash scripts/run_server.sh
# 浏览器访问 http://localhost:8000/app/#/
```

## 目录结构

- `lib/`：应用源码（Riverpod + GoRouter + 分层目录）
- `pubspec.yaml`：依赖与元信息
- `web/`：Flutter Web 模板（`flutter create .` 生成）
- `build/web`：Web 构建产物（被 FastAPI 挂载到 `/app`）

## 📚 文档索引

- [界面布局图.md](./界面布局图.md) - 详细的界面布局文档，包含窄屏和宽屏模式的布局说明
- [COMPOSER_UPDATE.md](./COMPOSER_UPDATE.md) - Composer 组件更新说明，包含新UI设计和功能菜单说明
- [API_ARCHITECTURE.md](./API_ARCHITECTURE.md) - API 架构文档
- [AUDIO_PLAYER_GUIDE.md](./AUDIO_PLAYER_GUIDE.md) - 音频播放器使用指南
- [AUDIO_TEST_GUIDE.md](./AUDIO_TEST_GUIDE.md) - 音频测试指南
- [CONSOLE_USAGE.md](./CONSOLE_USAGE.md) - 控制台使用说明
- [前端说明.md](./前端说明.md) - 前端开发详细说明（注意：此文件可能存在编码问题）

## 功能里程碑（前端）

- M1：联系人列表 + 聊天页（移动端两级，桌面双栏）+ 非流式聊天 + 自动 TTS 播放
- M2：完整 MoeTalk 主题细节、联系人编辑与删除、设置与提供方选择
- M3：多平台打包与优化
