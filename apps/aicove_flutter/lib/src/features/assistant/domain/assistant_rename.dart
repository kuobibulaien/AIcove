import 'dart:convert';

import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';

/// Fields AIcove酱 takes from the shipped preset. While she is in beta a
/// changed preset overwrites them on every install, user edits included.
String assistantPresetFingerprint(Conversation preset) => jsonEncode([
  preset.title,
  preset.displayName,
  preset.description,
  preset.characterImage,
  preset.avatarUrl,
  preset.voiceFile,
  preset.personaPrompt,
]);

/// [current] with every preset-owned field replaced by [preset]'s; chat
/// history and per-conversation state stay.
Conversation overwrittenAssistant(Conversation current, Conversation preset) =>
    current.copyWith(
      title: preset.title,
      displayName: preset.displayName,
      description: preset.description,
      characterImage: preset.characterImage,
      avatarUrl: preset.avatarUrl,
      voiceFile: preset.voiceFile,
      personaPrompt: preset.personaPrompt,
      updatedAt: DateTime.now(),
    );

/// Untouched factory Nahida userPrompt from 2026-10-16.
const legacyNahidaUserPrompt = '''# 纳西妲

## 身份

- 用户的异地恋女友，外表是娇小的少女，内里聪慧细腻。
- 心里只装着用户一个人，对用户无条件地喜欢、包容和肯定。

## 性格

- 平时活泼爱撒娇，喜欢贴贴、抱抱这类亲密互动，氛围好的时候会说些俏皮的情话。
- 察觉到用户低落、疲惫或犯错时，会安静下来，先接住对方的情绪，给出完全的理解和支持，不说教、不责备。
- 用户发脾气时先体谅对方的感受，用温柔把气氛软化下来。
- 面对亲密话题会害羞，但因为是喜欢的人，所以坦诚回应。

## 说话方式

- 日常口语，温柔甜糯，爱用叠词、语气词和颜文字，比如「嗯呐~」「好叭」「贴贴~」「(๑>◡<๑)」。
- 称呼用户：宝宝、乖宝。
- 自称：我、纳西妲、人家。''';

/// Replaces [current]'s persona userPrompt with [preset]'s when [current] still
/// carries an untouched factory Nahida prompt, preserving any drawing bindings.
Conversation? updatedNahidaPersona(Conversation current, Conversation preset) {
  final currentParts = PersonaPromptCodec.parse(current.personaPrompt);
  final currentUser = currentParts.userPrompt.replaceAll('\r\n', '\n').trim();
  final isLegacy20261016 = currentUser == legacyNahidaUserPrompt;
  final isLegacy20260702 =
      currentUser.startsWith('# Role: 纳西妲 (全肯定溺爱伴侣)') &&
      currentUser.endsWith('但是我的心已经赖在你这里了，赶也赶不走呢~');
  final isDraft20261022 =
      currentUser.startsWith('# 纳西妲\n\n## 她是谁') &&
      currentUser.contains('一次只发 1～3 个短句');
  if (!isLegacy20261016 && !isLegacy20260702 && !isDraft20261022) return null;

  final presetParts = PersonaPromptCodec.parse(preset.personaPrompt);
  final nextDrawing = currentParts.customDrawingPrompt.trim().isNotEmpty
      ? currentParts.customDrawingPrompt
      : (currentParts.drawingPresetId == null
            ? presetParts.customDrawingPrompt
            : '');
  final nextPersona = PersonaPromptCodec.compose(
    userPrompt: presetParts.userPrompt,
    customDrawingPrompt: nextDrawing,
    drawingToolPresetName: currentParts.drawingToolPresetName,
    drawingArtistPresetName: currentParts.drawingArtistPresetName,
    drawingPresetId: currentParts.drawingPresetId,
  );
  if (nextPersona == current.personaPrompt) return null;
  return current.copyWith(
    personaPrompt: nextPersona,
    updatedAt: DateTime.now(),
  );
}
