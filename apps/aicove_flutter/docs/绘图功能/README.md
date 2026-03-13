# 绘图功能

> 更新日期：2026-03-06

AI 角色可以通过 `draw_image` 工具调用来生成图片。用户在聊天中说"画一张图"之类的话，AI 就会自动调用绘图工具，生成图片后以图片消息的形式发送到聊天中。

---

## 功能总览

| 项目 | 说明 |
|------|------|
| 插件名称 | 绘图工具 (ImagePlugin) |
| 工具名称 | `draw_image` |
| 触发方式 | 用户在聊天中要求画图，AI 自动调用 |
| 支持渠道 | NovelAI 等支持图片生成的渠道 |
| 图片存储 | 本地存储（应用文档目录） |

---

## 文件地图

> "这个功能出问题了，我该去哪个文件找？"

| 文件 | 负责什么 |
|------|----------|
| `lib/src/features/plugins/image/image_plugin.dart` | **核心引擎** - 提供 draw_image 工具定义、执行图片生成请求、保存图片 |
| `lib/src/features/plugins/image/image_config.dart` | **配置模型** - 定义所有绘图参数（尺寸、步数、画师串等） |
| `lib/src/features/plugins/plugin_providers.dart` | **状态管理** - ImagePluginConfigNotifier，管理配置的读写和持久化 |
| `lib/src/ui/features/plugins/pages/image_plugin_detail_page.dart` | **设置页面** - 绘图功能的配置界面（选渠道、选模型、调参数） |
| `lib/src/ui/features/plugins/pages/draw_image_tool_description_page.dart` | **工具描述页面** - 管理 draw_image 工具描述与预设 |
| `lib/src/features/chat/services/chat_send_service.dart` | **聊天服务** - AI 调用枢纽，负责发消息、执行工具调用、收集图片结果 |
| `lib/src/features/chat/presentation/widgets/message_bubble.dart` | **消息气泡** - 在聊天中显示生成的图片 |

---

## 工作流程

用最简单的话描述"用户说画图 → 图片出现在聊天"的完整过程：

```
用户说 "画一只猫"
      |
      v
ChatSendService 把消息发给 AI
（同时附上 draw_image 工具定义 + 简短路由提示）
      |
      v
AI 理解后决定调用 draw_image 工具
返回：{ name: "draw_image", arguments: { prompt: "1girl, cat ears, ..." } }
      |
      v
ImagePlugin._handleDrawImage() 执行：
  1. 检查参数是否合法
  2. 找到配置中选择的渠道和模型
  3. 调用 AgentApiClient.generateImage() 发请求
  4. 收到图片数据，保存到本地文件
  5. 返回结果 { success: true, images: [{ localPath: "..." }] }
      |
      v
ChatSendService 收到结果：
  - 提取图片 -> 创建 ImageBlock
  - 构建 Message（包含文字 + 图片）
  - 投递到聊天记录
      |
      v
MessageBubble 渲染：
  - 文字部分 -> 在气泡内显示
  - 图片部分 -> 显示为可点击的图片（无气泡）
```

### 非视觉模型下的图片描述优先级（新增）

当当前聊天模型不支持视觉输入，但上下文里有图片时，系统会按这个顺序处理：

1. 先读取图片消息里已有的生图提示词（`ImageBlock.prompt`）
2. 若没有提示词，再调用视觉辅助模型做图片转文字
3. 最终写回请求历史时，不再伪装成普通助手文案，而是输出隐藏的图片上下文标记
4. 若仍拿不到描述，也会保留“这里有图片”的结构化标记，而不是降级成自然语言摘要

这样可以优先复用真实生图参数，减少额外一次视觉模型调用。

新增原因：

- 旧做法会把“助手上一条发了一张图片，生图提示词/内容摘要：...”当成 assistant 正文塞回历史
- 模型容易把这句当作自己上一轮说过的话继续续写
- 现在改成 `__AICOVE_IMAGE_CONTEXT__{...}` 这类隐藏标记，只表达“这轮有图”，不伪装成聊天正文
- 同轮工具续写时，`draw_image` 的 tool result 也会带上 `delivered_to_chat` 或 `image_delivery_pending`，让模型知道图片已发出还是仍在排队

---

## 工具描述固定块

`draw_image` 的主要规则现在不再靠长篇 system prompt 传递，而是写进工具自己的描述里。

```
draw_image.description
+ prompt.description
+ negative_prompt.description
+ width.description
+ height.description
```

- 这些内容由 `ImageConfig.effectiveToolDescriptionBlocks` 提供
- 设置入口是「绘图设置页 -> 绘图工具描述」
- `getSystemPrompt()` 不再额外注入绘图路由提示，避免出现预设外的隐藏指令
- 旧版纯文本 `drawingSystemPrompt` 仍会自动迁移成新的描述块，避免老配置失效

这次改完后，聊天链路里真正负责“怎么写提示词、尺寸怎么选、负面词怎么写”的，是工具 schema，不是系统提示词正文。

