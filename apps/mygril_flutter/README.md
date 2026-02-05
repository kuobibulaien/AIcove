# MyGril Flutter 前端

本目录存放 Flutter 前端源码与构建产物。目标平台：Web（集成到 FastAPI 的 `/app` 路径）、Android、Windows。

## 环境准备

1. 安装 Flutter SDK（稳定版，3.22+）
2. 安装平台依赖：
   - Android：Android Studio + SDK + 平台工具
   - Windows：Visual Studio（含 C++ 桌面开发）

## 初始化项目（首次）

本仓库已包含 `android/`、`windows/`、`web/` 等平台目录，通常**不需要**再执行 `flutter create .`。

如果你是把本目录单独拷贝出来、或平台目录缺失，可以在本目录执行以下命令重新生成平台目录：

```bash
cd apps/mygril_flutter
flutter create .
```

随后执行依赖安装：

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
flutter build web --release --base-href /app/ --pwa-strategy none --dart-define=API_BASE_URL=/
# 产物输出到 build/web
# FastAPI 已在 cloud_backend/main.py 自动尝试挂载 apps/mygril_flutter/build/web 到 /app
```

构建完成后启动后端：

```bash
cd ../../cloud_backend
python main.py
# 浏览器访问 http://localhost:8000/app/#/
```

## 目录结构

- `lib/`：应用源码（Riverpod + GoRouter + 分层目录）
- `pubspec.yaml`：依赖与元信息
- `web/`：Flutter Web 模板（`flutter create .` 生成）
- `build/web`：Web 构建产物（被 FastAPI 挂载到 `/app`）

## 📚 文档索引

- [docs/README.md](./docs/README.md) - 文档库索引（推荐从这里开始）
- [界面布局图.md](./界面布局图.md) - 详细的界面布局文档，包含窄屏和宽屏模式的布局说明
- [API_ARCHITECTURE.md](./API_ARCHITECTURE.md) - 聊天调用链/架构说明（以当前实现为准）
- [AUDIO_PLAYER_GUIDE.md](./AUDIO_PLAYER_GUIDE.md) - 音频播放器使用指南
- [AUDIO_TEST_GUIDE.md](./AUDIO_TEST_GUIDE.md) - 音频测试指南

## 功能里程碑（前端）

- M1：联系人列表 + 聊天页（移动端两级，桌面双栏）+ 非流式聊天 + 自动 TTS 播放
- M2：完整 MoeTalk 主题细节、联系人编辑与删除、设置与提供方选择
- M3：多平台打包与优化
