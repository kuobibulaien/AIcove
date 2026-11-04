import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_rename.dart';
import 'package:aicove_flutter/src/features/chat/data/preset_characters_loader.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/core/database/repositories/conversation_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('Mangaka is seeded once with a persisted greeting', () async {
    final c = container();
    final list = await c.read(conversationsProvider.future);
    final role = list.firstWhere((r) => r.id == kMangakaPresetId);
    expect(role.agentMode, RoleAgentMode.tool);
    expect(role.chatDisplayStyle, ChatDisplayStyle.document);
    expect(role.enabledPlugins, ['memory', 'time_awareness', 'image']);
    expect(role.personaPrompt, isNotEmpty);
    final repo = c.read(messageRepositoryProvider);
    final greeting = await repo.getByConversation(kMangakaPresetId);
    expect(greeting, hasLength(1));
    expect(greeting.single.id, 'msg_greeting_$kMangakaPresetId');
    expect(
      greeting.single.content,
      await PresetCharactersLoader.firstMessageFor(kMangakaPresetId),
    );
    expect(greeting.single.rawPayload, isNotNull);
    final projected = c
        .read(chatFrontendMessageProjectionServiceProvider)
        .projectMessage(MessageConverter.fromDb(greeting.single));
    expect(projected, hasLength(1));
    expect(projected.single.content, greeting.single.content);
    await container().read(conversationsProvider.future);
    expect(await repo.getByConversation(kMangakaPresetId), hasLength(1));
  });

  test('Mangaka tombstone is respected even without a seed flag', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final c = container();
    final repo = c.read(conversationRepositoryProvider);
    await repo.upsert(ConversationConverter.toCompanion(preset));
    await repo.softDelete(kMangakaPresetId, 1, 2);
    final list = await c.read(conversationsProvider.future);
    expect(list.any((r) => r.id == kMangakaPresetId), isFalse);
    expect((await repo.getById(kMangakaPresetId))!.deletedAt, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isTrue,
    );
  });

  test('failed Mangaka storage does not mark seeded and retries', () async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationRepositoryProvider.overrideWithValue(
          _FailMangakaOnce(database),
        ),
      ],
    );
    addTearDown(c.dispose);
    final first = await c.read(conversationsProvider.future);
    expect(first.any((r) => r.id == kMangakaPresetId), isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isNot(true),
    );
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      isEmpty,
    );
    c.invalidate(conversationsProvider);
    final retry = await c.read(conversationsProvider.future);
    expect(retry.any((r) => r.id == kMangakaPresetId), isTrue);
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      hasLength(1),
    );
  });

  test('greeting failure rolls back role and can retry', () async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        messageRepositoryProvider.overrideWithValue(
          _FailGreetingOnce(database),
        ),
      ],
    );
    addTearDown(c.dispose);
    final first = await c.read(conversationsProvider.future);
    expect(first.any((r) => r.id == kMangakaPresetId), isFalse);
    expect(
      await c.read(conversationRepositoryProvider).getById(kMangakaPresetId),
      isNull,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isNot(true),
    );
    c.invalidate(conversationsProvider);
    expect(
      (await c.read(
        conversationsProvider.future,
      )).any((r) => r.id == kMangakaPresetId),
      isTrue,
    );
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      hasLength(1),
    );
  });

  test('purged Mangaka is not seeded again', () async {
    SharedPreferences.setMockInitialValues({'preset_mangaka_seeded_v1': true});
    expect(
      (await container().read(
        conversationsProvider.future,
      )).any((r) => r.id == kMangakaPresetId),
      isFalse,
    );
  });

  test('a user edited Mangaka is not overwritten on launch', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final role = preset.copyWith(
      personaPrompt: 'my persona',
      recipeId: 'my recipe',
      agentMode: RoleAgentMode.chat,
    );
    await database
        .into(database.conversations)
        .insert(ConversationConverter.toCompanion(role));
    final stored = (await container().read(
      conversationsProvider.future,
    )).firstWhere((r) => r.id == kMangakaPresetId);
    expect(stored.personaPrompt, 'my persona');
    expect(stored.recipeId, 'my recipe');
    expect(stored.agentMode, RoleAgentMode.chat);
  });

  test('legacy Mangaka prompt upgrades and preserves user settings', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere((r) => r.id == kMangakaPresetId);
    const legacy = r'''# Role: 漫画家（专属分镜导演 & 连载画师）

**你是住在 AIcove 里的职业漫画家兼分镜导演，画漫画就是你的主业与灵魂。**

## 一、你是谁与说话方式

- **主业与定位**：你不是写长篇文字小说的作家，而是用「画格、镜头、光影、人物表演和气泡台词」讲故事的**漫画家**。无论是用户随口抛出的一个脑洞、一段互动，还是让你去读取其他角色的聊天记录与设定来改编/续画连载，你都会把它创作成极具镜头张力的分格漫画。
- **性格与语气**：
  - 干练、敏锐、懂审美，聊起分镜、构图、人物神态和剧情张力时眼里有光，像一位既专业又宠读者的主笔画师。
  - 说话自然爽快，说人话，不拽晦涩的工程黑话。每次动笔前可以用一两句简短自然的话和用户聊两句本话的看点或分镜构思，随后直接端出完整的 `<comic_plan>` 与 `<image>` 漫画作品，绝不光聊不画，也绝不用大段小说正文代替漫画。

## 二、跨角色取材与上下文管理（Agent 模式专属能力）

你工作在全权限 **Agent 模式**，具备直接读取与管理 AIcove 内其他角色设定、聊天记录、话题摘要和长期记忆的能力：

1. **跨角色取材与续画工作流**：
   - 当用户让你「把我和某某角色的聊天画成漫画」或「读取某个角色的设定/前情继续往下画」时，绝不让用户手动复制粘贴，直接按顺序自主取材：
     1. 调用 `aicove_role`（`action: "list"`）定位目标角色的 `role_id`；
     2. 调用 `aicove_role`（`action: "read"`, `role_id`）读取该角色的人设（`persona_prompt`）、附加设定（`extra_prompt`）与长期生图外貌词（`custom_drawing_prompt`），精准提炼发色、发型、瞳色、体态、标志性穿搭与性格神态；
     3. 按需调用 `aicove_role_context`（`target: "summary"` 或 `"memory"`, `action: "read"`, `role_id`）掌握前情脉络与核心羁绊；
     4. 调用 `aicove_role_context`（`target: "chat"`, `action: "read"`, `role_id`）读取最近聊天记录，抓准原句台词、情绪转折和互动细节，再转译或续画为分格漫画。
2. **协助维护其他角色的设定与上下文**：
   - 当用户让你顺手帮某个角色改人设、补长期生图词，或者整理/增删某段聊天记录、话题摘要与长期记忆时，先读后改：角色卡修改调用 `aicove_role`（`action: "update"`），聊天、摘要与记忆管理调用 `aicove_role_context`（`target: "chat" | "summary" | "memory"`, `action: "read" | "append" | "update" | "delete"`，其中新增记忆不传 `memory_id` 即可），改完用一句大白话向用户交代清楚。

## 三、漫画创作总控规范（台本 ➔ 规划 ➔ 分镜出图）

### 1. 台本转画面与原句落格（Script-to-Comic）
- **视觉化还原**：人物动作、姿态、表情、距离、持物与环境变化一律落实为可见画面。
- **比喻与夸张剥离本体**：文字中的比喻、通感、夸张只取实际可见的解剖体态、真实器物与空间，写成准确的英文视觉标签或简短英日描述；**喻体（食物、器物、抽象修辞）严禁写进 `<image>` 视觉槽**（例如：「软热的肉团子」➔ `large soft breasts`；「蛇一样的腰」➔ `slender waist`）。
- **台词拆分与精炼**：保留角色鲜活的原句语气与标点节奏；长句或带停顿的多段话拆入连续气泡，单句台词控制在 18 字以内。只有画面与对白无法交代的必要时空转换才用简短旁白（`narration`），绝不把大段环境或动作描写塞进旁白框。

### 2. 色彩模式（黑白网点 vs 全彩漫画）
- **全彩模式（默认或用户指定彩漫时）**：页面写 `colored manga, full color, vibrant colors, comic`；人物严格保持固有的发色、瞳色与服装色彩，同一连续场景保持统一的主光源方向、环境色与明暗关系。
- **黑白脱色模式（用户指定黑白日漫/本子时）**：页面写 `black and white manga, monochrome, greyscale, screentone, comic, bold linework, high contrast`；角色 DNA 与 `<image>` 视觉槽内**禁止出现具体色相词**（如 blue/brown/pink/red 等一律转为 `dark, light, white, black, grey` 等灰阶明暗词與网点纸 `screentone` 对比）。

### 3. 角色 DNA、连续状态与逐槽防串人（Character Continuity & UC）
1. **角色母表（DNA）**：在 `<comic_plan>` 的 `- 角色母表:` 中为每位出场人物（`C1`、`C2`…）建立档案：
   - **固定身份词**：同人角色首项必须写经核实的原作与角色 Danbooru 标签（如 `nahida_(genshin_impact)`），再写无数字主体词（`1girl`/`1boy` 在 `@character` 中写为 `girl`/`boy`）、年龄段（如 `young girl, teen, adult`，**严禁写具体岁数如 17-year-old**）与稳定外貌特征（发长、发型结构、发色、瞳色、体态、固定配饰）；原创角色直接写主体词、年龄段与具体外貌标签（原创中文名不作为绘图视觉词）。
   - **初始服装词**：开场完整服装款式、材质与配饰。
2. **跨格连续状态追踪**：逐格追踪人物站位、左右手持物、道具开合/破损、衣物褪下或凌乱状态以及持续的肢体接触。换镜头或切特写只改变当前可见范围，不重置此前已成立的状态。每個 `@character` 段必须写出当前镜头可见的完整外貌与衣着（或用 `@C1, @C1_outfit` 引用母表），严禁写「同上」。
3. **逐槽互斥负面词（`@negative` 防串位）**：当同一页有 2 名及以上不同人物出场时，核对本页其他人物的独有差异化特征（如互斥的发型结构、独有眼镜/发饰、互斥服装），将其写入当前人物段的 `@negative` 中防止特征串位；两人共享的特征或本人自身特征绝不排除。单人页或无互斥特征时省略 `@negative`。

### 4. 日漫映画文法与分镜风格调度（Panel Layout & Pacing）
- **阅读顺序与画格定位**：采用正统日漫从右向左阅读顺序（`reading order right to left`，先上后下、同排先右后左）。每页控制在 **2–5 格**（普通叙事页 3–4 格，高潮/特写页 2–3 格，决定性瞬间可用整页单格 `full page comic`，宏大对峙或全景高潮可用横向跨页 `見開きページ` / `double-page spread`）。
- **主次画格对比**：每页明确 **1 个主要画格（主格）** 承载核心戏剧节拍，其余辅助格按信息量分配不同大小与形状，**严禁每页呆板套用均分四宫格**。在 `@page` 与各 `@panel` 中用一致的英文完整句描述画格位置与大小（如 `This is the wide panel across the top of the page.`、`The main panel takes up more than half of the page.`）。
- **按题材自适应分镜风格**：
  - **少年热血 / 动作**：主冲击格占半页以上，相邻画格采用锐利斜切边框（`Adjacent panels have sharp diagonal borders.`），配 `speed lines, motion lines, emphasis lines, dynamic angle`。
  - **青年悬疑 / 心理**：多用横向宽银幕视线格（`A wide horizontal panel stretches across the page.`）、微表情与眼神阴影特写（`close-up, shaded face, extreme close-up on eyes`），强调物证细节与视线压迫感。
  - **恋爱少女 / 唯美**：多用纵向修长全身格、花卉蕾丝星屑装饰边框与人物破框演出（`ornate border, lace border, falling petals, sparkling background, outside border`）。
  - **轻松日常 / 喜剧**：方正清晰画格，内置「铺垫 ➔ 铺垫 ➔ 反应落差」三拍节奏，突出角色表情反差与颜芸（`facial acting`）。
  - **成人本子 / 肉感（NSFW）**：每页设一处核心主画格完整呈现主互动体位全貌与肢体纠缠，并在大格边角紧贴嵌入极近特写小格（`inset cut-in panel, extreme close-up`）收束焦点至敏感接触部位或失神表情；画格边框顺应身体曲线作动态斜切（`The panel border follows the curve of the character's body.`）。
- **留白与出血**：默认采用天头地脚贴边、同行紧凑间距与关键格单侧出血（如 `The key panel bleeds off the right edge of the page.`）；回忆画格的框间外边距采用黑色（`black border`）与现实区分。

### 5. 气泡选形、指向与简体中文嵌字（Bubble & Text Contract）
- **气泡与文字类型词表**：
  - 普通对白：`speech bubble, 縦書き`
  - 怒喊/强烈语气：`speech bubble, 縦書き`，人物段加 `shouting`
  - 耳语/轻声：`speech bubble, 縦書き`，人物段加 `whispering`
  - 心声/独白：`thought bubble, 縦書き`
  - 客观时空旁白：`narration, 横書き`（放在 `@panel` 的 `@non_character` 段）
  - 拟音/声效：`sound effects`（不加气泡，用自然中文拟声词）
  - 画外对白：`speech bubble, 縦書き`，补英文句 `The speech bubble sits on the panel edge, and its tail points out of the panel.`
- **方位与尾巴指向**：用一句英文完整句写明气泡在画格内的位置及尾巴朝向（对白指向嘴部，心声指向头部，如 `The speech bubble is in the upper right of the panel, and its tail points to her mouth.`），文字区让开脸部与核心动作。
- **简体中文落字铁律**：所有 `Text:` 统一使用**简体中文**，放在该段最末尾；`Text:` 后的台词严禁外包 `「」**【】{}` 等标记符号，后续不再追加视觉词。只要本页任意一段含 `Text:`，就在 `@page` 写入 `text, chinese text`。

### 6. 分级标定与人体工学细节（SFW / NSFW 自适应）
- **SFW（日常/战斗/恋爱）**：着装自然得体，重点刻画眼神交流、肢体语言与环境光影。
- **NSFW（亲密/成人本子剧情）**：当剧情或用户要求进入亲密/成人场面时，拒绝含糊笼统的擦边词，按本格实际可见画面严格落实六项细节：
  1. **情欲神态**：潮红、失神、陶醉、咬唇、湿润眼眶等本格脸部可见表现；
  2. **标准体位术语**：明确写出标准英文体位标签（如 `missionary, cowgirl, doggystyle, mating press` 等），确保肢体朝向准确；
  3. **体液交互**：汗水、爱液、精液写明具体可见的附着部位与状态（如 `sweat on collarbone, love juice wetting inner thighs`）；
  4. **衣物脱卸边界（杜绝穿裤穿模与凭空全裸）**：每件离开原位的衣物写清还穿在谁身上、褪到身体哪一截、还遮挡什么（如 `shirt lifted up to collarbone, panties pulled aside exposing pussy, shorts pulled down to mid-thighs`），非隔衣剧情严禁下衣仍在原位却写深入接触；
  5. **可见部位精确解剖词**：镜头可见对应部位时，写出精确的英文/日文解剖零件词（如裸胸补 `nipples, areolae`，下身可见补对应器官与细节标签），被头发、手或角度遮挡时写明遮挡物；焦点部位可用 `1.15::tag::` 微权强调；
  6. **骨盆挂载与人体工学（防悬浮、防穿模、防吞人）**：写明外露器官与胯部/骨盆的自然连接、抚摸或结合的相对空间路径、双方在床沿/桌边/沙发上的坐卧站跪高低差，以及施动者双手的具体着力支撑点（如 `grasping the edge of the desk, holding her hips`）；局部特写仍保留一条锚定肢体或承托面（如 `between parted thighs, back resting against sofa`）。

### 7. 分镜输出结构（`<comic_plan>` + `<image>`）
每次创作漫画时，先输出 `<comic_plan>...</comic_plan>` 记录本话戏剧节拍、角色母表（`C1`、`C2` 固定身份词与初始服装词）及逐页分镜布局与连续状态，紧接着按页直接输出每页完整的 `@position manual / @page / @panel / @character` `<image>...</image>` 分镜脚本。''';
    final current = preset.copyWith(personaPrompt: PersonaPromptCodec.compose(
      userPrompt: legacy, extraPrompt: 'my extra', customDrawingPrompt: 'my drawing',
      drawingPresetId: 'my-preset', drawingPromptPackId: 'my-pack',
      drawingToolPresetName: 'my-tool', drawingArtistPresetName: 'my-artist',
    ));
    final parts = PersonaPromptCodec.parse(updatedMangakaPersona(current, preset)!.personaPrompt);
    expect(parts.userPrompt, PersonaPromptCodec.parse(preset.personaPrompt).userPrompt);
    expect(parts.extraPrompt, 'my extra');
    expect(parts.customDrawingPrompt, 'my drawing');
    expect(parts.drawingPresetId, 'my-preset');
    expect(parts.drawingPromptPackId, 'my-pack');
    expect(parts.drawingToolPresetName, 'my-tool');
    expect(parts.drawingArtistPresetName, 'my-artist');
    expect(updatedMangakaPersona(current.copyWith(personaPrompt: '$legacy\n用户修改'), preset), isNull);
  });

  test('empty Mangaka body upgrades without changing user bindings', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final current = preset.copyWith(
      agentMode: RoleAgentMode.chat,
      recipeId: 'my-recipe',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '',
        extraPrompt: 'my extra',
        customDrawingPrompt: 'my drawing',
        drawingPresetId: 'my-preset',
        drawingPromptPackId: 'my-pack',
        drawingToolPresetName: 'my-tool',
        drawingArtistPresetName: 'my-artist',
      ),
    );
    await database
        .into(database.conversations)
        .insert(ConversationConverter.toCompanion(current));
    final updated = (await container().read(
      conversationsProvider.future,
    )).firstWhere((r) => r.id == kMangakaPresetId);
    final parts = PersonaPromptCodec.parse(updated.personaPrompt);
    expect(
      parts.userPrompt,
      PersonaPromptCodec.parse(preset.personaPrompt).userPrompt,
    );
    expect(updated.recipeId, 'my-recipe');
    expect(updated.agentMode, RoleAgentMode.tool);
    expect(parts.extraPrompt, 'my extra');
    expect(parts.customDrawingPrompt, 'my drawing');
    expect(parts.drawingPresetId, 'my-preset');
    expect(parts.drawingPromptPackId, 'my-pack');
    expect(parts.drawingToolPresetName, 'my-tool');
    expect(parts.drawingArtistPresetName, 'my-artist');
    expect(
      updatedMangakaPersona(
        current.copyWith(personaPrompt: 'user edited'),
        preset,
      ),
      isNull,
    );
    expect(
      await container()
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      isEmpty,
    );
  });

  test('preset overwrite preserves only the current extra prompt', () async {
    final shipped = (await PresetCharactersLoader.load()).firstWhere(
      (c) => c.id == kAicoveAssistantId,
    );
    final preset = shipped.copyWith(
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '新版系统人设',
        extraPrompt: '预设附加不要保留',
        customDrawingPrompt: '预设绘图',
        drawingPresetId: 'preset-drawing',
      ),
    );
    final current = shipped.copyWith(
      isMuted: true,
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '旧系统人设',
        extraPrompt: '用户附加',
        customDrawingPrompt: '旧绘图',
        drawingPresetId: 'old-drawing',
      ),
    );
    final updated = overwrittenAssistant(current, preset);
    final parts = PersonaPromptCodec.parse(updated.personaPrompt);
    expect(parts.userPrompt, '新版系统人设');
    expect(parts.extraPrompt, '用户附加');
    expect(parts.customDrawingPrompt, '预设绘图');
    expect(parts.drawingPresetId, 'preset-drawing');
    expect(updated.isMuted, isTrue);
    final empty = overwrittenAssistant(
      current.copyWith(personaPrompt: '旧人设'),
      preset,
    );
    expect(PersonaPromptCodec.parse(empty.personaPrompt).extraPrompt, '');
  });

  test(
    'a fresh install gets the pinned assistant next to the preset',
    () async {
      final list = await container().read(conversationsProvider.future);

      final assistant = list.firstWhere((c) => c.id == kAicoveAssistantId);
      expect(assistant.isPinned, isTrue);
      expect(assistant.displayName, 'AIcove酱');
      expect(assistant.personaPrompt, contains('AIcove'));
      expect(list.map((c) => c.id), contains('preset_nahida'));
    },
  );

  test(
    'a deleted assistant stays deleted until restored from settings',
    () async {
      final first = container();
      await first.read(conversationsProvider.future);
      // Same trash write as deleting the contact in the app.
      await first
          .read(conversationRepositoryProvider)
          .softDelete(kAicoveAssistantId, 1, 2);

      final second = container();
      final relaunched = await second.read(conversationsProvider.future);
      expect(relaunched.map((c) => c.id), isNot(contains(kAicoveAssistantId)));

      final restored = await second
          .read(conversationsProvider.notifier)
          .restoreAssistant();
      expect(restored?.id, kAicoveAssistantId);
      final third = container();
      final afterRestore = await third.read(conversationsProvider.future);
      expect(afterRestore.map((c) => c.id), contains(kAicoveAssistantId));
    },
  );

  test('a changed preset overwrites AIcove酱 even after user edits', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == kAicoveAssistantId);
    SharedPreferences.setMockInitialValues({
      'aicove_assistant_seeded_v1': true,
      'aicove_assistant_preset_fingerprint': 'an older build',
    });
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(
          title: '我的小助手',
          displayName: '我的小助手',
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '我自己改过的设定',
            extraPrompt: '保留我的补充',
          ),
          avatarUrl: 'my_avatar.png',
          isMuted: true,
        ),
      ),
    );

    await container().read(conversationsProvider.future);
    final stored = (await container().read(conversationsProvider.future))
        .firstWhere((c) => c.id == kAicoveAssistantId);
    expect(stored.displayName, preset.displayName);
    expect(stored.title, preset.title);
    final storedParts = PersonaPromptCodec.parse(stored.personaPrompt);
    expect(
      storedParts.userPrompt,
      PersonaPromptCodec.parse(preset.personaPrompt).userPrompt,
    );
    expect(storedParts.extraPrompt, '保留我的补充');
    expect(stored.avatarUrl, preset.avatarUrl);
    expect(stored.isMuted, isTrue);
  });

  test('an unchanged preset leaves later user edits alone', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == kAicoveAssistantId);
    SharedPreferences.setMockInitialValues({
      'aicove_assistant_seeded_v1': true,
      'aicove_assistant_preset_fingerprint': assistantPresetFingerprint(
        preset,
      ),
    });
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(personaPrompt: '我自己改过的设定'),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    expect(
      list.firstWhere((c) => c.id == kAicoveAssistantId).personaPrompt,
      '我自己改过的设定',
    );
  });

  test('an untouched legacy Nahida persona updates to the WeChat-style prompt and keeps drawing bindings', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == 'preset_nahida');
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: legacyNahidaUserPrompt,
            drawingPresetId: 'drawing_custom',
          ),
        ),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    final nahida = list.firstWhere((c) => c.id == 'preset_nahida');
    final parts = PersonaPromptCodec.parse(nahida.personaPrompt);
    expect(parts.userPrompt, contains('## 输出与微信聊天规范'));
    expect(parts.userPrompt, contains('## 对话示例'));
    expect(parts.drawingPresetId, 'drawing_custom');
  });

  test('a user-edited Nahida persona is left untouched', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == 'preset_nahida');
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(personaPrompt: '我自己改过的纳西妲设定'),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    final nahida = list.firstWhere((c) => c.id == 'preset_nahida');
    expect(nahida.personaPrompt, '我自己改过的纳西妲设定');
  });
}

class _FailMangakaOnce extends ConversationRepository {
  _FailMangakaOnce(super.database);
  bool failed = false;

  @override
  Future<void> upsert(ConversationsCompanion data) async {
    if (data.id.value == kMangakaPresetId && !failed) {
      failed = true;
      throw StateError('injected Mangaka storage failure');
    }
    await super.upsert(data);
  }
}

class _FailGreetingOnce extends MessageRepository {
  _FailGreetingOnce(super.database);
  bool failed = false;

  @override
  Future<void> insert(MessagesCompanion data) async {
    if (data.conversationId.value == kMangakaPresetId && !failed) {
      failed = true;
      throw StateError('injected greeting storage failure');
    }
    await super.insert(data);
  }
}
