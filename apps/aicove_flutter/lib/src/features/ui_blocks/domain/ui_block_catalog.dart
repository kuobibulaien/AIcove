import 'ui_block.dart';
import 'ui_expression.dart';

/// A catalog component the model can write with props alone.
class UiCatalogComponent {
  const UiCatalogComponent(this.name, this.use, this.props, [this.rules = '']);

  final String name;

  /// When to use it, for the model.
  final String use;
  final String props;
  final String rules;
}

/// Catalog components rendered by the app (ADR0073 交互组件, batch U1).
/// The renderer registry and the prompt both read this list.
const kUiCatalog = [
  UiCatalogComponent(
    'checklist',
    '要用户逐项完成或核对的事：配置步骤、准备清单、排查前的自查',
    '{title?, items: [string | {text, note?}]}',
    'note 是一句补充说明；用户勾选的结果会在下一轮的 ui_state 里（done 是已勾选的下标）',
  ),
  UiCatalogComponent(
    'steps',
    '一步步照着做的操作流程，每步一两句话',
    '{title?, items: [{title, text?}]}',
    '每步只写一个动作；界面路径写成「设置 · 渠道」这样的文字',
  ),
  UiCatalogComponent(
    'decision-tree',
    '排障、选型、判断是否适用：按用户的回答走到结论',
    '{title?, start?, other?, nodes: [{id, text, detail?, options?: [{label, next}], other?}]}',
    '没有 options 的节点是结论；start 缺省为第一个节点；next 写目标节点的 id；每个问题会自动多一个「其他」，用户可写自己的情况连同前面的选择填进输入框，所以 options 只列常见情况，不要自己写「其他」「都不是」；只有选项确实穷尽时才写 other: false',
  ),
  UiCatalogComponent(
    'quiz',
    '帮用户自测是否理解了某个概念',
    '{title?, questions: [{question, options: string[], answer?: number, explanation?}]}',
    'answer 是正确选项的下标（从 0 开始）',
  ),
  UiCatalogComponent(
    'form',
    '要继续做事必须先拿到用户的几项信息时：写角色卡缺名字和性格、排查前要知道用的是哪家渠道',
    '{title?, fields: [{key, label, type?: text|textarea|number|select|multiselect, options?, placeholder?, required?, other?}], submit?}',
    '最多 6 项；select 和 multiselect 会自动多一个可填写的「其他」，options 不要自己写「其他」，选项确实穷尽时写 other: false；能按合理默认直接做的就别发表单，直接做并说明默认值；用户点提交后各项会以「标签：值」填进输入框，由用户发送给你；绝不用它收 API Key、密码等机密（要 Key 用 Key 输入卡片）',
  ),
  UiCatalogComponent(
    'stat-grid',
    '几个并列的数字：token 数、条数、占比',
    '{title?, items: [{label, value, unit?, delta?, trend?: up|down|flat, tone?: positive|negative|neutral, note?}]}',
    'delta 只写变化量；越低越好的数（如 token、耗时）下降时写 tone: positive',
  ),
  UiCatalogComponent(
    'data-table',
    '十行以上、需要排序或搜索的结构化数据',
    '{title?, columns: [{key, label, type?: string|number}], rows: [{<key>: value}], pageSize?}',
  ),
];

Set<String> get kUiCatalogNames => {for (final c in kUiCatalog) c.name};

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
        '    <props>${component.props}</props>',
        if (component.rules.isNotEmpty) '    <rules>${component.rules}</rules>',
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
<syntax>语言标识为 `$kUiBlockFenceLanguage` 的代码块，内容是 JSON：component、id（简短英文，只用字母、数字、- 和 _，对话内唯一）与组件属性，属性平铺在顶层。字符串里的英文双引号写成 \\"，不要注释。代码块放在正文中它所属的位置，前后用自然语言承接。
```$kUiBlockFenceLanguage
{"component": "checklist", "id": "voice-setup", "title": "语音通话准备", "items": [{"text": "选音色预设", "note": "决定角色用什么声音说话"}, "填语音渠道的 Key", "选识别来源"]}
```</syntax>
<catalog>
$catalog
</catalog>
<panel>
  <shape>{"component": "panel", "id", "title?", "state": {名: 初始值}, "computed"?: {名: "公式"}, "children": [...]}。state 是用户可改的值；computed 由 state 推导，可以互相引用，不能循环。</shape>
  <children>从上到下排列，可以是下面的原语，也可以是目录组件（嵌套时不写 id）。控件用 bind 指向 state 名；visible: "{条件}" 为假时隐藏该节点。</children>
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
