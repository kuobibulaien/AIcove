import '../../ui_blocks/domain/ui_block.dart' show kUiBlockFenceLanguage;
import '../../ui_blocks/domain/ui_block_catalog.dart';

/// AIcove酱's quick panels (ADR0094): action components of the assistant
/// chat. The renderer registry (`assistant_quick_panels.dart`) covers the
/// same names as [kUiActionComponents].
const kAssistantPanels = [
  UiCatalogComponent(
    'roles',
    '用户要改角色却没说是哪个，或要先挑一个角色再做事',
    '{title?, purpose?: edit|drawing|voice, ids?: [角色 id]}',
    'purpose 决定点选后打开什么：edit＝角色卡（默认），drawing＝它的绘图预设，voice＝它的音色；ids 只在要缩小范围时写',
  ),
  UiCatalogComponent(
    'drawing-presets',
    '用户要改或换绘图预设（画风、尺寸、绘图模型、绘图提示词）',
    '{title?, role?: 角色 id}',
    '写了 role 时会标出这个角色在用哪个，并让用户一键换给它；用户可以点开任一预设的编辑页',
  ),
  UiCatalogComponent(
    'voice-presets',
    '用户要改或换音色预设',
    '{title?, role?: 角色 id}',
    '写了 role 时会标出这个角色在用哪个，并让用户一键换给它',
  ),
  UiCatalogComponent(
    'settings',
    '用户想自己调几项设置（深浅色、字号、默认模型、分段等），或改完后给个回头调的入口',
    '{title?, keys: [设置 key]}',
    'keys 只能用下面 keys 里列的，最多 8 个，按相关度排；控件按类型自动生成，改了立即生效、可撤销',
  ),
  UiCatalogComponent(
    'providers',
    '用户要看或管理模型渠道、给某家填 Key',
    '{title?}',
    '没 Key 的渠道会带「填 Key」按钮，Key 由用户自己粘贴',
  ),
];

/// The prompt section on quick panels, after [uiBlockPrompt]. [settings]
/// are the whitelisted setting keys with labels, so the model can fill a
/// `settings` panel without looking them up.
String assistantPanelPrompt({Map<String, String> settings = const {}}) {
  final keys = [
    for (final e in settings.entries) '${e.key}（${e.value}）',
  ].join('、');
  final catalog = [
    for (final component in kAssistantPanels)
      [
        '  <component name="${component.name}">',
        '    <use>${component.use}</use>',
        '    <props>${component.props}</props>',
        if (component.rules.isNotEmpty) '    <rules>${component.rules}</rules>',
        if (component.name == 'settings' && keys.isNotEmpty)
          '    <keys>$keys</keys>',
        '  </component>',
      ].join('\n'),
  ].join('\n');
  return '''
## 快捷面板

<nature>快捷面板也是 `$kUiBlockFenceLanguage` 代码块，但列表内容由 AIcove 渲染时从本机实时读取：你只写组件名、id 和意图，不要自己列条目、不要编名字。用户点选一项后可以打开它的编辑页、直接改（可撤销），或点「交给 AIcove酱」把要求填进输入框发给你。</nature>
<when>
  <use>用户要改、换、挑某类东西却没说清是哪一个或要改哪里（「帮我改个角色」「改一下纳西妲的绘图预设」）；用户想自己动手调几项设置；做完修改后给一个回头调的入口。</use>
  <avoid>用户已经说清要怎么改、你有工具能直接做时，直接用工具改，不要先出面板让用户点。一条回复最多一个面板。</avoid>
  <followup>用户在面板里选中的一项（picked 是 id，pickedName 是名字）和做过的事（did）会在下一轮的 ui_state 里，直接接着做。</followup>
</when>
<catalog>
$catalog
</catalog>
<example>用户说「帮我改一下纳西妲的绘图预设」：先用 aicove_list_roles 找到纳西妲的 id（例如 nahida），再用一句话说明她现在用哪个、能改什么，然后：
```$kUiBlockFenceLanguage
{"component": "drawing-presets", "id": "nahida-drawing", "title": "纳西妲的绘图预设", "role": "nahida"}
```
最后问用户想改画风、尺寸还是换一个，或者让用户直接点开编辑。</example>''';
}