---

## 配置参数说明

### 基础配置

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| 绘图渠道 | 自动选择 | - | 从已添加的支持图片的渠道中选择 |
| 绘图模型 | 自动选择 | - | 该渠道下可用的模型 |
| 宽度 | 832 | 256-2048 | 图片宽度（像素） |
| 高度 | 1216 | 256-2048 | 图片高度（像素） |
| 采样步数 | 28 | 1-100 | 越高质量越好，但越慢 |
| 提示词强度 | 5.0 | 1.0-20.0 | 越高越贴近提示词，但可能死板 |
| 生成张数 | 1 | 1-4 | 一次生成几张图 |
| 负面提示词 | (空) | - | 不希望出现的元素 |

### 常见尺寸搭配

| 用途 | 宽 x 高 | 说明 |
|------|----------|------|
| 竖图（人像） | 832 x 1216 | 官方推荐，适合角色立绘 |
| 横图（风景） | 1216 x 832 | 适合场景图 |
| 方图 | 1024 x 1024 | 通用 |
| 小方图 | 512 x 512 | 快速预览 |

### 采样步数参考

| 步数 | 速度 | 质量 | 适合场景 |
|------|------|------|----------|
| 20 | 快 | 一般 | 快速预览 |
| 28 | 中等 | 好 | 日常使用（推荐） |
| 35 | 较慢 | 很好 | 追求细节 |
| 50 | 慢 | 精细 | 出图收藏 |

### 提示词强度参考

| 强度 | 效果 | 说明 |
|------|------|------|
| 3.5 | 自由创作 | AI 自由发挥，可能偏离提示词 |
| 5.0 | 均衡（推荐） | 兼顾准确和创意 |
| 7.0 | 较贴切 | 紧密跟随提示词 |
| 9.0+ | 强制模式 | 严格按提示词来，但可能出现伪影 |

---

## 工具描述预设与画师串预设

现在有两套独立预设：

- 工具描述预设：控制 `draw_image` 工具怎么向模型说明规则
- 画师串预设：控制最终生图 prompt 前面自动拼什么风格词

### 工作方式

```
工具调用规则 = 全局选中的工具描述预设
最终图片 prompt = 角色绑定画师串预设 或 全局选中的画师串预设 + AI 生成的 prompt
最终 negative prompt = 画师串负面词 + 全局默认负面词 + 本次调用传入的 negative_prompt
```

- 工具描述预设放在 `systemPromptPresets`
- 画师串预设放在 `artistPresets`
- 角色卡还能额外绑定“工具描述预设名”和“画师串预设名”
- 聊天发送时，会把角色绑定的工具描述预设改写进 `draw_image` schema
- 真正执行绘图时，会优先使用角色绑定的画师串预设；没有绑定才回退到全局选中预设

### 操作入口

绘图设置页 → 绘图工具描述

绘图设置页 → 工具描述预设 / 画师串预设

角色编辑页 → 专属绘图提示

---

## 提示词书写规范

系统内置了 NovelAI 的提示词规范，AI 会按这个规范生成 Tag。规范要点：

### Tag 顺序

```
人物数量 → 角色特征 → 动作表情 → 场景背景 → 构图镜头 → 光影氛围 → 质量标签
```

示例：
```
1girl, long hair, blue eyes, school uniform, standing, smile, looking at viewer,
outdoors, cherry blossoms, upper body, sunlight,
masterpiece, best quality, very aesthetic, absurdres
```

### 默认质量标签

AI 会自动在末尾加上：`masterpiece, best quality, very aesthetic, absurdres`

### 常用负面提示词

`lowres, bad anatomy, bad hands, watermark, text, missing fingers, extra digits`

---

## 图片存储

生成的图片保存在本地，路径格式：

```
{应用文档目录}/generated_images/{渠道ID}/{模型ID}/{时间戳}_{序号}.png
```

例如：
```
/data/user/0/com.aicove/documents/generated_images/novelai/nai-diffusion-4/1708765432_1.png
```

支持的格式：自动检测（PNG / JPG / WEBP），默认 PNG。

---

## 渠道选择逻辑

系统按以下优先级选择绘图渠道和模型：

```
渠道选择:
  1. 用户手动指定的渠道 (selectedProviderId)
  2. 第一个支持图片的已启用渠道

模型选择:
  1. 用户手动指定的模型 (selectedModelId)
  2. 渠道自定义配置中的默认模型
  3. 该渠道的第一个可用模型
```

渠道可用的前提条件：
- 渠道已启用 (enabled = true)
- 已填写 API 密钥
- 渠道类型支持图片生成 (modelType = 'image' 或 capabilities 包含 'image')

绘图设置页里的模型列表也按同一口径收敛：
- 只显示「渠道管理」里已显示的模型
- 且该模型必须带图像生成标签（也就是生图标签）
- 隐藏模型不会再出现在绘图设置里，也不会被绘图工具当成可用模型

