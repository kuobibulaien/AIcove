import 'ui_block.dart';
import 'ui_expression.dart';

/// A catalog component the model can write with props alone.
class UiCatalogComponent {
  const UiCatalogComponent(this.name, this.use, this.props, [this.rules = '', this.lines = '']);

  final String name;

  /// When to use it, for the model.
  final String use;

  /// Shape of the parsed props; the prompt shows it for components written
  /// as JSON (quick panels), the line example otherwise.
  final String props;
  final String rules;

  /// Line syntax example (`ui_lines.dart`), without the fence.
  final String lines;
}

/// Catalog components rendered by the app (ADR0073 交互组件, batch U1).
/// The renderer registry and the prompt both read this list.
const kUiCatalog = [
  UiCatalogComponent(
    'checklist',
    '要用户逐项完成或核对的事：配置步骤、准备清单、排查前的自查',
    '{title?, items: [string | {text, note?}]}',
    '一行一项，「| 」后写一句补充说明；用户勾选的结果会在下一轮的 ui_state 里（done 是已勾选的下标）',
    'checklist voice-setup\n# 语音通话准备\n选音色预设 | 决定角色用什么声音说话\n填语音渠道的 Key\n选识别来源',
  ),
  UiCatalogComponent(
    'steps',
    '一步步照着做的操作流程，每步一两句话',
    '{title?, items: [{title, text?}]}',
    '一行一步：「标题 | 说明」；每步只写一个动作；界面路径写成「设置 · 渠道」这样的文字',
    'steps get-key\n# 拿 DeepSeek Key\n打开 DeepSeek 开放平台 | 用手机号注册登录\nAPI Keys → 创建 | Key 只显示一次，马上复制',
  ),
  UiCatalogComponent(
    'decision-tree',
    '排障、选型、判断是否适用：按用户的回答走到结论',
    '{title?, start?, other?, nodes: [{id, text, detail?, options?: [{label, next}], other?}]}',
    '「[节点 id] 问题或结论」开一个节点，下面每行「- 选项 -> 目标 id」；「> 」行是这个节点的补充说明；没有选项的节点是结论；从第一个节点开始。每个问题会自动多一个「其他」，用户可写自己的情况连同前面的选择填进输入框，所以选项只列常见情况，不要自己写「其他」「都不是」；只有选项确实穷尽时在节点那行末尾加「| other=false」',
    'decision-tree no-image\n# 角色为什么不画画\n[plugin] 角色的插件里开了「绘图」吗？\n> 角色编辑页 → 管理插件\n- 开了 -> ask\n- 没开 -> fix\n[fix] 到角色编辑页打开「绘图」插件就行\n[ask] 把角色完整上下文页的截图发给我',
  ),
  UiCatalogComponent(
    'quiz',
    '帮用户自测是否理解了某个概念',
    '{title?, questions: [{question, options: string[], answer?: number, explanation?}]}',
    '「? 」开头是题目，下面每行一个选项，正确的那个末尾加 ✓；「> 」行是解析',
    'quiz ctx-quiz\n# 小测一下\n? 上下文窗口满了会怎样？\n- 直接报错\n- 旧消息被压缩成摘要 ✓\n> AIcove 会把旧消息整理成摘要，原文仍留在本机。',
  ),
  UiCatalogComponent(
    'form',
    '要继续做事必须先拿到用户的几项信息时：写角色卡缺名字和性格、排查前要知道用的是哪家渠道',
    '{title?, fields: [{key, label, type?: text|textarea|number|select|multiselect, options?, placeholder?, required?, other?}], submit?}',
    '一行一项：「标签 | 类型 | 选项或提示 | 必填」，类型是 文字、长文字、数字、单选、多选（不写就是文字）；单选多选的选项用「 / 」隔开，其他类型这一格是输入框里的提示；后面两格可省。最多 6 项；单选和多选会自动多一个可填写的「其他」，选项不要自己写「其他」，确实穷尽时加一格「无其他」；「@submit: 文字」改提交按钮；能按合理默认直接做的就别发表单，直接做并说明默认值；用户点提交后各项会以「标签：值」填进输入框，由用户发送给你；绝不用它收 API Key、密码等机密（要 Key 用 Key 输入卡片）',
    'form new-role\n# 新角色的基本信息\n@submit: 就按这些写\n名字 | 文字 | 比如：小雪 | 必填\n性别 | 单选 | 女 / 男 / 不设定\n性格 | 多选 | 温柔 / 毒舌 / 元气 / 高冷\n背景故事 | 长文字 | 几句话就行，没有就空着',
  ),
  UiCatalogComponent(
    'stat-grid',
    '几个并列的数字：token 数、条数、占比',
    '{title?, items: [{label, value, unit?, delta?, trend?: up|down|flat, tone?: positive|negative|neutral, note?}]}',
    '一行一个：「标签 | 数值 | 单位 | 变化量 | 备注」，后面的格可省；要标趋势加一格 trend=up 或 trend=down，好坏加 tone=positive 或 tone=negative；越低越好的数（如 token、耗时）下降时写 tone=positive',
    'stat-grid ctx-stats\n# 小雪的上下文\n系统提示词 | 3,120 | token\n聊天记录 | 18,400 | token | -2,100 | 压缩后 | trend=down | tone=positive',
  ),
  UiCatalogComponent(
    'data-table',
    '十行以上、需要排序或搜索的结构化数据',
    '{title?, columns: [{key, label, type?: string|number}], rows: [{<key>: value}], pageSize?}',
    '第一行是表头，之后一行一条，格子用「|」隔开；全是数字的列自动按数字排序；「@pageSize: 10」改每页条数',
    'data-table role-plugins\n# 各角色的插件\n角色 | 插件数 | 预设\n小雪 | 4 | 默认\n阿澈 | 2 | ARGO',
  ),
];

