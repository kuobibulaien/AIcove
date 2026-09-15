# Lucide 0.257.0：Flutter 3.44 兼容副本

来源：https://pub.dev/packages/lucide_icons/versions/0.257.0
上游：https://github.com/lucide-icons/lucide
许可证：本目录 `LICENSE`（ISC），保留上游版权。

Flutter 3.44 将 `IconData` 标为 final，上游 0.257.0 的 `LucideIconData extends IconData` 无法编译。此副本仅保留运行需要的图标常量、原始字体和许可证；将生成文件中的构造改为 `const IconData(codePoint, fontFamily: 'Lucide', fontPackage: 'lucide_icons')`，不再继承 IconData。

所有 1,000 多个常量名、码点与字体文件保持原样，不替换项目图标或修改全局 pub 缓存。包名保持不变，以保留 fontPackage 和现有 import。SDK 约束更新为 Dart 3；不带上游示例、生成工具及其开发依赖。

校验：应用 `test/ui/theme/lucide_sdk_compatibility_test.dart` 检查字体归属、代表码点与图标绘制；SDK 升级记录另保存全部码点及字体 SHA-256 的比对结果。

后续上游有兼容版时，可改回 hosted 依赖并重跑上述测试及图标外观验收。
