/// 每个联系人一份记忆文档。ownerId 必须来自请求/页面的稳定联系人 ID，
/// 不能来自模型参数、昵称或当前活动页面。
abstract interface class ContactMemoryPort {
  Future<ContactMemoryNotebook> load(String ownerId);

  /// revision 是读取时的内容哈希。并发修改时拒绝覆盖，调用方重新加载。
  Future<ContactMemoryNotebook> save(ContactMemoryNotebook notebook);
}

class ContactMemoryConflict implements Exception {
  const ContactMemoryConflict();
  @override
  String toString() => '记忆已被修改，请重新打开后再保存。';
}

class ContactMemoryNotebook {
  ContactMemoryNotebook({
    required this.ownerId,
    this.revision = '',
    this.enabled = false,
    this.core = '',
    this.appliedCompactions = const [],
    List<ContactMemoryEvent> events = const [],
  }) : events = List.unmodifiable(events);

  final String ownerId;
  final String revision;
  final bool enabled;
  final String core;
  final List<String> appliedCompactions;
  final List<ContactMemoryEvent> events;

  ContactMemoryNotebook copyWith({
    String? revision,
    bool? enabled,
    String? core,
    List<String>? appliedCompactions,
    List<ContactMemoryEvent>? events,
  }) => ContactMemoryNotebook(
    ownerId: ownerId,
    revision: revision ?? this.revision,
    enabled: enabled ?? this.enabled,
    core: core ?? this.core,
    appliedCompactions: appliedCompactions ?? this.appliedCompactions,
    events: events ?? this.events,
  );
}

class ContactMemoryEvent {
  const ContactMemoryEvent({
    required this.id,
    required this.title,
    required this.body,
    required this.occurredAt,
    this.generatedKey,
    this.generatedDigest,
    this.memoryKind,
  });
  final String? generatedKey, generatedDigest, memoryKind;
  final String id;
  final String title;
  final String body;
  final DateTime occurredAt;
}