Set<String> get kUiCatalogNames => {for (final c in kUiCatalog) c.name};

/// Action components (ADR0094): panels that list the user's own data and
/// change it. Only the assistant chat renders them; their props and prompt
/// live with the assistant. Named here so every renderer and the saved
/// state know them.
const kUiActionComponents = {
  'roles', 'drawing-presets', 'voice-presets', 'settings', 'providers', //
};

/// Panel primitives; catalog components may be nested among them.
const kUiPrimitives = {
  'panel', 'row', 'stack', 'grid', 'card', 'tabs', 'collapse', 'divider', //
  'text', 'stat', 'badge', 'progress', 'callout',
  'slider', 'select', 'segmented', 'switch', 'input', 'button',
};

/// The prompt section describing interactive blocks to the model.
String uiBlockPrompt() {
  final catalog = [
    for (final component in kUiCatalog)
      [
        '  <component name="${component.name}">',
        '    <use>${component.use}</use>',
        '    <rules>${component.rules}</rules>',
        '    <example>\n```$kUiBlockFenceLanguage\n${component.lines}\n```\n    </example>',
        '  </component>',
      ].join('\n'),
  ].join('\n');
  final functions = kUiExpressionFunctions.join(' ');
  return '''
## 交互组件

<nature>交互组件是回复正文里的一段 Markdown 代码块，由 AIcove 画成能点、能改的界面。它是输出格式，不是工具：不要用工具调用它，也不要等它返回结果。</nature>
<when>
  <principle>组件是让用户直接操作的，不是装饰。结论和要点写在正文，要用户动手的部分放进组件：去掉组件，回复仍然回答了问题。</principle>
  <use>满足任一项就出组件：要用户照着做的三步以上的操作（steps）；必须先问用户几项信息才能继续（form）；要用户逐项准备或核对的清单（checklist）；排障或选择要先问用户几个问题（decision-tree）；给出一组可比较的数字（stat-grid）；十行以上的条目（data-table）；用户在估算或比较方案，结果取决于几个可调的量（panel）。</use>
  <avoid>闲聊、观点、一两句话就能答完的事；写作类请求（角色卡正文、人设、文案）要的是可复制的文字，不要放进组件；没有可靠数据时不要为了出组件编数字；组件只是把正文已有的内容再摆一遍。</avoid>
  <choose>一条回复一般一个块，最多三个。能用目录组件就不用 panel；只有存在会改变结果的控件，或几个部件要共享状态时才用 panel。</choose>
  <followup>用户在组件里的操作会在下一轮以 ui_state 提供。追问已有组件时，直接用其中的当前值作答，不要让用户复述，也不要重复输出同一个块；要改组件就输出一个新块（新 id）。</followup>
</when>
<syntax>语言标识为 `$kUiBlockFenceLanguage` 的代码块。下面目录里的组件用逐行写法，不写 JSON、不用括号：
  第一行：组件名 和 id（简短英文，只用字母、数字、- 和 _，对话内唯一），用空格隔开。
  「# 」开头的一行是标题；「@名字: 值」设一个顶层属性；其余每行是一项，格子用「 | 」隔开；「> 」开头的行是上一项的补充说明。
  各组件的行怎么写见目录里的例子。只有 panel 和快捷面板用 JSON。代码块放在正文中它所属的位置，前后用自然语言承接。</syntax>
<catalog>
$catalog
</catalog>
<panel>
  <shape>{"component": "panel", "id", "title?", "state": {名: 初始值}, "computed"?: {名: "公式"}, "children": [...]}。state 是用户可改的值；computed 由 state 推导，可以互相引用，不能循环。</shape>
  <syntax>panel 的内容是 JSON，属性平铺在顶层；字符串里的英文双引号写成 \\"，不要注释，写完数一下括号都闭合了。</syntax>
  <children>从上到下排列，只用下面的原语；要清单、步骤等目录组件就在 panel 外另写一个块。控件用 bind 指向 state 名；visible: "{条件}" 为假时隐藏该节点。</children>
  <formula>属性值里的 {公式} 实时求值：整个值只有一个 {…} 时保留原类型，与文字混写时数字按千分位、最多两位小数显示；{{ 和 }} 表示字面花括号。公式只能用数字、'文字'、+ - * / % ^、比较、&& || !、a ? b : c、obj.key、list[i]、[a, b]，函数 $functions，常量 pi e；没有赋值、循环和自定义函数。range 包含两端，最多 1000 项。</formula>
  <actions>button 三选一：ask: "文字" 把这段文字（可含 {公式}）填进用户的输入框，用户确认后自己发送，写成用户可能想问的完整问题；set: {state 名: 值} 修改状态；copy: "文字" 复制到剪贴板。</actions>
  <primitives>
    布局：row、stack、grid {columns?: 1-4}、card {title?}、tabs {items: [标签]}（第 i 个子节点是第 i 页）、collapse {title, open?}、divider
    展示：text {text, tone?, size?: sm|base|lg}、stat {label, value, unit?, note?, precision?, highlight?, tone?}、badge {text, tone?}、progress {value, max?, label?}、callout {text, title?, tone?}
    控件：slider {bind, label, min, max, step?, unit?}、select {bind, label, options}、segmented {bind, label?, options}、switch {bind, label}、input {bind, label, type?: text|number, placeholder?}、button {label?, ask | set | copy}
    tone 取 default|muted|positive|negative|warning|info；options 写成 ["文字"] 或 [{label, value}]
  </primitives>
  <example>
```$kUiBlockFenceLanguage
{"component": "panel", "id": "ctx-budget", "title": "上下文估算",
 "state": {"turns": 40, "perTurn": 300, "window": 64},
 "computed": {"used": "turns * perTurn * 2 / 1000", "ratio": "min(used / window, 1)"},
 "children": [
   {"component": "slider", "bind": "turns", "label": "保留轮数", "min": 10, "max": 200, "step": 10},
   {"component": "slider", "bind": "perTurn", "label": "每句约多少 token", "min": 50, "max": 1000, "step": 50},
   {"component": "segmented", "bind": "window", "label": "上下文窗口（K）", "options": [32, 64, 128]},
   {"component": "stat", "label": "聊天记录约占", "value": "{round(used, 1)}", "unit": "K token"},
   {"component": "progress", "value": "{ratio}", "max": 1, "label": "占窗口 {round(ratio * 100)}%"},
   {"component": "callout", "tone": "warning", "text": "超过窗口，旧消息会被压缩", "visible": "{used > window}"},
   {"component": "button", "ask": "按保留 {turns} 轮、窗口 {window}K，帮我调一下上下文设置"}]}
```
  </example>
</panel>''';
}