---

## 故障排查

### 问题：绘图功能不可用 / AI 不调用画图

检查清单：
1. 设置中「绘图工具」是否已启用
2. 是否至少添加了一个支持图片的渠道（如 NovelAI）
3. 该渠道是否已启用、API 密钥是否已填写
4. 该渠道下是否有可用的模型

### 问题：生成失败 / 报错

可能原因：
- API 密钥过期或余额不足
- 网络连接问题
- 请求参数超出范围（如尺寸过大）
- 渠道服务暂时不可用

### 问题：图片质量不好

优化方向：
1. 增加采样步数（28 → 35 → 50）
2. 调整提示词强度（5.0 → 7.0）
3. 添加合适的画师串预设
4. 补充负面提示词（排除不想要的元素）
5. 确保 AI 按 NovelAI Tag 规范生成提示词

### 问题：生成速度慢

影响速度的因素（从快到慢）：
- 步数：20 < 28 < 35 < 50
- 尺寸：512x512 < 832x1216 < 1216x1216
- 张数：1 < 2 < 4

### 问题：在「绘图提示词模板」里新建预设后爆红（`_dependents.isEmpty`）

已知触发链路：
- 新建预设弹窗关闭后，输入框 `TextEditingController` 被立即释放，动画尾帧仍可能访问该 controller
- 同时页面初始化迁移逻辑若在 `initState` 里直接改 Riverpod 状态，会放大异常并引发后续框架断言

修复策略（2026-03-04）：
- 预设迁移改为首帧后写入（`addPostFrameCallback`），避免在构建生命周期内修改 provider
- 名称弹窗里的 controller 改为首帧后释放，避免关闭动画阶段访问已释放对象

验证方式：
- Widget 测试：`test/ui/features/plugins/pages/draw_image_tool_description_page_test.dart`
- 运行验证：`flutter run --no-resident`，进入绘图提示词模板页面连续新建预设不应再红屏

---

## 技术架构图

```
┌──────────────────────────────────────────────────┐
│                    配置层                         │
│                                                   │
│  ImageConfig (image_config.dart)                  │
│  ├── 渠道/模型选择                                │
│  ├── 默认参数（尺寸、步数、强度等）                │
│  ├── 工具描述固定块 / 工具描述预设                 │
│  └── 画师串预设                                   │
│            ↕ 持久化: SharedPreferences             │
│  ImagePluginConfigNotifier (plugin_providers.dart) │
└──────────────────────┬───────────────────────────┘
                       │
                       v
┌──────────────────────────────────────────────────┐
│                    业务层                         │
│                                                   │
│  ImagePlugin (image_plugin.dart)                  │
│  ├── getTools()        → 提供 draw_image 工具定义 │
│  ├── getSystemPrompt() → 提供简短工具路由提示     │
│  └── _handleDrawImage()→ 执行图片生成             │
│       ├── _resolveTarget() → 选渠道+模型          │
│       ├── 拼角色/全局画师串 → 组最终 prompt       │
│       ├── AgentApiClient.generateImage() → 调API  │
│       └── _saveImages() → 保存图片到本地          │
└──────────────────────┬───────────────────────────┘
                       │
                       v
┌──────────────────────────────────────────────────┐
│                    调用层                         │
│                                                   │
│  ChatSendService (chat_send_service.dart)         │
│  ├── 组装工具列表 + 简短路由提示                   │
│  ├── 按角色绑定改写 draw_image 工具描述            │
│  ├── 调用 AI API，获取回复 + 工具调用              │
│  ├── 执行 draw_image → 收集图片结果               │
│  └── 构建 Message(TextBlock + ImageBlock)          │
└──────────────────────┬───────────────────────────┘
                       │
                       v
┌──────────────────────────────────────────────────┐
│                    展示层                         │
│                                                   │
│  MessageBubble (message_bubble.dart)              │
│  ├── TextBlock → 气泡内显示文字                   │
│  └── ImageBlock → 无气泡直接显示图片              │
│       └── 支持点击预览、长按菜单                  │
└──────────────────────────────────────────────────┘
```

---

## 相关代码入口

- 绘图插件核心：`lib/src/features/plugins/image/image_plugin.dart`
- 绘图配置模型：`lib/src/features/plugins/image/image_config.dart`
- 状态管理：`lib/src/features/plugins/plugin_providers.dart` → `imagePluginConfigProvider`
- 设置页面 UI：`lib/src/ui/features/plugins/pages/image_plugin_detail_page.dart`
- 工具描述管理 UI：`lib/src/ui/features/plugins/pages/draw_image_tool_description_page.dart`
- 角色绑定编解码：`lib/src/features/chat/domain/persona_prompt_codec.dart`
- 聊天调用入口：`lib/src/features/chat/services/chat_send_service.dart` → `executeApiCall()`
- 消息渲染：`lib/src/features/chat/presentation/widgets/message_bubble.dart`
