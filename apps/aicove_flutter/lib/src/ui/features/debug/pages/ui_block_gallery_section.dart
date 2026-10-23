import 'package:flutter/material.dart';

import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// Samples of `aicove-ui` interactive blocks (ADR0091) for the UI gallery.
/// State the samples are left in is kept like in a chat, under a debug
/// conversation id.
class UiBlockGallerySection extends StatelessWidget {
  const UiBlockGallerySection({super.key});

  static const conversationId = 'debug_ui_gallery';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeUiBlockScope(
      conversationId: conversationId,
      onAsk: (text) => MoeToast.brief(context, '会填进输入框：$text'),
      child: MoeUiBlockMessage(
        messageId: 'gallery',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MoeSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final sample in _samples) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 2),
                  child: Text(
                    sample.label,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
                MoeUiBlock(code: sample.code, closed: sample.closed),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Sample = ({String label, String code, bool closed});

const List<_Sample> _samples = [
  (
    label: 'checklist · 清单',
    closed: true,
    code: '''
checklist voice-setup
# 语音通话准备
选音色预设 | 决定角色用什么声音说话
填语音渠道的 Key
选识别来源''',
  ),
  (
    label: 'steps · 步骤',
    closed: true,
    code: '''
steps get-key
# 拿 DeepSeek Key
打开 DeepSeek 开放平台 | 用手机号注册登录
充值 | 按量计费，先充一点就够
API Keys → 创建 | Key 只显示一次，马上复制
回到 AIcove 粘贴 | AIcove酱会给你一张输入卡片，Key 不会进聊天记录''',
  ),
  (
    label: 'decision-tree · 决策树（每个问题自动带「其他」，点开可写自己的情况）',
    closed: true,
    code: '''
decision-tree no-image
# 角色为什么不画画
[plugin] 角色的插件里开了「绘图」吗？
> 角色编辑页 → 管理插件
- 开了 -> preset
- 没开 -> fix-plugin
[preset] 绑定的预设关了函数调用吗？
- 关了 -> fix-preset
- 没关 -> ask
[fix-plugin] 到角色编辑页打开「绘图」插件就行
[fix-preset] 预设关了函数调用时，绘图只能走内联标签
[ask] 把角色完整上下文页的截图发给我''',
  ),
  (
    label: 'form · 向用户要信息（必填校验；单选多选自动带「其他」；提交后填进输入框；机密字段不给输入）',
    closed: true,
    code: '''
form new-role
# 新角色的基本信息
@submit: 就按这些写
名字 | 文字 | 比如：小雪 | 必填
性别 | 单选 | 女 / 男 / 不设定
性格（可多选） | 多选 | 温柔 / 毒舌 / 元气 / 高冷 / 话痨 / 腹黑
年龄 | 数字 | 18
背景故事 | 长文字 | 几句话就行，没有就空着，我来补
DeepSeek API Key''',
  ),
  (
    label: 'decision-tree · 长选项（自动改成整行，可换行）',
    closed: true,
    code: '''
decision-tree draw-long
# 角色不画图 · 自查
[q1] 你让它画图的时候，它的反应更像哪一种？
- 完全像没听见，一点要画的意思都没有 -> c1
- 嘴上说画好了、还描述了画面，但聊天里没有图 -> c2
- 直接说自己不能画、没有这个能力 -> c1
[c1] 多半是角色没勾「生图」插件，绘图工具没进上下文。
> 角色编辑页 → 管理插件 → 勾上「生图」。
[c2] 插件关着时它会按旧习惯说「画好了」，先确认插件开着。''',
  ),
  (
    label: 'quiz · 测验',
    closed: true,
    code: '''
quiz ctx-quiz
# 小测一下
? 上下文窗口满了会怎样？
- 直接报错
- 旧消息被压缩成摘要 ✓
- 模型变聪明
> AIcove 会把旧消息整理成摘要，原文仍留在本机。
? API Key 应该发在哪里？
- 直接发在聊天里
- 填进 AIcove酱给的输入卡片 ✓
> 输入卡片直接写进渠道设置，Key 不会进模型上下文。''',
  ),
  (
    label: 'stat-grid · 指标卡',
    closed: true,
    code: '''
stat-grid
# 小雪的上下文
系统提示词 | 3,120 | token
聊天记录 | 18,400 | token | -2,100 | 压缩后 | trend=down | tone=positive
工具 | 6 | 个
占窗口 | 33% | | +5% | trend=up | tone=negative''',
  ),
  (
    label: 'data-table · 数据表（超过一页时出现搜索与翻页）',
    closed: true,
    code: '''
data-table
# 各角色的插件
@pageSize: 5
角色 | 插件数 | 预设 | 上下文
小雪 | 4 | 默认 | 21520
阿澈 | 2 | ARGO | 8800
店长 | 6 | 默认 | 30210
猫猫 | 1 | 无 | 3400
旅行搭子 | 3 | 双人成行 | 12000
学姐 | 5 | 默认 | 17650
AIcove酱 | 0 | 无 | 9100''',
  ),
  (
    label: 'form · 旧 JSON 写法（历史消息兼容，结尾漏写括号也能显示）',
    closed: true,
    code: '''
{"component": "form", "id": "rr-config", "title": "要我改哪些", "fields": [
  {"key": "scope", "label": "改到什么程度", "type": "select", "options": ["除 Key 以外全配好", "先别改"]},
  {"key": "model", "label": "模型", "type": "text", "placeholder": "deepseek-flash"}''',
  ),
  (
    label: 'panel · 联动计算（滑块、分段、提示条件显示、追问）',
    closed: true,
    code: '''
{"component": "panel", "id": "ctx-budget", "title": "上下文估算", "description": "拖一下看看保留多少轮合适",
 "state": {"turns": 40, "perTurn": 300, "window": 64},
 "computed": {"used": "turns * perTurn * 2 / 1000", "ratio": "min(used / window, 1)"},
 "children": [
   {"component": "slider", "bind": "turns", "label": "保留轮数", "min": 10, "max": 200, "step": 10},
   {"component": "slider", "bind": "perTurn", "label": "每句约多少 token", "min": 50, "max": 1000, "step": 50},
   {"component": "segmented", "bind": "window", "label": "上下文窗口（K）", "options": [32, 64, 128]},
   {"component": "grid", "columns": 2, "children": [
     {"component": "stat", "label": "聊天记录约占", "value": "{round(used, 1)}", "unit": "K token", "highlight": true},
     {"component": "stat", "label": "还剩", "value": "{max(window - used, 0)}", "unit": "K token"}]},
   {"component": "progress", "value": "{ratio}", "max": 1, "label": "占窗口 {round(ratio * 100)}%"},
   {"component": "callout", "tone": "warning", "title": "超过窗口", "text": "旧消息会被压缩成摘要", "visible": "{used > window}"},
   {"component": "button", "ask": "按保留 {turns} 轮、窗口 {window}K，帮我调一下上下文设置"}]}''',
  ),
  (
    label: 'panel · 原语大全（标签页、折叠、开关、输入、选择、徽标、复制、按钮改状态）',
    closed: true,
    code: '''
{"component": "panel", "id": "primitives", "title": "原语一览",
 "state": {"name": "小雪", "nsfw": false, "style": "温柔", "level": 2, "opening": "先打招呼，再问用户今天过得怎么样"},
 "children": [
   {"component": "tabs", "items": ["人设", "更多"], "children": [
     {"component": "stack", "children": [
       {"component": "input", "bind": "name", "label": "角色名", "placeholder": "起个名字"},
       {"component": "select", "bind": "style", "label": "说话风格", "options": ["温柔", "毒舌", "元气", "高冷", "话痨"]},
       {"component": "select", "bind": "opening", "label": "开场方式（长选项）", "options": ["先打招呼，再问用户今天过得怎么样", "直接接着上次聊到的话题往下说", "什么都不说，等用户先开口"]},
       {"component": "switch", "bind": "nsfw", "label": "允许成人内容"},
       {"component": "text", "text": "{name} 会用「{style}」的语气说话{nsfw ? '，已允许成人内容' : ''}。"}]},
     {"component": "stack", "children": [
       {"component": "row", "children": [
         {"component": "badge", "text": "已同步", "tone": "positive"},
         {"component": "badge", "text": "实验", "tone": "warning"},
         {"component": "badge", "text": "等级 {level}", "tone": "info"}]},
       {"component": "row", "children": [
         {"component": "button", "label": "升一级", "set": {"level": "{level + 1}"}},
         {"component": "button", "label": "复制名字", "copy": "{name}"}]},
       {"component": "callout", "tone": "info", "text": "按钮的 set 会改状态，copy 会复制到剪贴板。"}]}]},
   {"component": "divider"},
   {"component": "collapse", "title": "展开看说明", "children": [
     {"component": "text", "size": "sm", "tone": "muted", "text": "折叠区里也能放任何原语。"},
     {"component": "card", "title": "卡片", "children": [{"component": "text", "text": "卡片是一块浅底的分组。"}]}]}]}''',
  ),
  (
    label: '生成中占位（围栏还没写完）',
    closed: false,
    code: '{"component": "checklist", "items": [',
  ),
  (
    label: '解析失败退回原文',
    closed: true,
    code: '{"component": "rocket", "fuel": 100}',
  ),
];
