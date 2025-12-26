# 推荐命令

## 系统环境
- **操作系统**: Windows
- **终端**: Git Bash（所有命令必须在 Git Bash 中执行）

## Flutter 开发命令

### 依赖管理
```bash
flutter pub get              # 安装依赖
flutter pub upgrade          # 升级依赖
```

### 运行与调试
```bash
# Web 开发
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000

# Android 调试
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000

# Windows 调试
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8000
```

### 构建
```bash
# Web 发布版本
flutter build web --release --dart-define=API_BASE_URL=/

# Android APK
flutter build apk --release

# Windows 版本
flutter build windows --release
```

### 代码质量
```bash
flutter analyze              # 静态代码分析
flutter test                 # 运行测试
```

## Git 命令（Git Bash）
```bash
git status                   # 查看状态
git add .                    # 添加所有更改
git commit -m "message"      # 提交更改
git push                     # 推送到远程
git pull                     # 拉取更新
```

## 常用 Bash 命令
```bash
ls                           # 列出文件
ls -la                       # 列出所有文件（包括隐藏）
cd <path>                    # 切换目录
pwd                          # 显示当前路径
cat <file>                   # 查看文件内容
grep <pattern> <file>        # 搜索文件内容
find . -name <pattern>       # 查找文件
```

## 注意事项
1. 所有 shell 命令必须在 Git Bash 中执行
2. 使用 `flutter run` 时，可以按 `r` 热重载，按 `R` 热重启，按 `q` 退出
3. Windows 上的路径分隔符在 Git Bash 中使用 `/` 而不是 `\`