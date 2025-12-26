# 任务完成检查清单

## 代码修改完成后必须执行

### 1. 代码质量检查
```bash
flutter analyze
```
- 确保没有分析错误或警告
- 如有 lint 警告，根据实际情况修复或添加 `// ignore` 注释

### 2. 测试（如有相关测试）
```bash
flutter test
```
- 确保所有测试通过
- 如果添加新功能，考虑编写相应测试

### 3. 本地运行验证
根据修改的平台，选择相应命令：
```bash
# Android 测试
flutter run -d emulator-5554

# Windows 测试
flutter run -d windows

# Web 测试
flutter run -d chrome
```
- 手动验证功能是否正常工作
- 检查 UI 是否符合预期
- 测试边界情况和错误处理

### 4. 格式化代码（可选但推荐）
```bash
flutter format .
```

### 5. 提交前检查
- 检查是否有意外的文件修改
- 确保没有遗留的调试代码或注释
- 确认所有新增文件都已添加到 Git

### 6. 更新文档
- 如果有重大功能变更，更新 README.md 或相关文档
- 在 README.md 的 `## 更新日志` 章节添加更新记录

## 注意事项
- 在 Windows 上必须使用 Git Bash 执行命令
- 确保 Flutter SDK 版本满足要求（3.22+）
- 如果修改了依赖，先运行 `flutter pub get`