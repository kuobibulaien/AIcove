# model_list_page.dart 修复方案

## 问题描述

文件 `c:\ide\mygril\apps\mygril_flutter\lib\src\features\chat\presentation\pages\model_list_page.dart` 在第115-122行存在格式损坏。

### 损坏的代码（第110-125行）
```dart
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                            backgroundColor: colors.dialogWarning,
                            label: const Text('已停用'),
                            labelStyle: TextStyle(color: colors.text, fontSize: 11),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
```

**问题分析**：
- 第116行直接跳到了 `backgroundColor`，缺少了前面的代码结构
- 缺少了显示API Key、Domain和Capabilities的代码
- 代码结构不完整，缺少多个必要的Widget

## 修复方案

### 步骤1：定位损坏位置
文件路径：`c:\ide\mygril\apps\mygril_flutter\lib\src\features\chat\presentation\pages\model_list_page.dart`
损坏行号：**第110行到第125行**

### 步骤2：替换代码

将第110-125行的内容替换为以下完整代码：

```dart
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _extractDomain(provider.apiBaseUrl),
                        style: TextStyle(color: colors.muted, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (provider.apiKeys.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Key: ${provider.apiKeys.first}',
                            style: TextStyle(color: colors.muted, fontSize: 11, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: provider.capabilities.map((cap) {
                          final capInfo = _getCapabilityInfo(cap);
                          return Tooltip(
                            message: capInfo.label,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: colors.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: colors.primary.withOpacity(0.3),
                                  width: 0.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(capInfo.icon, size: 12, color: colors.primary),
                                  const SizedBox(width: 4),
                                  Text(
                                    capInfo.shortLabel,
                                    style: TextStyle(
                                      color: colors.primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      if (!provider.enabled)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Chip(
                            visualDensity: VisualDensity.compact,
                            backgroundColor: colors.dialogWarning,
                            label: const Text('已停用'),
                            labelStyle: TextStyle(color: colors.text, fontSize: 11),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
```

### 步骤3：验证辅助函数

确认文件末尾（第972行之后）包含以下辅助函数，如果没有则添加：

```dart
class _CapabilityInfo {
  final String label;
  final String shortLabel;
  final IconData icon;
  const _CapabilityInfo(this.label, this.shortLabel, this.icon);
}

_CapabilityInfo _getCapabilityInfo(String capability) {
  switch (capability) {
    case 'chat':
      return const _CapabilityInfo('聊天对话', '聊天', Icons.chat_bubble_outline);
    case 'embedding':
      return const _CapabilityInfo('向量嵌入', '嵌入', Icons.scatter_plot);
    case 'tts':
      return const _CapabilityInfo('语音生成', '语音', Icons.record_voice_over);
    case 'image':
      return const _CapabilityInfo('图片生成', '图片', Icons.image_outlined);
    default:
      return const _CapabilityInfo('未知', '?', Icons.help_outline);
  }
}
```

### 步骤4：验证 `_extractDomain` 函数

确认文件中存在 `_extractDomain` 函数（通常在第950行左右），如果没有则添加：

```dart
String _extractDomain(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.host.isNotEmpty ? uri.host : url;
  } catch (e) {
    return url;
  }
}
```

## 修复后的效果

修复完成后，模型管理页面的每个渠道卡片将显示：
1. ✅ 渠道名称和图标
2. ✅ API Base URL 的域名
3. ✅ API Key（脱敏显示）
4. ✅ **能力标签**（聊天、嵌入、语音、图片，带图标和Tooltip）
5. ✅ 停用状态标记（如果已停用）

## 验证步骤

修复后，运行以下命令验证：

```powershell
cd c:\ide\mygril\apps\mygril_flutter
flutter run -d chrome
```

然后：
1. 打开应用的"模型管理"页面
2. 查看每个渠道卡片是否正确显示所有信息
3. 检查能力标签是否显示并有正确的图标和颜色

## 备注

- 修复过程中如果遇到语法错误，检查括号是否匹配
- 确保没有遗漏逗号
- `provider.capabilities` 字段已在 `ProviderAuth` 类中定义（位于 `app_settings.dart`）
- 默认情况下，旧的provider会自动获得 `['chat']` 能力
