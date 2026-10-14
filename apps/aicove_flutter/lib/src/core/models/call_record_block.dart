part of 'message_block.dart';

/// 通话中的一轮发言（ADR0074）。
final _speechTag = RegExp(r'\[[^\[\]\n]{1,30}\]');

/// 被打断时只截到一半的标签（如 `好呀[轻`）。
final _cutSpeechTag = RegExp(r'\[[^\[\]\n]{0,30}$');

/// 去掉台词里的方括号语气标签（Fish Audio 语法），并收掉因此多出的空白。
String stripSpeechTags(String text) => text
    .replaceAll(_speechTag, '')
    .replaceAll(_cutSpeechTag, '')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .trim();

class CallTurn {
  const CallTurn({
    required this.role,
    required this.text,
    this.interrupted = false,
  });

  /// `user` 或 `assistant`。
  final String role;
  final String text;

  /// 角色这句话被用户打断；[text] 只含实际播出去的部分。
  final bool interrupted;

  bool get isUser => role == 'user';

  /// 去掉语气控制标签（如 `[轻笑]`）后的台词，字幕和记录显示用；[text] 保留原文
  /// 让模型下一轮照着同样的风格说。
  String get spokenText => isUser ? text : stripSpeechTags(text);

  factory CallTurn.fromJson(Map<String, dynamic> json) => CallTurn(
    role: json['role'] as String,
    text: json['text'] as String,
    interrupted: json['interrupted'] == true,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    if (interrupted) 'interrupted': true,
  };
}

/// 聊天里的语音通话气泡（ADR0074）。逐句记录跟着气泡存、随聊天同步（[turns]），
/// 但不是正式消息：文字内容只有给模型看的标签和挂断后补上的通话摘要（决定 4）。
class CallRecordBlock extends TextBlock {
  CallRecordBlock({
    super.id,
    required super.messageId,
    required this.callId,
    required this.duration,
    this.summary,
    List<CallTurn> turns = const [],
    this.missed = false,
    super.status,
  }) : turns = List.unmodifiable(turns),
       super(
         content: missed
             ? missedCallLabel
             : summary == null || summary.trim().isEmpty
             ? callRecordLabel(duration)
             : '${callRecordLabel(duration)}\n通话摘要：${summary.trim()}',
       );

  /// 角色主动打来、用户没接的电话（方案 12 §4.8）：时长为 0，没有逐句记录。
  factory CallRecordBlock.missed({
    required String messageId,
    required String callId,
  }) => CallRecordBlock(
    messageId: messageId,
    callId: callId,
    duration: Duration.zero,
    missed: true,
  );

  final String callId;
  final Duration duration;

  /// 没接通的来电。模型只看到 [missedCallLabel]，知道自己打过、对方没接。
  final bool missed;

  /// 挂断后由后台整理的摘要；还没整理好或整理失败时为空。
  final String? summary;

  /// 逐句记录。2026-10-12 之前的通话为空，记录只在通话那台设备的旧表里。
  final List<CallTurn> turns;

  CallRecordBlock withSummary(String summary) => CallRecordBlock(
    id: id,
    messageId: messageId,
    callId: callId,
    duration: duration,
    summary: summary,
    turns: turns,
    missed: missed,
    status: status,
  );

  factory CallRecordBlock.fromJson(Map<String, dynamic> json) {
    final record = Map<String, dynamic>.from(json['callRecord'] as Map);
    return CallRecordBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      callId: record['callId'] as String,
      duration: Duration(milliseconds: (record['durationMs'] as num).toInt()),
      summary: record['summary'] as String?,
      turns: [
        for (final turn in record['turns'] as List? ?? const [])
          CallTurn.fromJson(Map<String, dynamic>.from(turn as Map)),
      ],
      missed: record['missed'] == true,
      status: BlockStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'callRecord': {
      'callId': callId,
      'durationMs': duration.inMilliseconds,
      if (summary != null) 'summary': summary,
      if (turns.isNotEmpty) 'turns': [for (final turn in turns) turn.toJson()],
      if (missed) 'missed': true,
    },
  };
}

/// 未接来电在聊天记录里的文字，模型和会话预览都看这个。
const String missedCallLabel = '[未接的语音通话]';

/// 聊天列表和气泡预览里的通话标签。
String callRecordLabel(Duration duration) =>
    '[语音通话 ${formatCallDuration(duration)}]';

/// 通话时长：不足一小时 `mm:ss`，否则 `h:mm:ss`。
String formatCallDuration(Duration duration) {
  final s = duration.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600;
  final body = '${two(s ~/ 60 % 60)}:${two(s % 60)}';
  return h > 0 ? '$h:$body' : body;
}
