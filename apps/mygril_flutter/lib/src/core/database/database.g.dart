// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, Conversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _displayNameMeta =
      const VerificationMeta('displayName');
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
      'display_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _avatarUrlMeta =
      const VerificationMeta('avatarUrl');
  @override
  late final GeneratedColumn<String> avatarUrl = GeneratedColumn<String>(
      'avatar_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _characterImageMeta =
      const VerificationMeta('characterImage');
  @override
  late final GeneratedColumn<String> characterImage = GeneratedColumn<String>(
      'character_image', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _selfAddressMeta =
      const VerificationMeta('selfAddress');
  @override
  late final GeneratedColumn<String> selfAddress = GeneratedColumn<String>(
      'self_address', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _addressUserMeta =
      const VerificationMeta('addressUser');
  @override
  late final GeneratedColumn<String> addressUser = GeneratedColumn<String>(
      'address_user', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _voiceFileMeta =
      const VerificationMeta('voiceFile');
  @override
  late final GeneratedColumn<String> voiceFile = GeneratedColumn<String>(
      'voice_file', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _personaPromptMeta =
      const VerificationMeta('personaPrompt');
  @override
  late final GeneratedColumn<String> personaPrompt = GeneratedColumn<String>(
      'persona_prompt', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _defaultProviderMeta =
      const VerificationMeta('defaultProvider');
  @override
  late final GeneratedColumn<String> defaultProvider = GeneratedColumn<String>(
      'default_provider', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sessionProviderMeta =
      const VerificationMeta('sessionProvider');
  @override
  late final GeneratedColumn<String> sessionProvider = GeneratedColumn<String>(
      'session_provider', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _isPinnedMeta =
      const VerificationMeta('isPinned');
  @override
  late final GeneratedColumn<bool> isPinned = GeneratedColumn<bool>(
      'is_pinned', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_pinned" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _isFavoriteMeta =
      const VerificationMeta('isFavorite');
  @override
  late final GeneratedColumn<bool> isFavorite = GeneratedColumn<bool>(
      'is_favorite', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_favorite" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _isMutedMeta =
      const VerificationMeta('isMuted');
  @override
  late final GeneratedColumn<bool> isMuted = GeneratedColumn<bool>(
      'is_muted', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_muted" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _notificationSoundMeta =
      const VerificationMeta('notificationSound');
  @override
  late final GeneratedColumn<bool> notificationSound = GeneratedColumn<bool>(
      'notification_sound', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("notification_sound" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _lastMessageMeta =
      const VerificationMeta('lastMessage');
  @override
  late final GeneratedColumn<String> lastMessage = GeneratedColumn<String>(
      'last_message', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _lastMessageTimeMeta =
      const VerificationMeta('lastMessageTime');
  @override
  late final GeneratedColumn<int> lastMessageTime = GeneratedColumn<int>(
      'last_message_time', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _unreadCountMeta =
      const VerificationMeta('unreadCount');
  @override
  late final GeneratedColumn<int> unreadCount = GeneratedColumn<int>(
      'unread_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _parentConversationIdMeta =
      const VerificationMeta('parentConversationId');
  @override
  late final GeneratedColumn<String> parentConversationId =
      GeneratedColumn<String>('parent_conversation_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _forkFromMessageIdMeta =
      const VerificationMeta('forkFromMessageId');
  @override
  late final GeneratedColumn<String> forkFromMessageId =
      GeneratedColumn<String>('fork_from_message_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _conflictOfMeta =
      const VerificationMeta('conflictOf');
  @override
  late final GeneratedColumn<String> conflictOf = GeneratedColumn<String>(
      'conflict_of', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _purgeAtMeta =
      const VerificationMeta('purgeAt');
  @override
  late final GeneratedColumn<int> purgeAt = GeneratedColumn<int>(
      'purge_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        title,
        displayName,
        avatarUrl,
        characterImage,
        selfAddress,
        addressUser,
        voiceFile,
        personaPrompt,
        defaultProvider,
        sessionProvider,
        isPinned,
        isFavorite,
        isMuted,
        notificationSound,
        lastMessage,
        lastMessageTime,
        unreadCount,
        parentConversationId,
        forkFromMessageId,
        conflictOf,
        deletedAt,
        purgeAt,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(Insertable<Conversation> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
          _displayNameMeta,
          displayName.isAcceptableOrUnknown(
              data['display_name']!, _displayNameMeta));
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('avatar_url')) {
      context.handle(_avatarUrlMeta,
          avatarUrl.isAcceptableOrUnknown(data['avatar_url']!, _avatarUrlMeta));
    }
    if (data.containsKey('character_image')) {
      context.handle(
          _characterImageMeta,
          characterImage.isAcceptableOrUnknown(
              data['character_image']!, _characterImageMeta));
    }
    if (data.containsKey('self_address')) {
      context.handle(
          _selfAddressMeta,
          selfAddress.isAcceptableOrUnknown(
              data['self_address']!, _selfAddressMeta));
    }
    if (data.containsKey('address_user')) {
      context.handle(
          _addressUserMeta,
          addressUser.isAcceptableOrUnknown(
              data['address_user']!, _addressUserMeta));
    }
    if (data.containsKey('voice_file')) {
      context.handle(_voiceFileMeta,
          voiceFile.isAcceptableOrUnknown(data['voice_file']!, _voiceFileMeta));
    }
    if (data.containsKey('persona_prompt')) {
      context.handle(
          _personaPromptMeta,
          personaPrompt.isAcceptableOrUnknown(
              data['persona_prompt']!, _personaPromptMeta));
    }
    if (data.containsKey('default_provider')) {
      context.handle(
          _defaultProviderMeta,
          defaultProvider.isAcceptableOrUnknown(
              data['default_provider']!, _defaultProviderMeta));
    }
    if (data.containsKey('session_provider')) {
      context.handle(
          _sessionProviderMeta,
          sessionProvider.isAcceptableOrUnknown(
              data['session_provider']!, _sessionProviderMeta));
    }
    if (data.containsKey('is_pinned')) {
      context.handle(_isPinnedMeta,
          isPinned.isAcceptableOrUnknown(data['is_pinned']!, _isPinnedMeta));
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
          _isFavoriteMeta,
          isFavorite.isAcceptableOrUnknown(
              data['is_favorite']!, _isFavoriteMeta));
    }
    if (data.containsKey('is_muted')) {
      context.handle(_isMutedMeta,
          isMuted.isAcceptableOrUnknown(data['is_muted']!, _isMutedMeta));
    }
    if (data.containsKey('notification_sound')) {
      context.handle(
          _notificationSoundMeta,
          notificationSound.isAcceptableOrUnknown(
              data['notification_sound']!, _notificationSoundMeta));
    }
    if (data.containsKey('last_message')) {
      context.handle(
          _lastMessageMeta,
          lastMessage.isAcceptableOrUnknown(
              data['last_message']!, _lastMessageMeta));
    }
    if (data.containsKey('last_message_time')) {
      context.handle(
          _lastMessageTimeMeta,
          lastMessageTime.isAcceptableOrUnknown(
              data['last_message_time']!, _lastMessageTimeMeta));
    }
    if (data.containsKey('unread_count')) {
      context.handle(
          _unreadCountMeta,
          unreadCount.isAcceptableOrUnknown(
              data['unread_count']!, _unreadCountMeta));
    }
    if (data.containsKey('parent_conversation_id')) {
      context.handle(
          _parentConversationIdMeta,
          parentConversationId.isAcceptableOrUnknown(
              data['parent_conversation_id']!, _parentConversationIdMeta));
    }
    if (data.containsKey('fork_from_message_id')) {
      context.handle(
          _forkFromMessageIdMeta,
          forkFromMessageId.isAcceptableOrUnknown(
              data['fork_from_message_id']!, _forkFromMessageIdMeta));
    }
    if (data.containsKey('conflict_of')) {
      context.handle(
          _conflictOfMeta,
          conflictOf.isAcceptableOrUnknown(
              data['conflict_of']!, _conflictOfMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('purge_at')) {
      context.handle(_purgeAtMeta,
          purgeAt.isAcceptableOrUnknown(data['purge_at']!, _purgeAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Conversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Conversation(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      displayName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}display_name'])!,
      avatarUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}avatar_url']),
      characterImage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}character_image']),
      selfAddress: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}self_address']),
      addressUser: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}address_user']),
      voiceFile: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}voice_file']),
      personaPrompt: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}persona_prompt'])!,
      defaultProvider: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}default_provider']),
      sessionProvider: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}session_provider']),
      isPinned: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_pinned'])!,
      isFavorite: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_favorite'])!,
      isMuted: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_muted'])!,
      notificationSound: attachedDatabase.typeMapping.read(
          DriftSqlType.bool, data['${effectivePrefix}notification_sound'])!,
      lastMessage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_message']),
      lastMessageTime: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_message_time']),
      unreadCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}unread_count'])!,
      parentConversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}parent_conversation_id']),
      forkFromMessageId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}fork_from_message_id']),
      conflictOf: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}conflict_of']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      purgeAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}purge_at']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class Conversation extends DataClass implements Insertable<Conversation> {
  final String id;
  final String title;
  final String displayName;
  final String? avatarUrl;
  final String? characterImage;
  final String? selfAddress;
  final String? addressUser;
  final String? voiceFile;
  final String personaPrompt;
  final String? defaultProvider;
  final String? sessionProvider;
  final bool isPinned;
  final bool isFavorite;
  final bool isMuted;
  final bool notificationSound;
  final String? lastMessage;
  final int? lastMessageTime;
  final int unreadCount;
  final String? parentConversationId;
  final String? forkFromMessageId;
  final String? conflictOf;
  final int? deletedAt;
  final int? purgeAt;
  final int createdAt;
  final int updatedAt;
  const Conversation(
      {required this.id,
      required this.title,
      required this.displayName,
      this.avatarUrl,
      this.characterImage,
      this.selfAddress,
      this.addressUser,
      this.voiceFile,
      required this.personaPrompt,
      this.defaultProvider,
      this.sessionProvider,
      required this.isPinned,
      required this.isFavorite,
      required this.isMuted,
      required this.notificationSound,
      this.lastMessage,
      this.lastMessageTime,
      required this.unreadCount,
      this.parentConversationId,
      this.forkFromMessageId,
      this.conflictOf,
      this.deletedAt,
      this.purgeAt,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || avatarUrl != null) {
      map['avatar_url'] = Variable<String>(avatarUrl);
    }
    if (!nullToAbsent || characterImage != null) {
      map['character_image'] = Variable<String>(characterImage);
    }
    if (!nullToAbsent || selfAddress != null) {
      map['self_address'] = Variable<String>(selfAddress);
    }
    if (!nullToAbsent || addressUser != null) {
      map['address_user'] = Variable<String>(addressUser);
    }
    if (!nullToAbsent || voiceFile != null) {
      map['voice_file'] = Variable<String>(voiceFile);
    }
    map['persona_prompt'] = Variable<String>(personaPrompt);
    if (!nullToAbsent || defaultProvider != null) {
      map['default_provider'] = Variable<String>(defaultProvider);
    }
    if (!nullToAbsent || sessionProvider != null) {
      map['session_provider'] = Variable<String>(sessionProvider);
    }
    map['is_pinned'] = Variable<bool>(isPinned);
    map['is_favorite'] = Variable<bool>(isFavorite);
    map['is_muted'] = Variable<bool>(isMuted);
    map['notification_sound'] = Variable<bool>(notificationSound);
    if (!nullToAbsent || lastMessage != null) {
      map['last_message'] = Variable<String>(lastMessage);
    }
    if (!nullToAbsent || lastMessageTime != null) {
      map['last_message_time'] = Variable<int>(lastMessageTime);
    }
    map['unread_count'] = Variable<int>(unreadCount);
    if (!nullToAbsent || parentConversationId != null) {
      map['parent_conversation_id'] = Variable<String>(parentConversationId);
    }
    if (!nullToAbsent || forkFromMessageId != null) {
      map['fork_from_message_id'] = Variable<String>(forkFromMessageId);
    }
    if (!nullToAbsent || conflictOf != null) {
      map['conflict_of'] = Variable<String>(conflictOf);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || purgeAt != null) {
      map['purge_at'] = Variable<int>(purgeAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      title: Value(title),
      displayName: Value(displayName),
      avatarUrl: avatarUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(avatarUrl),
      characterImage: characterImage == null && nullToAbsent
          ? const Value.absent()
          : Value(characterImage),
      selfAddress: selfAddress == null && nullToAbsent
          ? const Value.absent()
          : Value(selfAddress),
      addressUser: addressUser == null && nullToAbsent
          ? const Value.absent()
          : Value(addressUser),
      voiceFile: voiceFile == null && nullToAbsent
          ? const Value.absent()
          : Value(voiceFile),
      personaPrompt: Value(personaPrompt),
      defaultProvider: defaultProvider == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultProvider),
      sessionProvider: sessionProvider == null && nullToAbsent
          ? const Value.absent()
          : Value(sessionProvider),
      isPinned: Value(isPinned),
      isFavorite: Value(isFavorite),
      isMuted: Value(isMuted),
      notificationSound: Value(notificationSound),
      lastMessage: lastMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessage),
      lastMessageTime: lastMessageTime == null && nullToAbsent
          ? const Value.absent()
          : Value(lastMessageTime),
      unreadCount: Value(unreadCount),
      parentConversationId: parentConversationId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentConversationId),
      forkFromMessageId: forkFromMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(forkFromMessageId),
      conflictOf: conflictOf == null && nullToAbsent
          ? const Value.absent()
          : Value(conflictOf),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      purgeAt: purgeAt == null && nullToAbsent
          ? const Value.absent()
          : Value(purgeAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Conversation.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Conversation(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      displayName: serializer.fromJson<String>(json['displayName']),
      avatarUrl: serializer.fromJson<String?>(json['avatarUrl']),
      characterImage: serializer.fromJson<String?>(json['characterImage']),
      selfAddress: serializer.fromJson<String?>(json['selfAddress']),
      addressUser: serializer.fromJson<String?>(json['addressUser']),
      voiceFile: serializer.fromJson<String?>(json['voiceFile']),
      personaPrompt: serializer.fromJson<String>(json['personaPrompt']),
      defaultProvider: serializer.fromJson<String?>(json['defaultProvider']),
      sessionProvider: serializer.fromJson<String?>(json['sessionProvider']),
      isPinned: serializer.fromJson<bool>(json['isPinned']),
      isFavorite: serializer.fromJson<bool>(json['isFavorite']),
      isMuted: serializer.fromJson<bool>(json['isMuted']),
      notificationSound: serializer.fromJson<bool>(json['notificationSound']),
      lastMessage: serializer.fromJson<String?>(json['lastMessage']),
      lastMessageTime: serializer.fromJson<int?>(json['lastMessageTime']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      parentConversationId:
          serializer.fromJson<String?>(json['parentConversationId']),
      forkFromMessageId:
          serializer.fromJson<String?>(json['forkFromMessageId']),
      conflictOf: serializer.fromJson<String?>(json['conflictOf']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      purgeAt: serializer.fromJson<int?>(json['purgeAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'displayName': serializer.toJson<String>(displayName),
      'avatarUrl': serializer.toJson<String?>(avatarUrl),
      'characterImage': serializer.toJson<String?>(characterImage),
      'selfAddress': serializer.toJson<String?>(selfAddress),
      'addressUser': serializer.toJson<String?>(addressUser),
      'voiceFile': serializer.toJson<String?>(voiceFile),
      'personaPrompt': serializer.toJson<String>(personaPrompt),
      'defaultProvider': serializer.toJson<String?>(defaultProvider),
      'sessionProvider': serializer.toJson<String?>(sessionProvider),
      'isPinned': serializer.toJson<bool>(isPinned),
      'isFavorite': serializer.toJson<bool>(isFavorite),
      'isMuted': serializer.toJson<bool>(isMuted),
      'notificationSound': serializer.toJson<bool>(notificationSound),
      'lastMessage': serializer.toJson<String?>(lastMessage),
      'lastMessageTime': serializer.toJson<int?>(lastMessageTime),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'parentConversationId': serializer.toJson<String?>(parentConversationId),
      'forkFromMessageId': serializer.toJson<String?>(forkFromMessageId),
      'conflictOf': serializer.toJson<String?>(conflictOf),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'purgeAt': serializer.toJson<int?>(purgeAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Conversation copyWith(
          {String? id,
          String? title,
          String? displayName,
          Value<String?> avatarUrl = const Value.absent(),
          Value<String?> characterImage = const Value.absent(),
          Value<String?> selfAddress = const Value.absent(),
          Value<String?> addressUser = const Value.absent(),
          Value<String?> voiceFile = const Value.absent(),
          String? personaPrompt,
          Value<String?> defaultProvider = const Value.absent(),
          Value<String?> sessionProvider = const Value.absent(),
          bool? isPinned,
          bool? isFavorite,
          bool? isMuted,
          bool? notificationSound,
          Value<String?> lastMessage = const Value.absent(),
          Value<int?> lastMessageTime = const Value.absent(),
          int? unreadCount,
          Value<String?> parentConversationId = const Value.absent(),
          Value<String?> forkFromMessageId = const Value.absent(),
          Value<String?> conflictOf = const Value.absent(),
          Value<int?> deletedAt = const Value.absent(),
          Value<int?> purgeAt = const Value.absent(),
          int? createdAt,
          int? updatedAt}) =>
      Conversation(
        id: id ?? this.id,
        title: title ?? this.title,
        displayName: displayName ?? this.displayName,
        avatarUrl: avatarUrl.present ? avatarUrl.value : this.avatarUrl,
        characterImage:
            characterImage.present ? characterImage.value : this.characterImage,
        selfAddress: selfAddress.present ? selfAddress.value : this.selfAddress,
        addressUser: addressUser.present ? addressUser.value : this.addressUser,
        voiceFile: voiceFile.present ? voiceFile.value : this.voiceFile,
        personaPrompt: personaPrompt ?? this.personaPrompt,
        defaultProvider: defaultProvider.present
            ? defaultProvider.value
            : this.defaultProvider,
        sessionProvider: sessionProvider.present
            ? sessionProvider.value
            : this.sessionProvider,
        isPinned: isPinned ?? this.isPinned,
        isFavorite: isFavorite ?? this.isFavorite,
        isMuted: isMuted ?? this.isMuted,
        notificationSound: notificationSound ?? this.notificationSound,
        lastMessage: lastMessage.present ? lastMessage.value : this.lastMessage,
        lastMessageTime: lastMessageTime.present
            ? lastMessageTime.value
            : this.lastMessageTime,
        unreadCount: unreadCount ?? this.unreadCount,
        parentConversationId: parentConversationId.present
            ? parentConversationId.value
            : this.parentConversationId,
        forkFromMessageId: forkFromMessageId.present
            ? forkFromMessageId.value
            : this.forkFromMessageId,
        conflictOf: conflictOf.present ? conflictOf.value : this.conflictOf,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        purgeAt: purgeAt.present ? purgeAt.value : this.purgeAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      displayName:
          data.displayName.present ? data.displayName.value : this.displayName,
      avatarUrl: data.avatarUrl.present ? data.avatarUrl.value : this.avatarUrl,
      characterImage: data.characterImage.present
          ? data.characterImage.value
          : this.characterImage,
      selfAddress:
          data.selfAddress.present ? data.selfAddress.value : this.selfAddress,
      addressUser:
          data.addressUser.present ? data.addressUser.value : this.addressUser,
      voiceFile: data.voiceFile.present ? data.voiceFile.value : this.voiceFile,
      personaPrompt: data.personaPrompt.present
          ? data.personaPrompt.value
          : this.personaPrompt,
      defaultProvider: data.defaultProvider.present
          ? data.defaultProvider.value
          : this.defaultProvider,
      sessionProvider: data.sessionProvider.present
          ? data.sessionProvider.value
          : this.sessionProvider,
      isPinned: data.isPinned.present ? data.isPinned.value : this.isPinned,
      isFavorite:
          data.isFavorite.present ? data.isFavorite.value : this.isFavorite,
      isMuted: data.isMuted.present ? data.isMuted.value : this.isMuted,
      notificationSound: data.notificationSound.present
          ? data.notificationSound.value
          : this.notificationSound,
      lastMessage:
          data.lastMessage.present ? data.lastMessage.value : this.lastMessage,
      lastMessageTime: data.lastMessageTime.present
          ? data.lastMessageTime.value
          : this.lastMessageTime,
      unreadCount:
          data.unreadCount.present ? data.unreadCount.value : this.unreadCount,
      parentConversationId: data.parentConversationId.present
          ? data.parentConversationId.value
          : this.parentConversationId,
      forkFromMessageId: data.forkFromMessageId.present
          ? data.forkFromMessageId.value
          : this.forkFromMessageId,
      conflictOf:
          data.conflictOf.present ? data.conflictOf.value : this.conflictOf,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      purgeAt: data.purgeAt.present ? data.purgeAt.value : this.purgeAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('displayName: $displayName, ')
          ..write('avatarUrl: $avatarUrl, ')
          ..write('characterImage: $characterImage, ')
          ..write('selfAddress: $selfAddress, ')
          ..write('addressUser: $addressUser, ')
          ..write('voiceFile: $voiceFile, ')
          ..write('personaPrompt: $personaPrompt, ')
          ..write('defaultProvider: $defaultProvider, ')
          ..write('sessionProvider: $sessionProvider, ')
          ..write('isPinned: $isPinned, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('isMuted: $isMuted, ')
          ..write('notificationSound: $notificationSound, ')
          ..write('lastMessage: $lastMessage, ')
          ..write('lastMessageTime: $lastMessageTime, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('parentConversationId: $parentConversationId, ')
          ..write('forkFromMessageId: $forkFromMessageId, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        title,
        displayName,
        avatarUrl,
        characterImage,
        selfAddress,
        addressUser,
        voiceFile,
        personaPrompt,
        defaultProvider,
        sessionProvider,
        isPinned,
        isFavorite,
        isMuted,
        notificationSound,
        lastMessage,
        lastMessageTime,
        unreadCount,
        parentConversationId,
        forkFromMessageId,
        conflictOf,
        deletedAt,
        purgeAt,
        createdAt,
        updatedAt
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.id == this.id &&
          other.title == this.title &&
          other.displayName == this.displayName &&
          other.avatarUrl == this.avatarUrl &&
          other.characterImage == this.characterImage &&
          other.selfAddress == this.selfAddress &&
          other.addressUser == this.addressUser &&
          other.voiceFile == this.voiceFile &&
          other.personaPrompt == this.personaPrompt &&
          other.defaultProvider == this.defaultProvider &&
          other.sessionProvider == this.sessionProvider &&
          other.isPinned == this.isPinned &&
          other.isFavorite == this.isFavorite &&
          other.isMuted == this.isMuted &&
          other.notificationSound == this.notificationSound &&
          other.lastMessage == this.lastMessage &&
          other.lastMessageTime == this.lastMessageTime &&
          other.unreadCount == this.unreadCount &&
          other.parentConversationId == this.parentConversationId &&
          other.forkFromMessageId == this.forkFromMessageId &&
          other.conflictOf == this.conflictOf &&
          other.deletedAt == this.deletedAt &&
          other.purgeAt == this.purgeAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> displayName;
  final Value<String?> avatarUrl;
  final Value<String?> characterImage;
  final Value<String?> selfAddress;
  final Value<String?> addressUser;
  final Value<String?> voiceFile;
  final Value<String> personaPrompt;
  final Value<String?> defaultProvider;
  final Value<String?> sessionProvider;
  final Value<bool> isPinned;
  final Value<bool> isFavorite;
  final Value<bool> isMuted;
  final Value<bool> notificationSound;
  final Value<String?> lastMessage;
  final Value<int?> lastMessageTime;
  final Value<int> unreadCount;
  final Value<String?> parentConversationId;
  final Value<String?> forkFromMessageId;
  final Value<String?> conflictOf;
  final Value<int?> deletedAt;
  final Value<int?> purgeAt;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatarUrl = const Value.absent(),
    this.characterImage = const Value.absent(),
    this.selfAddress = const Value.absent(),
    this.addressUser = const Value.absent(),
    this.voiceFile = const Value.absent(),
    this.personaPrompt = const Value.absent(),
    this.defaultProvider = const Value.absent(),
    this.sessionProvider = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.isMuted = const Value.absent(),
    this.notificationSound = const Value.absent(),
    this.lastMessage = const Value.absent(),
    this.lastMessageTime = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.parentConversationId = const Value.absent(),
    this.forkFromMessageId = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    required String title,
    required String displayName,
    this.avatarUrl = const Value.absent(),
    this.characterImage = const Value.absent(),
    this.selfAddress = const Value.absent(),
    this.addressUser = const Value.absent(),
    this.voiceFile = const Value.absent(),
    this.personaPrompt = const Value.absent(),
    this.defaultProvider = const Value.absent(),
    this.sessionProvider = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.isMuted = const Value.absent(),
    this.notificationSound = const Value.absent(),
    this.lastMessage = const Value.absent(),
    this.lastMessageTime = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.parentConversationId = const Value.absent(),
    this.forkFromMessageId = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        title = Value(title),
        displayName = Value(displayName),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<Conversation> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? displayName,
    Expression<String>? avatarUrl,
    Expression<String>? characterImage,
    Expression<String>? selfAddress,
    Expression<String>? addressUser,
    Expression<String>? voiceFile,
    Expression<String>? personaPrompt,
    Expression<String>? defaultProvider,
    Expression<String>? sessionProvider,
    Expression<bool>? isPinned,
    Expression<bool>? isFavorite,
    Expression<bool>? isMuted,
    Expression<bool>? notificationSound,
    Expression<String>? lastMessage,
    Expression<int>? lastMessageTime,
    Expression<int>? unreadCount,
    Expression<String>? parentConversationId,
    Expression<String>? forkFromMessageId,
    Expression<String>? conflictOf,
    Expression<int>? deletedAt,
    Expression<int>? purgeAt,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (displayName != null) 'display_name': displayName,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (characterImage != null) 'character_image': characterImage,
      if (selfAddress != null) 'self_address': selfAddress,
      if (addressUser != null) 'address_user': addressUser,
      if (voiceFile != null) 'voice_file': voiceFile,
      if (personaPrompt != null) 'persona_prompt': personaPrompt,
      if (defaultProvider != null) 'default_provider': defaultProvider,
      if (sessionProvider != null) 'session_provider': sessionProvider,
      if (isPinned != null) 'is_pinned': isPinned,
      if (isFavorite != null) 'is_favorite': isFavorite,
      if (isMuted != null) 'is_muted': isMuted,
      if (notificationSound != null) 'notification_sound': notificationSound,
      if (lastMessage != null) 'last_message': lastMessage,
      if (lastMessageTime != null) 'last_message_time': lastMessageTime,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (parentConversationId != null)
        'parent_conversation_id': parentConversationId,
      if (forkFromMessageId != null) 'fork_from_message_id': forkFromMessageId,
      if (conflictOf != null) 'conflict_of': conflictOf,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (purgeAt != null) 'purge_at': purgeAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith(
      {Value<String>? id,
      Value<String>? title,
      Value<String>? displayName,
      Value<String?>? avatarUrl,
      Value<String?>? characterImage,
      Value<String?>? selfAddress,
      Value<String?>? addressUser,
      Value<String?>? voiceFile,
      Value<String>? personaPrompt,
      Value<String?>? defaultProvider,
      Value<String?>? sessionProvider,
      Value<bool>? isPinned,
      Value<bool>? isFavorite,
      Value<bool>? isMuted,
      Value<bool>? notificationSound,
      Value<String?>? lastMessage,
      Value<int?>? lastMessageTime,
      Value<int>? unreadCount,
      Value<String?>? parentConversationId,
      Value<String?>? forkFromMessageId,
      Value<String?>? conflictOf,
      Value<int?>? deletedAt,
      Value<int?>? purgeAt,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      characterImage: characterImage ?? this.characterImage,
      selfAddress: selfAddress ?? this.selfAddress,
      addressUser: addressUser ?? this.addressUser,
      voiceFile: voiceFile ?? this.voiceFile,
      personaPrompt: personaPrompt ?? this.personaPrompt,
      defaultProvider: defaultProvider ?? this.defaultProvider,
      sessionProvider: sessionProvider ?? this.sessionProvider,
      isPinned: isPinned ?? this.isPinned,
      isFavorite: isFavorite ?? this.isFavorite,
      isMuted: isMuted ?? this.isMuted,
      notificationSound: notificationSound ?? this.notificationSound,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      parentConversationId: parentConversationId ?? this.parentConversationId,
      forkFromMessageId: forkFromMessageId ?? this.forkFromMessageId,
      conflictOf: conflictOf ?? this.conflictOf,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatarUrl.present) {
      map['avatar_url'] = Variable<String>(avatarUrl.value);
    }
    if (characterImage.present) {
      map['character_image'] = Variable<String>(characterImage.value);
    }
    if (selfAddress.present) {
      map['self_address'] = Variable<String>(selfAddress.value);
    }
    if (addressUser.present) {
      map['address_user'] = Variable<String>(addressUser.value);
    }
    if (voiceFile.present) {
      map['voice_file'] = Variable<String>(voiceFile.value);
    }
    if (personaPrompt.present) {
      map['persona_prompt'] = Variable<String>(personaPrompt.value);
    }
    if (defaultProvider.present) {
      map['default_provider'] = Variable<String>(defaultProvider.value);
    }
    if (sessionProvider.present) {
      map['session_provider'] = Variable<String>(sessionProvider.value);
    }
    if (isPinned.present) {
      map['is_pinned'] = Variable<bool>(isPinned.value);
    }
    if (isFavorite.present) {
      map['is_favorite'] = Variable<bool>(isFavorite.value);
    }
    if (isMuted.present) {
      map['is_muted'] = Variable<bool>(isMuted.value);
    }
    if (notificationSound.present) {
      map['notification_sound'] = Variable<bool>(notificationSound.value);
    }
    if (lastMessage.present) {
      map['last_message'] = Variable<String>(lastMessage.value);
    }
    if (lastMessageTime.present) {
      map['last_message_time'] = Variable<int>(lastMessageTime.value);
    }
    if (unreadCount.present) {
      map['unread_count'] = Variable<int>(unreadCount.value);
    }
    if (parentConversationId.present) {
      map['parent_conversation_id'] =
          Variable<String>(parentConversationId.value);
    }
    if (forkFromMessageId.present) {
      map['fork_from_message_id'] = Variable<String>(forkFromMessageId.value);
    }
    if (conflictOf.present) {
      map['conflict_of'] = Variable<String>(conflictOf.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (purgeAt.present) {
      map['purge_at'] = Variable<int>(purgeAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('displayName: $displayName, ')
          ..write('avatarUrl: $avatarUrl, ')
          ..write('characterImage: $characterImage, ')
          ..write('selfAddress: $selfAddress, ')
          ..write('addressUser: $addressUser, ')
          ..write('voiceFile: $voiceFile, ')
          ..write('personaPrompt: $personaPrompt, ')
          ..write('defaultProvider: $defaultProvider, ')
          ..write('sessionProvider: $sessionProvider, ')
          ..write('isPinned: $isPinned, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('isMuted: $isMuted, ')
          ..write('notificationSound: $notificationSound, ')
          ..write('lastMessage: $lastMessage, ')
          ..write('lastMessageTime: $lastMessageTime, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('parentConversationId: $parentConversationId, ')
          ..write('forkFromMessageId: $forkFromMessageId, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationIdMeta =
      const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
      'conversation_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES conversations (id)'));
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
      'role', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('sent'));
  static const VerificationMeta _replacedByMeta =
      const VerificationMeta('replacedBy');
  @override
  late final GeneratedColumn<String> replacedBy = GeneratedColumn<String>(
      'replaced_by', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _conflictOfMeta =
      const VerificationMeta('conflictOf');
  @override
  late final GeneratedColumn<String> conflictOf = GeneratedColumn<String>(
      'conflict_of', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _purgeAtMeta =
      const VerificationMeta('purgeAt');
  @override
  late final GeneratedColumn<int> purgeAt = GeneratedColumn<int>(
      'purge_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        conversationId,
        role,
        content,
        status,
        replacedBy,
        conflictOf,
        deletedAt,
        purgeAt,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(Insertable<Message> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
          _conversationIdMeta,
          conversationId.isAcceptableOrUnknown(
              data['conversation_id']!, _conversationIdMeta));
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
          _roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('replaced_by')) {
      context.handle(
          _replacedByMeta,
          replacedBy.isAcceptableOrUnknown(
              data['replaced_by']!, _replacedByMeta));
    }
    if (data.containsKey('conflict_of')) {
      context.handle(
          _conflictOfMeta,
          conflictOf.isAcceptableOrUnknown(
              data['conflict_of']!, _conflictOfMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('purge_at')) {
      context.handle(_purgeAtMeta,
          purgeAt.isAcceptableOrUnknown(data['purge_at']!, _purgeAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      role: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      replacedBy: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}replaced_by']),
      conflictOf: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}conflict_of']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      purgeAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}purge_at']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class Message extends DataClass implements Insertable<Message> {
  final String id;
  final String conversationId;
  final String role;
  final String content;
  final String status;
  final String? replacedBy;
  final String? conflictOf;
  final int? deletedAt;
  final int? purgeAt;
  final int createdAt;
  const Message(
      {required this.id,
      required this.conversationId,
      required this.role,
      required this.content,
      required this.status,
      this.replacedBy,
      this.conflictOf,
      this.deletedAt,
      this.purgeAt,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || replacedBy != null) {
      map['replaced_by'] = Variable<String>(replacedBy);
    }
    if (!nullToAbsent || conflictOf != null) {
      map['conflict_of'] = Variable<String>(conflictOf);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || purgeAt != null) {
      map['purge_at'] = Variable<int>(purgeAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      role: Value(role),
      content: Value(content),
      status: Value(status),
      replacedBy: replacedBy == null && nullToAbsent
          ? const Value.absent()
          : Value(replacedBy),
      conflictOf: conflictOf == null && nullToAbsent
          ? const Value.absent()
          : Value(conflictOf),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      purgeAt: purgeAt == null && nullToAbsent
          ? const Value.absent()
          : Value(purgeAt),
      createdAt: Value(createdAt),
    );
  }

  factory Message.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      status: serializer.fromJson<String>(json['status']),
      replacedBy: serializer.fromJson<String?>(json['replacedBy']),
      conflictOf: serializer.fromJson<String?>(json['conflictOf']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      purgeAt: serializer.fromJson<int?>(json['purgeAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'status': serializer.toJson<String>(status),
      'replacedBy': serializer.toJson<String?>(replacedBy),
      'conflictOf': serializer.toJson<String?>(conflictOf),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'purgeAt': serializer.toJson<int?>(purgeAt),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  Message copyWith(
          {String? id,
          String? conversationId,
          String? role,
          String? content,
          String? status,
          Value<String?> replacedBy = const Value.absent(),
          Value<String?> conflictOf = const Value.absent(),
          Value<int?> deletedAt = const Value.absent(),
          Value<int?> purgeAt = const Value.absent(),
          int? createdAt}) =>
      Message(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        role: role ?? this.role,
        content: content ?? this.content,
        status: status ?? this.status,
        replacedBy: replacedBy.present ? replacedBy.value : this.replacedBy,
        conflictOf: conflictOf.present ? conflictOf.value : this.conflictOf,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        purgeAt: purgeAt.present ? purgeAt.value : this.purgeAt,
        createdAt: createdAt ?? this.createdAt,
      );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      status: data.status.present ? data.status.value : this.status,
      replacedBy:
          data.replacedBy.present ? data.replacedBy.value : this.replacedBy,
      conflictOf:
          data.conflictOf.present ? data.conflictOf.value : this.conflictOf,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      purgeAt: data.purgeAt.present ? data.purgeAt.value : this.purgeAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('status: $status, ')
          ..write('replacedBy: $replacedBy, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, role, content, status,
      replacedBy, conflictOf, deletedAt, purgeAt, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.role == this.role &&
          other.content == this.content &&
          other.status == this.status &&
          other.replacedBy == this.replacedBy &&
          other.conflictOf == this.conflictOf &&
          other.deletedAt == this.deletedAt &&
          other.purgeAt == this.purgeAt &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> role;
  final Value<String> content;
  final Value<String> status;
  final Value<String?> replacedBy;
  final Value<String?> conflictOf;
  final Value<int?> deletedAt;
  final Value<int?> purgeAt;
  final Value<int> createdAt;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.status = const Value.absent(),
    this.replacedBy = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String role,
    required String content,
    this.status = const Value.absent(),
    this.replacedBy = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        conversationId = Value(conversationId),
        role = Value(role),
        content = Value(content),
        createdAt = Value(createdAt);
  static Insertable<Message> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<String>? status,
    Expression<String>? replacedBy,
    Expression<String>? conflictOf,
    Expression<int>? deletedAt,
    Expression<int>? purgeAt,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (status != null) 'status': status,
      if (replacedBy != null) 'replaced_by': replacedBy,
      if (conflictOf != null) 'conflict_of': conflictOf,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (purgeAt != null) 'purge_at': purgeAt,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<String>? role,
      Value<String>? content,
      Value<String>? status,
      Value<String?>? replacedBy,
      Value<String?>? conflictOf,
      Value<int?>? deletedAt,
      Value<int?>? purgeAt,
      Value<int>? createdAt,
      Value<int>? rowid}) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      status: status ?? this.status,
      replacedBy: replacedBy ?? this.replacedBy,
      conflictOf: conflictOf ?? this.conflictOf,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (replacedBy.present) {
      map['replaced_by'] = Variable<String>(replacedBy.value);
    }
    if (conflictOf.present) {
      map['conflict_of'] = Variable<String>(conflictOf.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (purgeAt.present) {
      map['purge_at'] = Variable<int>(purgeAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('status: $status, ')
          ..write('replacedBy: $replacedBy, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageBlocksTable extends MessageBlocks
    with TableInfo<$MessageBlocksTable, MessageBlock> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageBlocksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _messageIdMeta =
      const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
      'message_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES messages (id)'));
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
      'type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('success'));
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<String> data = GeneratedColumn<String>(
      'data', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sortOrderMeta =
      const VerificationMeta('sortOrder');
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
      'sort_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, messageId, type, status, data, sortOrder, deletedAt, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_blocks';
  @override
  VerificationContext validateIntegrity(Insertable<MessageBlock> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta,
          messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    }
    if (data.containsKey('data')) {
      context.handle(
          _dataMeta, this.data.isAcceptableOrUnknown(data['data']!, _dataMeta));
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(_sortOrderMeta,
          sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageBlock map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageBlock(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      messageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}message_id'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}type'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      data: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}data'])!,
      sortOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sort_order'])!,
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessageBlocksTable createAlias(String alias) {
    return $MessageBlocksTable(attachedDatabase, alias);
  }
}

class MessageBlock extends DataClass implements Insertable<MessageBlock> {
  final String id;
  final String messageId;
  final String type;
  final String status;
  final String data;
  final int sortOrder;
  final int? deletedAt;
  final int createdAt;
  const MessageBlock(
      {required this.id,
      required this.messageId,
      required this.type,
      required this.status,
      required this.data,
      required this.sortOrder,
      this.deletedAt,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['message_id'] = Variable<String>(messageId);
    map['type'] = Variable<String>(type);
    map['status'] = Variable<String>(status);
    map['data'] = Variable<String>(data);
    map['sort_order'] = Variable<int>(sortOrder);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MessageBlocksCompanion toCompanion(bool nullToAbsent) {
    return MessageBlocksCompanion(
      id: Value(id),
      messageId: Value(messageId),
      type: Value(type),
      status: Value(status),
      data: Value(data),
      sortOrder: Value(sortOrder),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      createdAt: Value(createdAt),
    );
  }

  factory MessageBlock.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageBlock(
      id: serializer.fromJson<String>(json['id']),
      messageId: serializer.fromJson<String>(json['messageId']),
      type: serializer.fromJson<String>(json['type']),
      status: serializer.fromJson<String>(json['status']),
      data: serializer.fromJson<String>(json['data']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'messageId': serializer.toJson<String>(messageId),
      'type': serializer.toJson<String>(type),
      'status': serializer.toJson<String>(status),
      'data': serializer.toJson<String>(data),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  MessageBlock copyWith(
          {String? id,
          String? messageId,
          String? type,
          String? status,
          String? data,
          int? sortOrder,
          Value<int?> deletedAt = const Value.absent(),
          int? createdAt}) =>
      MessageBlock(
        id: id ?? this.id,
        messageId: messageId ?? this.messageId,
        type: type ?? this.type,
        status: status ?? this.status,
        data: data ?? this.data,
        sortOrder: sortOrder ?? this.sortOrder,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        createdAt: createdAt ?? this.createdAt,
      );
  MessageBlock copyWithCompanion(MessageBlocksCompanion data) {
    return MessageBlock(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      type: data.type.present ? data.type.value : this.type,
      status: data.status.present ? data.status.value : this.status,
      data: data.data.present ? data.data.value : this.data,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageBlock(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('data: $data, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, messageId, type, status, data, sortOrder, deletedAt, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageBlock &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.type == this.type &&
          other.status == this.status &&
          other.data == this.data &&
          other.sortOrder == this.sortOrder &&
          other.deletedAt == this.deletedAt &&
          other.createdAt == this.createdAt);
}

class MessageBlocksCompanion extends UpdateCompanion<MessageBlock> {
  final Value<String> id;
  final Value<String> messageId;
  final Value<String> type;
  final Value<String> status;
  final Value<String> data;
  final Value<int> sortOrder;
  final Value<int?> deletedAt;
  final Value<int> createdAt;
  final Value<int> rowid;
  const MessageBlocksCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.type = const Value.absent(),
    this.status = const Value.absent(),
    this.data = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageBlocksCompanion.insert({
    required String id,
    required String messageId,
    required String type,
    this.status = const Value.absent(),
    required String data,
    this.sortOrder = const Value.absent(),
    this.deletedAt = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        messageId = Value(messageId),
        type = Value(type),
        data = Value(data),
        createdAt = Value(createdAt);
  static Insertable<MessageBlock> custom({
    Expression<String>? id,
    Expression<String>? messageId,
    Expression<String>? type,
    Expression<String>? status,
    Expression<String>? data,
    Expression<int>? sortOrder,
    Expression<int>? deletedAt,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (type != null) 'type': type,
      if (status != null) 'status': status,
      if (data != null) 'data': data,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageBlocksCompanion copyWith(
      {Value<String>? id,
      Value<String>? messageId,
      Value<String>? type,
      Value<String>? status,
      Value<String>? data,
      Value<int>? sortOrder,
      Value<int?>? deletedAt,
      Value<int>? createdAt,
      Value<int>? rowid}) {
    return MessageBlocksCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      type: type ?? this.type,
      status: status ?? this.status,
      data: data ?? this.data,
      sortOrder: sortOrder ?? this.sortOrder,
      deletedAt: deletedAt ?? this.deletedAt,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (data.present) {
      map['data'] = Variable<String>(data.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessageBlocksCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('type: $type, ')
          ..write('status: $status, ')
          ..write('data: $data, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProvidersTable extends Providers
    with TableInfo<$ProvidersTable, Provider> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProvidersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _displayNameMeta =
      const VerificationMeta('displayName');
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
      'display_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _apiBaseUrlMeta =
      const VerificationMeta('apiBaseUrl');
  @override
  late final GeneratedColumn<String> apiBaseUrl = GeneratedColumn<String>(
      'api_base_url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _enabledMeta =
      const VerificationMeta('enabled');
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
      'enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("enabled" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _capabilitiesMeta =
      const VerificationMeta('capabilities');
  @override
  late final GeneratedColumn<String> capabilities = GeneratedColumn<String>(
      'capabilities', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _customConfigMeta =
      const VerificationMeta('customConfig');
  @override
  late final GeneratedColumn<String> customConfig = GeneratedColumn<String>(
      'custom_config', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('{}'));
  static const VerificationMeta _modelTypeMeta =
      const VerificationMeta('modelType');
  @override
  late final GeneratedColumn<String> modelType = GeneratedColumn<String>(
      'model_type', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _visibleModelsMeta =
      const VerificationMeta('visibleModels');
  @override
  late final GeneratedColumn<String> visibleModels = GeneratedColumn<String>(
      'visible_models', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _hiddenModelsMeta =
      const VerificationMeta('hiddenModels');
  @override
  late final GeneratedColumn<String> hiddenModels = GeneratedColumn<String>(
      'hidden_models', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _apiKeysMeta =
      const VerificationMeta('apiKeys');
  @override
  late final GeneratedColumn<String> apiKeys = GeneratedColumn<String>(
      'api_keys', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('[]'));
  static const VerificationMeta _conflictOfMeta =
      const VerificationMeta('conflictOf');
  @override
  late final GeneratedColumn<String> conflictOf = GeneratedColumn<String>(
      'conflict_of', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _purgeAtMeta =
      const VerificationMeta('purgeAt');
  @override
  late final GeneratedColumn<int> purgeAt = GeneratedColumn<int>(
      'purge_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        displayName,
        apiBaseUrl,
        enabled,
        capabilities,
        customConfig,
        modelType,
        visibleModels,
        hiddenModels,
        apiKeys,
        conflictOf,
        deletedAt,
        purgeAt,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'providers';
  @override
  VerificationContext validateIntegrity(Insertable<Provider> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
          _displayNameMeta,
          displayName.isAcceptableOrUnknown(
              data['display_name']!, _displayNameMeta));
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('api_base_url')) {
      context.handle(
          _apiBaseUrlMeta,
          apiBaseUrl.isAcceptableOrUnknown(
              data['api_base_url']!, _apiBaseUrlMeta));
    } else if (isInserting) {
      context.missing(_apiBaseUrlMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(_enabledMeta,
          enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta));
    }
    if (data.containsKey('capabilities')) {
      context.handle(
          _capabilitiesMeta,
          capabilities.isAcceptableOrUnknown(
              data['capabilities']!, _capabilitiesMeta));
    }
    if (data.containsKey('custom_config')) {
      context.handle(
          _customConfigMeta,
          customConfig.isAcceptableOrUnknown(
              data['custom_config']!, _customConfigMeta));
    }
    if (data.containsKey('model_type')) {
      context.handle(_modelTypeMeta,
          modelType.isAcceptableOrUnknown(data['model_type']!, _modelTypeMeta));
    }
    if (data.containsKey('visible_models')) {
      context.handle(
          _visibleModelsMeta,
          visibleModels.isAcceptableOrUnknown(
              data['visible_models']!, _visibleModelsMeta));
    }
    if (data.containsKey('hidden_models')) {
      context.handle(
          _hiddenModelsMeta,
          hiddenModels.isAcceptableOrUnknown(
              data['hidden_models']!, _hiddenModelsMeta));
    }
    if (data.containsKey('api_keys')) {
      context.handle(_apiKeysMeta,
          apiKeys.isAcceptableOrUnknown(data['api_keys']!, _apiKeysMeta));
    }
    if (data.containsKey('conflict_of')) {
      context.handle(
          _conflictOfMeta,
          conflictOf.isAcceptableOrUnknown(
              data['conflict_of']!, _conflictOfMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('purge_at')) {
      context.handle(_purgeAtMeta,
          purgeAt.isAcceptableOrUnknown(data['purge_at']!, _purgeAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Provider map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Provider(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      displayName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}display_name'])!,
      apiBaseUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}api_base_url'])!,
      enabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}enabled'])!,
      capabilities: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}capabilities'])!,
      customConfig: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}custom_config'])!,
      modelType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}model_type']),
      visibleModels: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}visible_models'])!,
      hiddenModels: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}hidden_models'])!,
      apiKeys: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}api_keys'])!,
      conflictOf: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}conflict_of']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      purgeAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}purge_at']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ProvidersTable createAlias(String alias) {
    return $ProvidersTable(attachedDatabase, alias);
  }
}

class Provider extends DataClass implements Insertable<Provider> {
  final String id;
  final String displayName;
  final String apiBaseUrl;
  final bool enabled;
  final String capabilities;
  final String customConfig;
  final String? modelType;
  final String visibleModels;
  final String hiddenModels;
  final String apiKeys;
  final String? conflictOf;
  final int? deletedAt;
  final int? purgeAt;
  final int createdAt;
  final int updatedAt;
  const Provider(
      {required this.id,
      required this.displayName,
      required this.apiBaseUrl,
      required this.enabled,
      required this.capabilities,
      required this.customConfig,
      this.modelType,
      required this.visibleModels,
      required this.hiddenModels,
      required this.apiKeys,
      this.conflictOf,
      this.deletedAt,
      this.purgeAt,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    map['api_base_url'] = Variable<String>(apiBaseUrl);
    map['enabled'] = Variable<bool>(enabled);
    map['capabilities'] = Variable<String>(capabilities);
    map['custom_config'] = Variable<String>(customConfig);
    if (!nullToAbsent || modelType != null) {
      map['model_type'] = Variable<String>(modelType);
    }
    map['visible_models'] = Variable<String>(visibleModels);
    map['hidden_models'] = Variable<String>(hiddenModels);
    map['api_keys'] = Variable<String>(apiKeys);
    if (!nullToAbsent || conflictOf != null) {
      map['conflict_of'] = Variable<String>(conflictOf);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || purgeAt != null) {
      map['purge_at'] = Variable<int>(purgeAt);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  ProvidersCompanion toCompanion(bool nullToAbsent) {
    return ProvidersCompanion(
      id: Value(id),
      displayName: Value(displayName),
      apiBaseUrl: Value(apiBaseUrl),
      enabled: Value(enabled),
      capabilities: Value(capabilities),
      customConfig: Value(customConfig),
      modelType: modelType == null && nullToAbsent
          ? const Value.absent()
          : Value(modelType),
      visibleModels: Value(visibleModels),
      hiddenModels: Value(hiddenModels),
      apiKeys: Value(apiKeys),
      conflictOf: conflictOf == null && nullToAbsent
          ? const Value.absent()
          : Value(conflictOf),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      purgeAt: purgeAt == null && nullToAbsent
          ? const Value.absent()
          : Value(purgeAt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Provider.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Provider(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      apiBaseUrl: serializer.fromJson<String>(json['apiBaseUrl']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      capabilities: serializer.fromJson<String>(json['capabilities']),
      customConfig: serializer.fromJson<String>(json['customConfig']),
      modelType: serializer.fromJson<String?>(json['modelType']),
      visibleModels: serializer.fromJson<String>(json['visibleModels']),
      hiddenModels: serializer.fromJson<String>(json['hiddenModels']),
      apiKeys: serializer.fromJson<String>(json['apiKeys']),
      conflictOf: serializer.fromJson<String?>(json['conflictOf']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      purgeAt: serializer.fromJson<int?>(json['purgeAt']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'apiBaseUrl': serializer.toJson<String>(apiBaseUrl),
      'enabled': serializer.toJson<bool>(enabled),
      'capabilities': serializer.toJson<String>(capabilities),
      'customConfig': serializer.toJson<String>(customConfig),
      'modelType': serializer.toJson<String?>(modelType),
      'visibleModels': serializer.toJson<String>(visibleModels),
      'hiddenModels': serializer.toJson<String>(hiddenModels),
      'apiKeys': serializer.toJson<String>(apiKeys),
      'conflictOf': serializer.toJson<String?>(conflictOf),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'purgeAt': serializer.toJson<int?>(purgeAt),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Provider copyWith(
          {String? id,
          String? displayName,
          String? apiBaseUrl,
          bool? enabled,
          String? capabilities,
          String? customConfig,
          Value<String?> modelType = const Value.absent(),
          String? visibleModels,
          String? hiddenModels,
          String? apiKeys,
          Value<String?> conflictOf = const Value.absent(),
          Value<int?> deletedAt = const Value.absent(),
          Value<int?> purgeAt = const Value.absent(),
          int? createdAt,
          int? updatedAt}) =>
      Provider(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        enabled: enabled ?? this.enabled,
        capabilities: capabilities ?? this.capabilities,
        customConfig: customConfig ?? this.customConfig,
        modelType: modelType.present ? modelType.value : this.modelType,
        visibleModels: visibleModels ?? this.visibleModels,
        hiddenModels: hiddenModels ?? this.hiddenModels,
        apiKeys: apiKeys ?? this.apiKeys,
        conflictOf: conflictOf.present ? conflictOf.value : this.conflictOf,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        purgeAt: purgeAt.present ? purgeAt.value : this.purgeAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Provider copyWithCompanion(ProvidersCompanion data) {
    return Provider(
      id: data.id.present ? data.id.value : this.id,
      displayName:
          data.displayName.present ? data.displayName.value : this.displayName,
      apiBaseUrl:
          data.apiBaseUrl.present ? data.apiBaseUrl.value : this.apiBaseUrl,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      capabilities: data.capabilities.present
          ? data.capabilities.value
          : this.capabilities,
      customConfig: data.customConfig.present
          ? data.customConfig.value
          : this.customConfig,
      modelType: data.modelType.present ? data.modelType.value : this.modelType,
      visibleModels: data.visibleModels.present
          ? data.visibleModels.value
          : this.visibleModels,
      hiddenModels: data.hiddenModels.present
          ? data.hiddenModels.value
          : this.hiddenModels,
      apiKeys: data.apiKeys.present ? data.apiKeys.value : this.apiKeys,
      conflictOf:
          data.conflictOf.present ? data.conflictOf.value : this.conflictOf,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      purgeAt: data.purgeAt.present ? data.purgeAt.value : this.purgeAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Provider(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('apiBaseUrl: $apiBaseUrl, ')
          ..write('enabled: $enabled, ')
          ..write('capabilities: $capabilities, ')
          ..write('customConfig: $customConfig, ')
          ..write('modelType: $modelType, ')
          ..write('visibleModels: $visibleModels, ')
          ..write('hiddenModels: $hiddenModels, ')
          ..write('apiKeys: $apiKeys, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      displayName,
      apiBaseUrl,
      enabled,
      capabilities,
      customConfig,
      modelType,
      visibleModels,
      hiddenModels,
      apiKeys,
      conflictOf,
      deletedAt,
      purgeAt,
      createdAt,
      updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Provider &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.apiBaseUrl == this.apiBaseUrl &&
          other.enabled == this.enabled &&
          other.capabilities == this.capabilities &&
          other.customConfig == this.customConfig &&
          other.modelType == this.modelType &&
          other.visibleModels == this.visibleModels &&
          other.hiddenModels == this.hiddenModels &&
          other.apiKeys == this.apiKeys &&
          other.conflictOf == this.conflictOf &&
          other.deletedAt == this.deletedAt &&
          other.purgeAt == this.purgeAt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ProvidersCompanion extends UpdateCompanion<Provider> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<String> apiBaseUrl;
  final Value<bool> enabled;
  final Value<String> capabilities;
  final Value<String> customConfig;
  final Value<String?> modelType;
  final Value<String> visibleModels;
  final Value<String> hiddenModels;
  final Value<String> apiKeys;
  final Value<String?> conflictOf;
  final Value<int?> deletedAt;
  final Value<int?> purgeAt;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const ProvidersCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.apiBaseUrl = const Value.absent(),
    this.enabled = const Value.absent(),
    this.capabilities = const Value.absent(),
    this.customConfig = const Value.absent(),
    this.modelType = const Value.absent(),
    this.visibleModels = const Value.absent(),
    this.hiddenModels = const Value.absent(),
    this.apiKeys = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProvidersCompanion.insert({
    required String id,
    required String displayName,
    required String apiBaseUrl,
    this.enabled = const Value.absent(),
    this.capabilities = const Value.absent(),
    this.customConfig = const Value.absent(),
    this.modelType = const Value.absent(),
    this.visibleModels = const Value.absent(),
    this.hiddenModels = const Value.absent(),
    this.apiKeys = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        displayName = Value(displayName),
        apiBaseUrl = Value(apiBaseUrl),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<Provider> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<String>? apiBaseUrl,
    Expression<bool>? enabled,
    Expression<String>? capabilities,
    Expression<String>? customConfig,
    Expression<String>? modelType,
    Expression<String>? visibleModels,
    Expression<String>? hiddenModels,
    Expression<String>? apiKeys,
    Expression<String>? conflictOf,
    Expression<int>? deletedAt,
    Expression<int>? purgeAt,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (apiBaseUrl != null) 'api_base_url': apiBaseUrl,
      if (enabled != null) 'enabled': enabled,
      if (capabilities != null) 'capabilities': capabilities,
      if (customConfig != null) 'custom_config': customConfig,
      if (modelType != null) 'model_type': modelType,
      if (visibleModels != null) 'visible_models': visibleModels,
      if (hiddenModels != null) 'hidden_models': hiddenModels,
      if (apiKeys != null) 'api_keys': apiKeys,
      if (conflictOf != null) 'conflict_of': conflictOf,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (purgeAt != null) 'purge_at': purgeAt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProvidersCompanion copyWith(
      {Value<String>? id,
      Value<String>? displayName,
      Value<String>? apiBaseUrl,
      Value<bool>? enabled,
      Value<String>? capabilities,
      Value<String>? customConfig,
      Value<String?>? modelType,
      Value<String>? visibleModels,
      Value<String>? hiddenModels,
      Value<String>? apiKeys,
      Value<String?>? conflictOf,
      Value<int?>? deletedAt,
      Value<int?>? purgeAt,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return ProvidersCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      enabled: enabled ?? this.enabled,
      capabilities: capabilities ?? this.capabilities,
      customConfig: customConfig ?? this.customConfig,
      modelType: modelType ?? this.modelType,
      visibleModels: visibleModels ?? this.visibleModels,
      hiddenModels: hiddenModels ?? this.hiddenModels,
      apiKeys: apiKeys ?? this.apiKeys,
      conflictOf: conflictOf ?? this.conflictOf,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (apiBaseUrl.present) {
      map['api_base_url'] = Variable<String>(apiBaseUrl.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (capabilities.present) {
      map['capabilities'] = Variable<String>(capabilities.value);
    }
    if (customConfig.present) {
      map['custom_config'] = Variable<String>(customConfig.value);
    }
    if (modelType.present) {
      map['model_type'] = Variable<String>(modelType.value);
    }
    if (visibleModels.present) {
      map['visible_models'] = Variable<String>(visibleModels.value);
    }
    if (hiddenModels.present) {
      map['hidden_models'] = Variable<String>(hiddenModels.value);
    }
    if (apiKeys.present) {
      map['api_keys'] = Variable<String>(apiKeys.value);
    }
    if (conflictOf.present) {
      map['conflict_of'] = Variable<String>(conflictOf.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (purgeAt.present) {
      map['purge_at'] = Variable<int>(purgeAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProvidersCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('apiBaseUrl: $apiBaseUrl, ')
          ..write('enabled: $enabled, ')
          ..write('capabilities: $capabilities, ')
          ..write('customConfig: $customConfig, ')
          ..write('modelType: $modelType, ')
          ..write('visibleModels: $visibleModels, ')
          ..write('hiddenModels: $hiddenModels, ')
          ..write('apiKeys: $apiKeys, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncScopesTable extends SyncScopes
    with TableInfo<$SyncScopesTable, SyncScope> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncScopesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _enabledScopesMeta =
      const VerificationMeta('enabledScopes');
  @override
  late final GeneratedColumn<String> enabledScopes = GeneratedColumn<String>(
      'enabled_scopes', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('["chat.history", "characters.cards"]'));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  @override
  List<GeneratedColumn> get $columns => [enabledScopes, updatedAt, id];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_scopes';
  @override
  VerificationContext validateIntegrity(Insertable<SyncScope> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('enabled_scopes')) {
      context.handle(
          _enabledScopesMeta,
          enabledScopes.isAcceptableOrUnknown(
              data['enabled_scopes']!, _enabledScopesMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncScope map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncScope(
      enabledScopes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}enabled_scopes'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
    );
  }

  @override
  $SyncScopesTable createAlias(String alias) {
    return $SyncScopesTable(attachedDatabase, alias);
  }
}

class SyncScope extends DataClass implements Insertable<SyncScope> {
  final String enabledScopes;
  final int updatedAt;
  final int id;
  const SyncScope(
      {required this.enabledScopes, required this.updatedAt, required this.id});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['enabled_scopes'] = Variable<String>(enabledScopes);
    map['updated_at'] = Variable<int>(updatedAt);
    map['id'] = Variable<int>(id);
    return map;
  }

  SyncScopesCompanion toCompanion(bool nullToAbsent) {
    return SyncScopesCompanion(
      enabledScopes: Value(enabledScopes),
      updatedAt: Value(updatedAt),
      id: Value(id),
    );
  }

  factory SyncScope.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncScope(
      enabledScopes: serializer.fromJson<String>(json['enabledScopes']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      id: serializer.fromJson<int>(json['id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'enabledScopes': serializer.toJson<String>(enabledScopes),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'id': serializer.toJson<int>(id),
    };
  }

  SyncScope copyWith({String? enabledScopes, int? updatedAt, int? id}) =>
      SyncScope(
        enabledScopes: enabledScopes ?? this.enabledScopes,
        updatedAt: updatedAt ?? this.updatedAt,
        id: id ?? this.id,
      );
  SyncScope copyWithCompanion(SyncScopesCompanion data) {
    return SyncScope(
      enabledScopes: data.enabledScopes.present
          ? data.enabledScopes.value
          : this.enabledScopes,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      id: data.id.present ? data.id.value : this.id,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncScope(')
          ..write('enabledScopes: $enabledScopes, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('id: $id')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(enabledScopes, updatedAt, id);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncScope &&
          other.enabledScopes == this.enabledScopes &&
          other.updatedAt == this.updatedAt &&
          other.id == this.id);
}

class SyncScopesCompanion extends UpdateCompanion<SyncScope> {
  final Value<String> enabledScopes;
  final Value<int> updatedAt;
  final Value<int> id;
  const SyncScopesCompanion({
    this.enabledScopes = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.id = const Value.absent(),
  });
  SyncScopesCompanion.insert({
    this.enabledScopes = const Value.absent(),
    required int updatedAt,
    this.id = const Value.absent(),
  }) : updatedAt = Value(updatedAt);
  static Insertable<SyncScope> custom({
    Expression<String>? enabledScopes,
    Expression<int>? updatedAt,
    Expression<int>? id,
  }) {
    return RawValuesInsertable({
      if (enabledScopes != null) 'enabled_scopes': enabledScopes,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (id != null) 'id': id,
    });
  }

  SyncScopesCompanion copyWith(
      {Value<String>? enabledScopes, Value<int>? updatedAt, Value<int>? id}) {
    return SyncScopesCompanion(
      enabledScopes: enabledScopes ?? this.enabledScopes,
      updatedAt: updatedAt ?? this.updatedAt,
      id: id ?? this.id,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (enabledScopes.present) {
      map['enabled_scopes'] = Variable<String>(enabledScopes.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncScopesCompanion(')
          ..write('enabledScopes: $enabledScopes, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('id: $id')
          ..write(')'))
        .toString();
  }
}

class $SyncCursorsTable extends SyncCursors
    with TableInfo<$SyncCursorsTable, SyncCursor> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta =
      const VerificationMeta('deviceId');
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
      'device_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _conversationsCursorMeta =
      const VerificationMeta('conversationsCursor');
  @override
  late final GeneratedColumn<int> conversationsCursor = GeneratedColumn<int>(
      'conversations_cursor', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _messagesCursorMeta =
      const VerificationMeta('messagesCursor');
  @override
  late final GeneratedColumn<int> messagesCursor = GeneratedColumn<int>(
      'messages_cursor', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _providersCursorMeta =
      const VerificationMeta('providersCursor');
  @override
  late final GeneratedColumn<int> providersCursor = GeneratedColumn<int>(
      'providers_cursor', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        deviceId,
        conversationsCursor,
        messagesCursor,
        providersCursor,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_cursors';
  @override
  VerificationContext validateIntegrity(Insertable<SyncCursor> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(_deviceIdMeta,
          deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta));
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('conversations_cursor')) {
      context.handle(
          _conversationsCursorMeta,
          conversationsCursor.isAcceptableOrUnknown(
              data['conversations_cursor']!, _conversationsCursorMeta));
    }
    if (data.containsKey('messages_cursor')) {
      context.handle(
          _messagesCursorMeta,
          messagesCursor.isAcceptableOrUnknown(
              data['messages_cursor']!, _messagesCursorMeta));
    }
    if (data.containsKey('providers_cursor')) {
      context.handle(
          _providersCursorMeta,
          providersCursor.isAcceptableOrUnknown(
              data['providers_cursor']!, _providersCursorMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  SyncCursor map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCursor(
      deviceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}device_id'])!,
      conversationsCursor: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}conversations_cursor'])!,
      messagesCursor: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}messages_cursor'])!,
      providersCursor: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}providers_cursor'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $SyncCursorsTable createAlias(String alias) {
    return $SyncCursorsTable(attachedDatabase, alias);
  }
}

class SyncCursor extends DataClass implements Insertable<SyncCursor> {
  final String deviceId;
  final int conversationsCursor;
  final int messagesCursor;
  final int providersCursor;
  final int updatedAt;
  const SyncCursor(
      {required this.deviceId,
      required this.conversationsCursor,
      required this.messagesCursor,
      required this.providersCursor,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['conversations_cursor'] = Variable<int>(conversationsCursor);
    map['messages_cursor'] = Variable<int>(messagesCursor);
    map['providers_cursor'] = Variable<int>(providersCursor);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  SyncCursorsCompanion toCompanion(bool nullToAbsent) {
    return SyncCursorsCompanion(
      deviceId: Value(deviceId),
      conversationsCursor: Value(conversationsCursor),
      messagesCursor: Value(messagesCursor),
      providersCursor: Value(providersCursor),
      updatedAt: Value(updatedAt),
    );
  }

  factory SyncCursor.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCursor(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      conversationsCursor:
          serializer.fromJson<int>(json['conversationsCursor']),
      messagesCursor: serializer.fromJson<int>(json['messagesCursor']),
      providersCursor: serializer.fromJson<int>(json['providersCursor']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'conversationsCursor': serializer.toJson<int>(conversationsCursor),
      'messagesCursor': serializer.toJson<int>(messagesCursor),
      'providersCursor': serializer.toJson<int>(providersCursor),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  SyncCursor copyWith(
          {String? deviceId,
          int? conversationsCursor,
          int? messagesCursor,
          int? providersCursor,
          int? updatedAt}) =>
      SyncCursor(
        deviceId: deviceId ?? this.deviceId,
        conversationsCursor: conversationsCursor ?? this.conversationsCursor,
        messagesCursor: messagesCursor ?? this.messagesCursor,
        providersCursor: providersCursor ?? this.providersCursor,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  SyncCursor copyWithCompanion(SyncCursorsCompanion data) {
    return SyncCursor(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      conversationsCursor: data.conversationsCursor.present
          ? data.conversationsCursor.value
          : this.conversationsCursor,
      messagesCursor: data.messagesCursor.present
          ? data.messagesCursor.value
          : this.messagesCursor,
      providersCursor: data.providersCursor.present
          ? data.providersCursor.value
          : this.providersCursor,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursor(')
          ..write('deviceId: $deviceId, ')
          ..write('conversationsCursor: $conversationsCursor, ')
          ..write('messagesCursor: $messagesCursor, ')
          ..write('providersCursor: $providersCursor, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(deviceId, conversationsCursor, messagesCursor,
      providersCursor, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCursor &&
          other.deviceId == this.deviceId &&
          other.conversationsCursor == this.conversationsCursor &&
          other.messagesCursor == this.messagesCursor &&
          other.providersCursor == this.providersCursor &&
          other.updatedAt == this.updatedAt);
}

class SyncCursorsCompanion extends UpdateCompanion<SyncCursor> {
  final Value<String> deviceId;
  final Value<int> conversationsCursor;
  final Value<int> messagesCursor;
  final Value<int> providersCursor;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const SyncCursorsCompanion({
    this.deviceId = const Value.absent(),
    this.conversationsCursor = const Value.absent(),
    this.messagesCursor = const Value.absent(),
    this.providersCursor = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCursorsCompanion.insert({
    required String deviceId,
    this.conversationsCursor = const Value.absent(),
    this.messagesCursor = const Value.absent(),
    this.providersCursor = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : deviceId = Value(deviceId),
        updatedAt = Value(updatedAt);
  static Insertable<SyncCursor> custom({
    Expression<String>? deviceId,
    Expression<int>? conversationsCursor,
    Expression<int>? messagesCursor,
    Expression<int>? providersCursor,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (conversationsCursor != null)
        'conversations_cursor': conversationsCursor,
      if (messagesCursor != null) 'messages_cursor': messagesCursor,
      if (providersCursor != null) 'providers_cursor': providersCursor,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCursorsCompanion copyWith(
      {Value<String>? deviceId,
      Value<int>? conversationsCursor,
      Value<int>? messagesCursor,
      Value<int>? providersCursor,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return SyncCursorsCompanion(
      deviceId: deviceId ?? this.deviceId,
      conversationsCursor: conversationsCursor ?? this.conversationsCursor,
      messagesCursor: messagesCursor ?? this.messagesCursor,
      providersCursor: providersCursor ?? this.providersCursor,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (conversationsCursor.present) {
      map['conversations_cursor'] = Variable<int>(conversationsCursor.value);
    }
    if (messagesCursor.present) {
      map['messages_cursor'] = Variable<int>(messagesCursor.value);
    }
    if (providersCursor.present) {
      map['providers_cursor'] = Variable<int>(providersCursor.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorsCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('conversationsCursor: $conversationsCursor, ')
          ..write('messagesCursor: $messagesCursor, ')
          ..write('providersCursor: $providersCursor, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingOperationsTable extends PendingOperations
    with TableInfo<$PendingOperationsTable, PendingOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
      'op_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _opTypeMeta = const VerificationMeta('opType');
  @override
  late final GeneratedColumn<String> opType = GeneratedColumn<String>(
      'op_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _opDataMeta = const VerificationMeta('opData');
  @override
  late final GeneratedColumn<String> opData = GeneratedColumn<String>(
      'op_data', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
      'synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns =>
      [opId, opType, opData, createdAt, synced];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_operations';
  @override
  VerificationContext validateIntegrity(Insertable<PendingOperation> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('op_id')) {
      context.handle(
          _opIdMeta, opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta));
    } else if (isInserting) {
      context.missing(_opIdMeta);
    }
    if (data.containsKey('op_type')) {
      context.handle(_opTypeMeta,
          opType.isAcceptableOrUnknown(data['op_type']!, _opTypeMeta));
    } else if (isInserting) {
      context.missing(_opTypeMeta);
    }
    if (data.containsKey('op_data')) {
      context.handle(_opDataMeta,
          opData.isAcceptableOrUnknown(data['op_data']!, _opDataMeta));
    } else if (isInserting) {
      context.missing(_opDataMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('synced')) {
      context.handle(_syncedMeta,
          synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {opId};
  @override
  PendingOperation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingOperation(
      opId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}op_id'])!,
      opType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}op_type'])!,
      opData: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}op_data'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      synced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}synced'])!,
    );
  }

  @override
  $PendingOperationsTable createAlias(String alias) {
    return $PendingOperationsTable(attachedDatabase, alias);
  }
}

class PendingOperation extends DataClass
    implements Insertable<PendingOperation> {
  final String opId;
  final String opType;
  final String opData;
  final int createdAt;
  final bool synced;
  const PendingOperation(
      {required this.opId,
      required this.opType,
      required this.opData,
      required this.createdAt,
      required this.synced});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['op_id'] = Variable<String>(opId);
    map['op_type'] = Variable<String>(opType);
    map['op_data'] = Variable<String>(opData);
    map['created_at'] = Variable<int>(createdAt);
    map['synced'] = Variable<bool>(synced);
    return map;
  }

  PendingOperationsCompanion toCompanion(bool nullToAbsent) {
    return PendingOperationsCompanion(
      opId: Value(opId),
      opType: Value(opType),
      opData: Value(opData),
      createdAt: Value(createdAt),
      synced: Value(synced),
    );
  }

  factory PendingOperation.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingOperation(
      opId: serializer.fromJson<String>(json['opId']),
      opType: serializer.fromJson<String>(json['opType']),
      opData: serializer.fromJson<String>(json['opData']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      synced: serializer.fromJson<bool>(json['synced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'opId': serializer.toJson<String>(opId),
      'opType': serializer.toJson<String>(opType),
      'opData': serializer.toJson<String>(opData),
      'createdAt': serializer.toJson<int>(createdAt),
      'synced': serializer.toJson<bool>(synced),
    };
  }

  PendingOperation copyWith(
          {String? opId,
          String? opType,
          String? opData,
          int? createdAt,
          bool? synced}) =>
      PendingOperation(
        opId: opId ?? this.opId,
        opType: opType ?? this.opType,
        opData: opData ?? this.opData,
        createdAt: createdAt ?? this.createdAt,
        synced: synced ?? this.synced,
      );
  PendingOperation copyWithCompanion(PendingOperationsCompanion data) {
    return PendingOperation(
      opId: data.opId.present ? data.opId.value : this.opId,
      opType: data.opType.present ? data.opType.value : this.opType,
      opData: data.opData.present ? data.opData.value : this.opData,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      synced: data.synced.present ? data.synced.value : this.synced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperation(')
          ..write('opId: $opId, ')
          ..write('opType: $opType, ')
          ..write('opData: $opData, ')
          ..write('createdAt: $createdAt, ')
          ..write('synced: $synced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(opId, opType, opData, createdAt, synced);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingOperation &&
          other.opId == this.opId &&
          other.opType == this.opType &&
          other.opData == this.opData &&
          other.createdAt == this.createdAt &&
          other.synced == this.synced);
}

class PendingOperationsCompanion extends UpdateCompanion<PendingOperation> {
  final Value<String> opId;
  final Value<String> opType;
  final Value<String> opData;
  final Value<int> createdAt;
  final Value<bool> synced;
  final Value<int> rowid;
  const PendingOperationsCompanion({
    this.opId = const Value.absent(),
    this.opType = const Value.absent(),
    this.opData = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingOperationsCompanion.insert({
    required String opId,
    required String opType,
    required String opData,
    required int createdAt,
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : opId = Value(opId),
        opType = Value(opType),
        opData = Value(opData),
        createdAt = Value(createdAt);
  static Insertable<PendingOperation> custom({
    Expression<String>? opId,
    Expression<String>? opType,
    Expression<String>? opData,
    Expression<int>? createdAt,
    Expression<bool>? synced,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (opId != null) 'op_id': opId,
      if (opType != null) 'op_type': opType,
      if (opData != null) 'op_data': opData,
      if (createdAt != null) 'created_at': createdAt,
      if (synced != null) 'synced': synced,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingOperationsCompanion copyWith(
      {Value<String>? opId,
      Value<String>? opType,
      Value<String>? opData,
      Value<int>? createdAt,
      Value<bool>? synced,
      Value<int>? rowid}) {
    return PendingOperationsCompanion(
      opId: opId ?? this.opId,
      opType: opType ?? this.opType,
      opData: opData ?? this.opData,
      createdAt: createdAt ?? this.createdAt,
      synced: synced ?? this.synced,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (opType.present) {
      map['op_type'] = Variable<String>(opType.value);
    }
    if (opData.present) {
      map['op_data'] = Variable<String>(opData.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperationsCompanion(')
          ..write('opId: $opId, ')
          ..write('opType: $opType, ')
          ..write('opData: $opData, ')
          ..write('createdAt: $createdAt, ')
          ..write('synced: $synced, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MemoriesTable extends Memories with TableInfo<$MemoriesTable, Memory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MemoriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _embeddingMeta =
      const VerificationMeta('embedding');
  @override
  late final GeneratedColumn<String> embedding = GeneratedColumn<String>(
      'embedding', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _persistencePMeta =
      const VerificationMeta('persistenceP');
  @override
  late final GeneratedColumn<double> persistenceP = GeneratedColumn<double>(
      'persistence_p', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.5));
  static const VerificationMeta _emotionEMeta =
      const VerificationMeta('emotionE');
  @override
  late final GeneratedColumn<double> emotionE = GeneratedColumn<double>(
      'emotion_e', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _infoIMeta = const VerificationMeta('infoI');
  @override
  late final GeneratedColumn<double> infoI = GeneratedColumn<double>(
      'info_i', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.5));
  static const VerificationMeta _judgeJMeta = const VerificationMeta('judgeJ');
  @override
  late final GeneratedColumn<double> judgeJ = GeneratedColumn<double>(
      'judge_j', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.5));
  static const VerificationMeta _infoImportanceMeta =
      const VerificationMeta('infoImportance');
  @override
  late final GeneratedColumn<double> infoImportance = GeneratedColumn<double>(
      'info_importance', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.5));
  static const VerificationMeta _timeCoefMeta =
      const VerificationMeta('timeCoef');
  @override
  late final GeneratedColumn<double> timeCoef = GeneratedColumn<double>(
      'time_coef', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(1.0));
  static const VerificationMeta _importanceMeta =
      const VerificationMeta('importance');
  @override
  late final GeneratedColumn<double> importance = GeneratedColumn<double>(
      'importance', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.5));
  static const VerificationMeta _useCountMeta =
      const VerificationMeta('useCount');
  @override
  late final GeneratedColumn<int> useCount = GeneratedColumn<int>(
      'use_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastActiveAtMeta =
      const VerificationMeta('lastActiveAt');
  @override
  late final GeneratedColumn<int> lastActiveAt = GeneratedColumn<int>(
      'last_active_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _purgeAtMeta =
      const VerificationMeta('purgeAt');
  @override
  late final GeneratedColumn<int> purgeAt = GeneratedColumn<int>(
      'purge_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _isSyncedMeta =
      const VerificationMeta('isSynced');
  @override
  late final GeneratedColumn<bool> isSynced = GeneratedColumn<bool>(
      'is_synced', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_synced" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _syncStateMeta =
      const VerificationMeta('syncState');
  @override
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
      'sync_state', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('local'));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        content,
        embedding,
        persistenceP,
        emotionE,
        infoI,
        judgeJ,
        infoImportance,
        timeCoef,
        importance,
        useCount,
        lastActiveAt,
        deletedAt,
        purgeAt,
        isSynced,
        syncState,
        createdAt,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'memories';
  @override
  VerificationContext validateIntegrity(Insertable<Memory> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('embedding')) {
      context.handle(_embeddingMeta,
          embedding.isAcceptableOrUnknown(data['embedding']!, _embeddingMeta));
    }
    if (data.containsKey('persistence_p')) {
      context.handle(
          _persistencePMeta,
          persistenceP.isAcceptableOrUnknown(
              data['persistence_p']!, _persistencePMeta));
    }
    if (data.containsKey('emotion_e')) {
      context.handle(_emotionEMeta,
          emotionE.isAcceptableOrUnknown(data['emotion_e']!, _emotionEMeta));
    }
    if (data.containsKey('info_i')) {
      context.handle(
          _infoIMeta, infoI.isAcceptableOrUnknown(data['info_i']!, _infoIMeta));
    }
    if (data.containsKey('judge_j')) {
      context.handle(_judgeJMeta,
          judgeJ.isAcceptableOrUnknown(data['judge_j']!, _judgeJMeta));
    }
    if (data.containsKey('info_importance')) {
      context.handle(
          _infoImportanceMeta,
          infoImportance.isAcceptableOrUnknown(
              data['info_importance']!, _infoImportanceMeta));
    }
    if (data.containsKey('time_coef')) {
      context.handle(_timeCoefMeta,
          timeCoef.isAcceptableOrUnknown(data['time_coef']!, _timeCoefMeta));
    }
    if (data.containsKey('importance')) {
      context.handle(
          _importanceMeta,
          importance.isAcceptableOrUnknown(
              data['importance']!, _importanceMeta));
    }
    if (data.containsKey('use_count')) {
      context.handle(_useCountMeta,
          useCount.isAcceptableOrUnknown(data['use_count']!, _useCountMeta));
    }
    if (data.containsKey('last_active_at')) {
      context.handle(
          _lastActiveAtMeta,
          lastActiveAt.isAcceptableOrUnknown(
              data['last_active_at']!, _lastActiveAtMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    }
    if (data.containsKey('purge_at')) {
      context.handle(_purgeAtMeta,
          purgeAt.isAcceptableOrUnknown(data['purge_at']!, _purgeAtMeta));
    }
    if (data.containsKey('is_synced')) {
      context.handle(_isSyncedMeta,
          isSynced.isAcceptableOrUnknown(data['is_synced']!, _isSyncedMeta));
    }
    if (data.containsKey('sync_state')) {
      context.handle(_syncStateMeta,
          syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Memory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Memory(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      embedding: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}embedding']),
      persistenceP: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}persistence_p'])!,
      emotionE: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}emotion_e'])!,
      infoI: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}info_i'])!,
      judgeJ: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}judge_j'])!,
      infoImportance: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}info_importance'])!,
      timeCoef: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}time_coef'])!,
      importance: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}importance'])!,
      useCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}use_count'])!,
      lastActiveAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_active_at']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at']),
      purgeAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}purge_at']),
      isSynced: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_synced'])!,
      syncState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_state'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $MemoriesTable createAlias(String alias) {
    return $MemoriesTable(attachedDatabase, alias);
  }
}

class Memory extends DataClass implements Insertable<Memory> {
  final String id;
  final String content;
  final String? embedding;
  final double persistenceP;
  final double emotionE;
  final double infoI;
  final double judgeJ;
  final double infoImportance;
  final double timeCoef;
  final double importance;
  final int useCount;
  final int? lastActiveAt;
  final int? deletedAt;
  final int? purgeAt;
  final bool isSynced;
  final String syncState;
  final int createdAt;
  final int updatedAt;
  const Memory(
      {required this.id,
      required this.content,
      this.embedding,
      required this.persistenceP,
      required this.emotionE,
      required this.infoI,
      required this.judgeJ,
      required this.infoImportance,
      required this.timeCoef,
      required this.importance,
      required this.useCount,
      this.lastActiveAt,
      this.deletedAt,
      this.purgeAt,
      required this.isSynced,
      required this.syncState,
      required this.createdAt,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['content'] = Variable<String>(content);
    if (!nullToAbsent || embedding != null) {
      map['embedding'] = Variable<String>(embedding);
    }
    map['persistence_p'] = Variable<double>(persistenceP);
    map['emotion_e'] = Variable<double>(emotionE);
    map['info_i'] = Variable<double>(infoI);
    map['judge_j'] = Variable<double>(judgeJ);
    map['info_importance'] = Variable<double>(infoImportance);
    map['time_coef'] = Variable<double>(timeCoef);
    map['importance'] = Variable<double>(importance);
    map['use_count'] = Variable<int>(useCount);
    if (!nullToAbsent || lastActiveAt != null) {
      map['last_active_at'] = Variable<int>(lastActiveAt);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || purgeAt != null) {
      map['purge_at'] = Variable<int>(purgeAt);
    }
    map['is_synced'] = Variable<bool>(isSynced);
    map['sync_state'] = Variable<String>(syncState);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  MemoriesCompanion toCompanion(bool nullToAbsent) {
    return MemoriesCompanion(
      id: Value(id),
      content: Value(content),
      embedding: embedding == null && nullToAbsent
          ? const Value.absent()
          : Value(embedding),
      persistenceP: Value(persistenceP),
      emotionE: Value(emotionE),
      infoI: Value(infoI),
      judgeJ: Value(judgeJ),
      infoImportance: Value(infoImportance),
      timeCoef: Value(timeCoef),
      importance: Value(importance),
      useCount: Value(useCount),
      lastActiveAt: lastActiveAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastActiveAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      purgeAt: purgeAt == null && nullToAbsent
          ? const Value.absent()
          : Value(purgeAt),
      isSynced: Value(isSynced),
      syncState: Value(syncState),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory Memory.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Memory(
      id: serializer.fromJson<String>(json['id']),
      content: serializer.fromJson<String>(json['content']),
      embedding: serializer.fromJson<String?>(json['embedding']),
      persistenceP: serializer.fromJson<double>(json['persistenceP']),
      emotionE: serializer.fromJson<double>(json['emotionE']),
      infoI: serializer.fromJson<double>(json['infoI']),
      judgeJ: serializer.fromJson<double>(json['judgeJ']),
      infoImportance: serializer.fromJson<double>(json['infoImportance']),
      timeCoef: serializer.fromJson<double>(json['timeCoef']),
      importance: serializer.fromJson<double>(json['importance']),
      useCount: serializer.fromJson<int>(json['useCount']),
      lastActiveAt: serializer.fromJson<int?>(json['lastActiveAt']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      purgeAt: serializer.fromJson<int?>(json['purgeAt']),
      isSynced: serializer.fromJson<bool>(json['isSynced']),
      syncState: serializer.fromJson<String>(json['syncState']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'content': serializer.toJson<String>(content),
      'embedding': serializer.toJson<String?>(embedding),
      'persistenceP': serializer.toJson<double>(persistenceP),
      'emotionE': serializer.toJson<double>(emotionE),
      'infoI': serializer.toJson<double>(infoI),
      'judgeJ': serializer.toJson<double>(judgeJ),
      'infoImportance': serializer.toJson<double>(infoImportance),
      'timeCoef': serializer.toJson<double>(timeCoef),
      'importance': serializer.toJson<double>(importance),
      'useCount': serializer.toJson<int>(useCount),
      'lastActiveAt': serializer.toJson<int?>(lastActiveAt),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'purgeAt': serializer.toJson<int?>(purgeAt),
      'isSynced': serializer.toJson<bool>(isSynced),
      'syncState': serializer.toJson<String>(syncState),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  Memory copyWith(
          {String? id,
          String? content,
          Value<String?> embedding = const Value.absent(),
          double? persistenceP,
          double? emotionE,
          double? infoI,
          double? judgeJ,
          double? infoImportance,
          double? timeCoef,
          double? importance,
          int? useCount,
          Value<int?> lastActiveAt = const Value.absent(),
          Value<int?> deletedAt = const Value.absent(),
          Value<int?> purgeAt = const Value.absent(),
          bool? isSynced,
          String? syncState,
          int? createdAt,
          int? updatedAt}) =>
      Memory(
        id: id ?? this.id,
        content: content ?? this.content,
        embedding: embedding.present ? embedding.value : this.embedding,
        persistenceP: persistenceP ?? this.persistenceP,
        emotionE: emotionE ?? this.emotionE,
        infoI: infoI ?? this.infoI,
        judgeJ: judgeJ ?? this.judgeJ,
        infoImportance: infoImportance ?? this.infoImportance,
        timeCoef: timeCoef ?? this.timeCoef,
        importance: importance ?? this.importance,
        useCount: useCount ?? this.useCount,
        lastActiveAt:
            lastActiveAt.present ? lastActiveAt.value : this.lastActiveAt,
        deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
        purgeAt: purgeAt.present ? purgeAt.value : this.purgeAt,
        isSynced: isSynced ?? this.isSynced,
        syncState: syncState ?? this.syncState,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Memory copyWithCompanion(MemoriesCompanion data) {
    return Memory(
      id: data.id.present ? data.id.value : this.id,
      content: data.content.present ? data.content.value : this.content,
      embedding: data.embedding.present ? data.embedding.value : this.embedding,
      persistenceP: data.persistenceP.present
          ? data.persistenceP.value
          : this.persistenceP,
      emotionE: data.emotionE.present ? data.emotionE.value : this.emotionE,
      infoI: data.infoI.present ? data.infoI.value : this.infoI,
      judgeJ: data.judgeJ.present ? data.judgeJ.value : this.judgeJ,
      infoImportance: data.infoImportance.present
          ? data.infoImportance.value
          : this.infoImportance,
      timeCoef: data.timeCoef.present ? data.timeCoef.value : this.timeCoef,
      importance:
          data.importance.present ? data.importance.value : this.importance,
      useCount: data.useCount.present ? data.useCount.value : this.useCount,
      lastActiveAt: data.lastActiveAt.present
          ? data.lastActiveAt.value
          : this.lastActiveAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      purgeAt: data.purgeAt.present ? data.purgeAt.value : this.purgeAt,
      isSynced: data.isSynced.present ? data.isSynced.value : this.isSynced,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Memory(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('embedding: $embedding, ')
          ..write('persistenceP: $persistenceP, ')
          ..write('emotionE: $emotionE, ')
          ..write('infoI: $infoI, ')
          ..write('judgeJ: $judgeJ, ')
          ..write('infoImportance: $infoImportance, ')
          ..write('timeCoef: $timeCoef, ')
          ..write('importance: $importance, ')
          ..write('useCount: $useCount, ')
          ..write('lastActiveAt: $lastActiveAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('isSynced: $isSynced, ')
          ..write('syncState: $syncState, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      content,
      embedding,
      persistenceP,
      emotionE,
      infoI,
      judgeJ,
      infoImportance,
      timeCoef,
      importance,
      useCount,
      lastActiveAt,
      deletedAt,
      purgeAt,
      isSynced,
      syncState,
      createdAt,
      updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Memory &&
          other.id == this.id &&
          other.content == this.content &&
          other.embedding == this.embedding &&
          other.persistenceP == this.persistenceP &&
          other.emotionE == this.emotionE &&
          other.infoI == this.infoI &&
          other.judgeJ == this.judgeJ &&
          other.infoImportance == this.infoImportance &&
          other.timeCoef == this.timeCoef &&
          other.importance == this.importance &&
          other.useCount == this.useCount &&
          other.lastActiveAt == this.lastActiveAt &&
          other.deletedAt == this.deletedAt &&
          other.purgeAt == this.purgeAt &&
          other.isSynced == this.isSynced &&
          other.syncState == this.syncState &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class MemoriesCompanion extends UpdateCompanion<Memory> {
  final Value<String> id;
  final Value<String> content;
  final Value<String?> embedding;
  final Value<double> persistenceP;
  final Value<double> emotionE;
  final Value<double> infoI;
  final Value<double> judgeJ;
  final Value<double> infoImportance;
  final Value<double> timeCoef;
  final Value<double> importance;
  final Value<int> useCount;
  final Value<int?> lastActiveAt;
  final Value<int?> deletedAt;
  final Value<int?> purgeAt;
  final Value<bool> isSynced;
  final Value<String> syncState;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const MemoriesCompanion({
    this.id = const Value.absent(),
    this.content = const Value.absent(),
    this.embedding = const Value.absent(),
    this.persistenceP = const Value.absent(),
    this.emotionE = const Value.absent(),
    this.infoI = const Value.absent(),
    this.judgeJ = const Value.absent(),
    this.infoImportance = const Value.absent(),
    this.timeCoef = const Value.absent(),
    this.importance = const Value.absent(),
    this.useCount = const Value.absent(),
    this.lastActiveAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.syncState = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MemoriesCompanion.insert({
    required String id,
    required String content,
    this.embedding = const Value.absent(),
    this.persistenceP = const Value.absent(),
    this.emotionE = const Value.absent(),
    this.infoI = const Value.absent(),
    this.judgeJ = const Value.absent(),
    this.infoImportance = const Value.absent(),
    this.timeCoef = const Value.absent(),
    this.importance = const Value.absent(),
    this.useCount = const Value.absent(),
    this.lastActiveAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.isSynced = const Value.absent(),
    this.syncState = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        content = Value(content),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<Memory> custom({
    Expression<String>? id,
    Expression<String>? content,
    Expression<String>? embedding,
    Expression<double>? persistenceP,
    Expression<double>? emotionE,
    Expression<double>? infoI,
    Expression<double>? judgeJ,
    Expression<double>? infoImportance,
    Expression<double>? timeCoef,
    Expression<double>? importance,
    Expression<int>? useCount,
    Expression<int>? lastActiveAt,
    Expression<int>? deletedAt,
    Expression<int>? purgeAt,
    Expression<bool>? isSynced,
    Expression<String>? syncState,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (content != null) 'content': content,
      if (embedding != null) 'embedding': embedding,
      if (persistenceP != null) 'persistence_p': persistenceP,
      if (emotionE != null) 'emotion_e': emotionE,
      if (infoI != null) 'info_i': infoI,
      if (judgeJ != null) 'judge_j': judgeJ,
      if (infoImportance != null) 'info_importance': infoImportance,
      if (timeCoef != null) 'time_coef': timeCoef,
      if (importance != null) 'importance': importance,
      if (useCount != null) 'use_count': useCount,
      if (lastActiveAt != null) 'last_active_at': lastActiveAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (purgeAt != null) 'purge_at': purgeAt,
      if (isSynced != null) 'is_synced': isSynced,
      if (syncState != null) 'sync_state': syncState,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MemoriesCompanion copyWith(
      {Value<String>? id,
      Value<String>? content,
      Value<String?>? embedding,
      Value<double>? persistenceP,
      Value<double>? emotionE,
      Value<double>? infoI,
      Value<double>? judgeJ,
      Value<double>? infoImportance,
      Value<double>? timeCoef,
      Value<double>? importance,
      Value<int>? useCount,
      Value<int?>? lastActiveAt,
      Value<int?>? deletedAt,
      Value<int?>? purgeAt,
      Value<bool>? isSynced,
      Value<String>? syncState,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int>? rowid}) {
    return MemoriesCompanion(
      id: id ?? this.id,
      content: content ?? this.content,
      embedding: embedding ?? this.embedding,
      persistenceP: persistenceP ?? this.persistenceP,
      emotionE: emotionE ?? this.emotionE,
      infoI: infoI ?? this.infoI,
      judgeJ: judgeJ ?? this.judgeJ,
      infoImportance: infoImportance ?? this.infoImportance,
      timeCoef: timeCoef ?? this.timeCoef,
      importance: importance ?? this.importance,
      useCount: useCount ?? this.useCount,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      isSynced: isSynced ?? this.isSynced,
      syncState: syncState ?? this.syncState,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (embedding.present) {
      map['embedding'] = Variable<String>(embedding.value);
    }
    if (persistenceP.present) {
      map['persistence_p'] = Variable<double>(persistenceP.value);
    }
    if (emotionE.present) {
      map['emotion_e'] = Variable<double>(emotionE.value);
    }
    if (infoI.present) {
      map['info_i'] = Variable<double>(infoI.value);
    }
    if (judgeJ.present) {
      map['judge_j'] = Variable<double>(judgeJ.value);
    }
    if (infoImportance.present) {
      map['info_importance'] = Variable<double>(infoImportance.value);
    }
    if (timeCoef.present) {
      map['time_coef'] = Variable<double>(timeCoef.value);
    }
    if (importance.present) {
      map['importance'] = Variable<double>(importance.value);
    }
    if (useCount.present) {
      map['use_count'] = Variable<int>(useCount.value);
    }
    if (lastActiveAt.present) {
      map['last_active_at'] = Variable<int>(lastActiveAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (purgeAt.present) {
      map['purge_at'] = Variable<int>(purgeAt.value);
    }
    if (isSynced.present) {
      map['is_synced'] = Variable<bool>(isSynced.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MemoriesCompanion(')
          ..write('id: $id, ')
          ..write('content: $content, ')
          ..write('embedding: $embedding, ')
          ..write('persistenceP: $persistenceP, ')
          ..write('emotionE: $emotionE, ')
          ..write('infoI: $infoI, ')
          ..write('judgeJ: $judgeJ, ')
          ..write('infoImportance: $infoImportance, ')
          ..write('timeCoef: $timeCoef, ')
          ..write('importance: $importance, ')
          ..write('useCount: $useCount, ')
          ..write('lastActiveAt: $lastActiveAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('isSynced: $isSynced, ')
          ..write('syncState: $syncState, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MemoryTombstonesTable extends MemoryTombstones
    with TableInfo<$MemoryTombstonesTable, MemoryTombstone> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MemoryTombstonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tombstoneIdMeta =
      const VerificationMeta('tombstoneId');
  @override
  late final GeneratedColumn<String> tombstoneId = GeneratedColumn<String>(
      'tombstone_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _memoryIdMeta =
      const VerificationMeta('memoryId');
  @override
  late final GeneratedColumn<String> memoryId = GeneratedColumn<String>(
      'memory_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
      'reason', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _payloadHashMeta =
      const VerificationMeta('payloadHash');
  @override
  late final GeneratedColumn<String> payloadHash = GeneratedColumn<String>(
      'payload_hash', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
      'deleted_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _purgeAtMeta =
      const VerificationMeta('purgeAt');
  @override
  late final GeneratedColumn<int> purgeAt = GeneratedColumn<int>(
      'purge_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _cloudSyncedAtMeta =
      const VerificationMeta('cloudSyncedAt');
  @override
  late final GeneratedColumn<int> cloudSyncedAt = GeneratedColumn<int>(
      'cloud_synced_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        tombstoneId,
        memoryId,
        reason,
        payloadHash,
        deletedAt,
        purgeAt,
        cloudSyncedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'memory_tombstones';
  @override
  VerificationContext validateIntegrity(Insertable<MemoryTombstone> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tombstone_id')) {
      context.handle(
          _tombstoneIdMeta,
          tombstoneId.isAcceptableOrUnknown(
              data['tombstone_id']!, _tombstoneIdMeta));
    } else if (isInserting) {
      context.missing(_tombstoneIdMeta);
    }
    if (data.containsKey('memory_id')) {
      context.handle(_memoryIdMeta,
          memoryId.isAcceptableOrUnknown(data['memory_id']!, _memoryIdMeta));
    } else if (isInserting) {
      context.missing(_memoryIdMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(_reasonMeta,
          reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta));
    } else if (isInserting) {
      context.missing(_reasonMeta);
    }
    if (data.containsKey('payload_hash')) {
      context.handle(
          _payloadHashMeta,
          payloadHash.isAcceptableOrUnknown(
              data['payload_hash']!, _payloadHashMeta));
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    if (data.containsKey('purge_at')) {
      context.handle(_purgeAtMeta,
          purgeAt.isAcceptableOrUnknown(data['purge_at']!, _purgeAtMeta));
    } else if (isInserting) {
      context.missing(_purgeAtMeta);
    }
    if (data.containsKey('cloud_synced_at')) {
      context.handle(
          _cloudSyncedAtMeta,
          cloudSyncedAt.isAcceptableOrUnknown(
              data['cloud_synced_at']!, _cloudSyncedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tombstoneId};
  @override
  MemoryTombstone map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MemoryTombstone(
      tombstoneId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tombstone_id'])!,
      memoryId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}memory_id'])!,
      reason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}reason'])!,
      payloadHash: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_hash']),
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at'])!,
      purgeAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}purge_at'])!,
      cloudSyncedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}cloud_synced_at']),
    );
  }

  @override
  $MemoryTombstonesTable createAlias(String alias) {
    return $MemoryTombstonesTable(attachedDatabase, alias);
  }
}

class MemoryTombstone extends DataClass implements Insertable<MemoryTombstone> {
  final String tombstoneId;
  final String memoryId;
  final String reason;
  final String? payloadHash;
  final int deletedAt;
  final int purgeAt;
  final int? cloudSyncedAt;
  const MemoryTombstone(
      {required this.tombstoneId,
      required this.memoryId,
      required this.reason,
      this.payloadHash,
      required this.deletedAt,
      required this.purgeAt,
      this.cloudSyncedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tombstone_id'] = Variable<String>(tombstoneId);
    map['memory_id'] = Variable<String>(memoryId);
    map['reason'] = Variable<String>(reason);
    if (!nullToAbsent || payloadHash != null) {
      map['payload_hash'] = Variable<String>(payloadHash);
    }
    map['deleted_at'] = Variable<int>(deletedAt);
    map['purge_at'] = Variable<int>(purgeAt);
    if (!nullToAbsent || cloudSyncedAt != null) {
      map['cloud_synced_at'] = Variable<int>(cloudSyncedAt);
    }
    return map;
  }

  MemoryTombstonesCompanion toCompanion(bool nullToAbsent) {
    return MemoryTombstonesCompanion(
      tombstoneId: Value(tombstoneId),
      memoryId: Value(memoryId),
      reason: Value(reason),
      payloadHash: payloadHash == null && nullToAbsent
          ? const Value.absent()
          : Value(payloadHash),
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
      cloudSyncedAt: cloudSyncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(cloudSyncedAt),
    );
  }

  factory MemoryTombstone.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MemoryTombstone(
      tombstoneId: serializer.fromJson<String>(json['tombstoneId']),
      memoryId: serializer.fromJson<String>(json['memoryId']),
      reason: serializer.fromJson<String>(json['reason']),
      payloadHash: serializer.fromJson<String?>(json['payloadHash']),
      deletedAt: serializer.fromJson<int>(json['deletedAt']),
      purgeAt: serializer.fromJson<int>(json['purgeAt']),
      cloudSyncedAt: serializer.fromJson<int?>(json['cloudSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tombstoneId': serializer.toJson<String>(tombstoneId),
      'memoryId': serializer.toJson<String>(memoryId),
      'reason': serializer.toJson<String>(reason),
      'payloadHash': serializer.toJson<String?>(payloadHash),
      'deletedAt': serializer.toJson<int>(deletedAt),
      'purgeAt': serializer.toJson<int>(purgeAt),
      'cloudSyncedAt': serializer.toJson<int?>(cloudSyncedAt),
    };
  }

  MemoryTombstone copyWith(
          {String? tombstoneId,
          String? memoryId,
          String? reason,
          Value<String?> payloadHash = const Value.absent(),
          int? deletedAt,
          int? purgeAt,
          Value<int?> cloudSyncedAt = const Value.absent()}) =>
      MemoryTombstone(
        tombstoneId: tombstoneId ?? this.tombstoneId,
        memoryId: memoryId ?? this.memoryId,
        reason: reason ?? this.reason,
        payloadHash: payloadHash.present ? payloadHash.value : this.payloadHash,
        deletedAt: deletedAt ?? this.deletedAt,
        purgeAt: purgeAt ?? this.purgeAt,
        cloudSyncedAt:
            cloudSyncedAt.present ? cloudSyncedAt.value : this.cloudSyncedAt,
      );
  MemoryTombstone copyWithCompanion(MemoryTombstonesCompanion data) {
    return MemoryTombstone(
      tombstoneId:
          data.tombstoneId.present ? data.tombstoneId.value : this.tombstoneId,
      memoryId: data.memoryId.present ? data.memoryId.value : this.memoryId,
      reason: data.reason.present ? data.reason.value : this.reason,
      payloadHash:
          data.payloadHash.present ? data.payloadHash.value : this.payloadHash,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      purgeAt: data.purgeAt.present ? data.purgeAt.value : this.purgeAt,
      cloudSyncedAt: data.cloudSyncedAt.present
          ? data.cloudSyncedAt.value
          : this.cloudSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MemoryTombstone(')
          ..write('tombstoneId: $tombstoneId, ')
          ..write('memoryId: $memoryId, ')
          ..write('reason: $reason, ')
          ..write('payloadHash: $payloadHash, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('cloudSyncedAt: $cloudSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(tombstoneId, memoryId, reason, payloadHash,
      deletedAt, purgeAt, cloudSyncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemoryTombstone &&
          other.tombstoneId == this.tombstoneId &&
          other.memoryId == this.memoryId &&
          other.reason == this.reason &&
          other.payloadHash == this.payloadHash &&
          other.deletedAt == this.deletedAt &&
          other.purgeAt == this.purgeAt &&
          other.cloudSyncedAt == this.cloudSyncedAt);
}

class MemoryTombstonesCompanion extends UpdateCompanion<MemoryTombstone> {
  final Value<String> tombstoneId;
  final Value<String> memoryId;
  final Value<String> reason;
  final Value<String?> payloadHash;
  final Value<int> deletedAt;
  final Value<int> purgeAt;
  final Value<int?> cloudSyncedAt;
  final Value<int> rowid;
  const MemoryTombstonesCompanion({
    this.tombstoneId = const Value.absent(),
    this.memoryId = const Value.absent(),
    this.reason = const Value.absent(),
    this.payloadHash = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.purgeAt = const Value.absent(),
    this.cloudSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MemoryTombstonesCompanion.insert({
    required String tombstoneId,
    required String memoryId,
    required String reason,
    this.payloadHash = const Value.absent(),
    required int deletedAt,
    required int purgeAt,
    this.cloudSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : tombstoneId = Value(tombstoneId),
        memoryId = Value(memoryId),
        reason = Value(reason),
        deletedAt = Value(deletedAt),
        purgeAt = Value(purgeAt);
  static Insertable<MemoryTombstone> custom({
    Expression<String>? tombstoneId,
    Expression<String>? memoryId,
    Expression<String>? reason,
    Expression<String>? payloadHash,
    Expression<int>? deletedAt,
    Expression<int>? purgeAt,
    Expression<int>? cloudSyncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tombstoneId != null) 'tombstone_id': tombstoneId,
      if (memoryId != null) 'memory_id': memoryId,
      if (reason != null) 'reason': reason,
      if (payloadHash != null) 'payload_hash': payloadHash,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (purgeAt != null) 'purge_at': purgeAt,
      if (cloudSyncedAt != null) 'cloud_synced_at': cloudSyncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MemoryTombstonesCompanion copyWith(
      {Value<String>? tombstoneId,
      Value<String>? memoryId,
      Value<String>? reason,
      Value<String?>? payloadHash,
      Value<int>? deletedAt,
      Value<int>? purgeAt,
      Value<int?>? cloudSyncedAt,
      Value<int>? rowid}) {
    return MemoryTombstonesCompanion(
      tombstoneId: tombstoneId ?? this.tombstoneId,
      memoryId: memoryId ?? this.memoryId,
      reason: reason ?? this.reason,
      payloadHash: payloadHash ?? this.payloadHash,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      cloudSyncedAt: cloudSyncedAt ?? this.cloudSyncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tombstoneId.present) {
      map['tombstone_id'] = Variable<String>(tombstoneId.value);
    }
    if (memoryId.present) {
      map['memory_id'] = Variable<String>(memoryId.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (payloadHash.present) {
      map['payload_hash'] = Variable<String>(payloadHash.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (purgeAt.present) {
      map['purge_at'] = Variable<int>(purgeAt.value);
    }
    if (cloudSyncedAt.present) {
      map['cloud_synced_at'] = Variable<int>(cloudSyncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MemoryTombstonesCompanion(')
          ..write('tombstoneId: $tombstoneId, ')
          ..write('memoryId: $memoryId, ')
          ..write('reason: $reason, ')
          ..write('payloadHash: $payloadHash, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('cloudSyncedAt: $cloudSyncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $MessageBlocksTable messageBlocks = $MessageBlocksTable(this);
  late final $ProvidersTable providers = $ProvidersTable(this);
  late final $SyncScopesTable syncScopes = $SyncScopesTable(this);
  late final $SyncCursorsTable syncCursors = $SyncCursorsTable(this);
  late final $PendingOperationsTable pendingOperations =
      $PendingOperationsTable(this);
  late final $MemoriesTable memories = $MemoriesTable(this);
  late final $MemoryTombstonesTable memoryTombstones =
      $MemoryTombstonesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        conversations,
        messages,
        messageBlocks,
        providers,
        syncScopes,
        syncCursors,
        pendingOperations,
        memories,
        memoryTombstones
      ];
}

typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion
    Function({
  required String id,
  required String title,
  required String displayName,
  Value<String?> avatarUrl,
  Value<String?> characterImage,
  Value<String?> selfAddress,
  Value<String?> addressUser,
  Value<String?> voiceFile,
  Value<String> personaPrompt,
  Value<String?> defaultProvider,
  Value<String?> sessionProvider,
  Value<bool> isPinned,
  Value<bool> isFavorite,
  Value<bool> isMuted,
  Value<bool> notificationSound,
  Value<String?> lastMessage,
  Value<int?> lastMessageTime,
  Value<int> unreadCount,
  Value<String?> parentConversationId,
  Value<String?> forkFromMessageId,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$ConversationsTableUpdateCompanionBuilder = ConversationsCompanion
    Function({
  Value<String> id,
  Value<String> title,
  Value<String> displayName,
  Value<String?> avatarUrl,
  Value<String?> characterImage,
  Value<String?> selfAddress,
  Value<String?> addressUser,
  Value<String?> voiceFile,
  Value<String> personaPrompt,
  Value<String?> defaultProvider,
  Value<String?> sessionProvider,
  Value<bool> isPinned,
  Value<bool> isFavorite,
  Value<bool> isMuted,
  Value<bool> notificationSound,
  Value<String?> lastMessage,
  Value<int?> lastMessageTime,
  Value<int> unreadCount,
  Value<String?> parentConversationId,
  Value<String?> forkFromMessageId,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

final class $$ConversationsTableReferences
    extends BaseReferences<_$AppDatabase, $ConversationsTable, Conversation> {
  $$ConversationsTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagesTable, List<Message>> _messagesRefsTable(
          _$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.messages,
          aliasName: $_aliasNameGenerator(
              db.conversations.id, db.messages.conversationId));

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager($_db, $_db.messages).filter(
        (f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get avatarUrl => $composableBuilder(
      column: $table.avatarUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get characterImage => $composableBuilder(
      column: $table.characterImage,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get selfAddress => $composableBuilder(
      column: $table.selfAddress, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get addressUser => $composableBuilder(
      column: $table.addressUser, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get voiceFile => $composableBuilder(
      column: $table.voiceFile, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get personaPrompt => $composableBuilder(
      column: $table.personaPrompt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get defaultProvider => $composableBuilder(
      column: $table.defaultProvider,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sessionProvider => $composableBuilder(
      column: $table.sessionProvider,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isPinned => $composableBuilder(
      column: $table.isPinned, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isMuted => $composableBuilder(
      column: $table.isMuted, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get notificationSound => $composableBuilder(
      column: $table.notificationSound,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastMessage => $composableBuilder(
      column: $table.lastMessage, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastMessageTime => $composableBuilder(
      column: $table.lastMessageTime,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get parentConversationId => $composableBuilder(
      column: $table.parentConversationId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get forkFromMessageId => $composableBuilder(
      column: $table.forkFromMessageId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  Expression<bool> messagesRefs(
      Expression<bool> Function($$MessagesTableFilterComposer f) f) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get avatarUrl => $composableBuilder(
      column: $table.avatarUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get characterImage => $composableBuilder(
      column: $table.characterImage,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get selfAddress => $composableBuilder(
      column: $table.selfAddress, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get addressUser => $composableBuilder(
      column: $table.addressUser, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get voiceFile => $composableBuilder(
      column: $table.voiceFile, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get personaPrompt => $composableBuilder(
      column: $table.personaPrompt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get defaultProvider => $composableBuilder(
      column: $table.defaultProvider,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sessionProvider => $composableBuilder(
      column: $table.sessionProvider,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isPinned => $composableBuilder(
      column: $table.isPinned, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isMuted => $composableBuilder(
      column: $table.isMuted, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get notificationSound => $composableBuilder(
      column: $table.notificationSound,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastMessage => $composableBuilder(
      column: $table.lastMessage, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastMessageTime => $composableBuilder(
      column: $table.lastMessageTime,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get parentConversationId => $composableBuilder(
      column: $table.parentConversationId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get forkFromMessageId => $composableBuilder(
      column: $table.forkFromMessageId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => column);

  GeneratedColumn<String> get avatarUrl =>
      $composableBuilder(column: $table.avatarUrl, builder: (column) => column);

  GeneratedColumn<String> get characterImage => $composableBuilder(
      column: $table.characterImage, builder: (column) => column);

  GeneratedColumn<String> get selfAddress => $composableBuilder(
      column: $table.selfAddress, builder: (column) => column);

  GeneratedColumn<String> get addressUser => $composableBuilder(
      column: $table.addressUser, builder: (column) => column);

  GeneratedColumn<String> get voiceFile =>
      $composableBuilder(column: $table.voiceFile, builder: (column) => column);

  GeneratedColumn<String> get personaPrompt => $composableBuilder(
      column: $table.personaPrompt, builder: (column) => column);

  GeneratedColumn<String> get defaultProvider => $composableBuilder(
      column: $table.defaultProvider, builder: (column) => column);

  GeneratedColumn<String> get sessionProvider => $composableBuilder(
      column: $table.sessionProvider, builder: (column) => column);

  GeneratedColumn<bool> get isPinned =>
      $composableBuilder(column: $table.isPinned, builder: (column) => column);

  GeneratedColumn<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => column);

  GeneratedColumn<bool> get isMuted =>
      $composableBuilder(column: $table.isMuted, builder: (column) => column);

  GeneratedColumn<bool> get notificationSound => $composableBuilder(
      column: $table.notificationSound, builder: (column) => column);

  GeneratedColumn<String> get lastMessage => $composableBuilder(
      column: $table.lastMessage, builder: (column) => column);

  GeneratedColumn<int> get lastMessageTime => $composableBuilder(
      column: $table.lastMessageTime, builder: (column) => column);

  GeneratedColumn<int> get unreadCount => $composableBuilder(
      column: $table.unreadCount, builder: (column) => column);

  GeneratedColumn<String> get parentConversationId => $composableBuilder(
      column: $table.parentConversationId, builder: (column) => column);

  GeneratedColumn<String> get forkFromMessageId => $composableBuilder(
      column: $table.forkFromMessageId, builder: (column) => column);

  GeneratedColumn<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get purgeAt =>
      $composableBuilder(column: $table.purgeAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> messagesRefs<T extends Object>(
      Expression<T> Function($$MessagesTableAnnotationComposer a) f) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$ConversationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConversationsTable,
    Conversation,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (Conversation, $$ConversationsTableReferences),
    Conversation,
    PrefetchHooks Function({bool messagesRefs})> {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> displayName = const Value.absent(),
            Value<String?> avatarUrl = const Value.absent(),
            Value<String?> characterImage = const Value.absent(),
            Value<String?> selfAddress = const Value.absent(),
            Value<String?> addressUser = const Value.absent(),
            Value<String?> voiceFile = const Value.absent(),
            Value<String> personaPrompt = const Value.absent(),
            Value<String?> defaultProvider = const Value.absent(),
            Value<String?> sessionProvider = const Value.absent(),
            Value<bool> isPinned = const Value.absent(),
            Value<bool> isFavorite = const Value.absent(),
            Value<bool> isMuted = const Value.absent(),
            Value<bool> notificationSound = const Value.absent(),
            Value<String?> lastMessage = const Value.absent(),
            Value<int?> lastMessageTime = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> parentConversationId = const Value.absent(),
            Value<String?> forkFromMessageId = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion(
            id: id,
            title: title,
            displayName: displayName,
            avatarUrl: avatarUrl,
            characterImage: characterImage,
            selfAddress: selfAddress,
            addressUser: addressUser,
            voiceFile: voiceFile,
            personaPrompt: personaPrompt,
            defaultProvider: defaultProvider,
            sessionProvider: sessionProvider,
            isPinned: isPinned,
            isFavorite: isFavorite,
            isMuted: isMuted,
            notificationSound: notificationSound,
            lastMessage: lastMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: unreadCount,
            parentConversationId: parentConversationId,
            forkFromMessageId: forkFromMessageId,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String title,
            required String displayName,
            Value<String?> avatarUrl = const Value.absent(),
            Value<String?> characterImage = const Value.absent(),
            Value<String?> selfAddress = const Value.absent(),
            Value<String?> addressUser = const Value.absent(),
            Value<String?> voiceFile = const Value.absent(),
            Value<String> personaPrompt = const Value.absent(),
            Value<String?> defaultProvider = const Value.absent(),
            Value<String?> sessionProvider = const Value.absent(),
            Value<bool> isPinned = const Value.absent(),
            Value<bool> isFavorite = const Value.absent(),
            Value<bool> isMuted = const Value.absent(),
            Value<bool> notificationSound = const Value.absent(),
            Value<String?> lastMessage = const Value.absent(),
            Value<int?> lastMessageTime = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> parentConversationId = const Value.absent(),
            Value<String?> forkFromMessageId = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              ConversationsCompanion.insert(
            id: id,
            title: title,
            displayName: displayName,
            avatarUrl: avatarUrl,
            characterImage: characterImage,
            selfAddress: selfAddress,
            addressUser: addressUser,
            voiceFile: voiceFile,
            personaPrompt: personaPrompt,
            defaultProvider: defaultProvider,
            sessionProvider: sessionProvider,
            isPinned: isPinned,
            isFavorite: isFavorite,
            isMuted: isMuted,
            notificationSound: notificationSound,
            lastMessage: lastMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: unreadCount,
            parentConversationId: parentConversationId,
            forkFromMessageId: forkFromMessageId,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$ConversationsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData<Conversation, $ConversationsTable,
                            Message>(
                        currentTable: table,
                        referencedTable: $$ConversationsTableReferences
                            ._messagesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ConversationsTableReferences(db, table, p0)
                                .messagesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.conversationId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ConversationsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ConversationsTable,
    Conversation,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableAnnotationComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder,
    (Conversation, $$ConversationsTableReferences),
    Conversation,
    PrefetchHooks Function({bool messagesRefs})>;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String role,
  required String content,
  Value<String> status,
  Value<String?> replacedBy,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  required int createdAt,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> role,
  Value<String> content,
  Value<String> status,
  Value<String?> replacedBy,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<int> createdAt,
  Value<int> rowid,
});

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, Message> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationsTable _conversationIdTable(_$AppDatabase db) =>
      db.conversations.createAlias($_aliasNameGenerator(
          db.messages.conversationId, db.conversations.id));

  $$ConversationsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationsTableTableManager($_db, $_db.conversations)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$MessageBlocksTable, List<MessageBlock>>
      _messageBlocksRefsTable(_$AppDatabase db) =>
          MultiTypedResultKey.fromTable(db.messageBlocks,
              aliasName: $_aliasNameGenerator(
                  db.messages.id, db.messageBlocks.messageId));

  $$MessageBlocksTableProcessedTableManager get messageBlocksRefs {
    final manager = $$MessageBlocksTableTableManager($_db, $_db.messageBlocks)
        .filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messageBlocksRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get replacedBy => $composableBuilder(
      column: $table.replacedBy, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableFilterComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<bool> messageBlocksRefs(
      Expression<bool> Function($$MessageBlocksTableFilterComposer f) f) {
    final $$MessageBlocksTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messageBlocks,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessageBlocksTableFilterComposer(
              $db: $db,
              $table: $db.messageBlocks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role => $composableBuilder(
      column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get replacedBy => $composableBuilder(
      column: $table.replacedBy, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableOrderingComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get replacedBy => $composableBuilder(
      column: $table.replacedBy, builder: (column) => column);

  GeneratedColumn<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get purgeAt =>
      $composableBuilder(column: $table.purgeAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$ConversationsTableAnnotationComposer(
              $db: $db,
              $table: $db.conversations,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }

  Expression<T> messageBlocksRefs<T extends Object>(
      Expression<T> Function($$MessageBlocksTableAnnotationComposer a) f) {
    final $$MessageBlocksTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.messageBlocks,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessageBlocksTableAnnotationComposer(
              $db: $db,
              $table: $db.messageBlocks,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$MessagesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessagesTable,
    Message,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (Message, $$MessagesTableReferences),
    Message,
    PrefetchHooks Function({bool conversationId, bool messageBlocksRefs})> {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String?> replacedBy = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            status: status,
            replacedBy: replacedBy,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required String role,
            required String content,
            Value<String> status = const Value.absent(),
            Value<String?> replacedBy = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            required int createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            status: status,
            replacedBy: replacedBy,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$MessagesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {conversationId = false, messageBlocksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (messageBlocksRefs) db.messageBlocks
              ],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (conversationId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.conversationId,
                    referencedTable:
                        $$MessagesTableReferences._conversationIdTable(db),
                    referencedColumn:
                        $$MessagesTableReferences._conversationIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messageBlocksRefs)
                    await $_getPrefetchedData<Message, $MessagesTable,
                            MessageBlock>(
                        currentTable: table,
                        referencedTable: $$MessagesTableReferences
                            ._messageBlocksRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$MessagesTableReferences(db, table, p0)
                                .messageBlocksRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.messageId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$MessagesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MessagesTable,
    Message,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableAnnotationComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder,
    (Message, $$MessagesTableReferences),
    Message,
    PrefetchHooks Function({bool conversationId, bool messageBlocksRefs})>;
typedef $$MessageBlocksTableCreateCompanionBuilder = MessageBlocksCompanion
    Function({
  required String id,
  required String messageId,
  required String type,
  Value<String> status,
  required String data,
  Value<int> sortOrder,
  Value<int?> deletedAt,
  required int createdAt,
  Value<int> rowid,
});
typedef $$MessageBlocksTableUpdateCompanionBuilder = MessageBlocksCompanion
    Function({
  Value<String> id,
  Value<String> messageId,
  Value<String> type,
  Value<String> status,
  Value<String> data,
  Value<int> sortOrder,
  Value<int?> deletedAt,
  Value<int> createdAt,
  Value<int> rowid,
});

final class $$MessageBlocksTableReferences
    extends BaseReferences<_$AppDatabase, $MessageBlocksTable, MessageBlock> {
  $$MessageBlocksTableReferences(
      super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias(
          $_aliasNameGenerator(db.messageBlocks.messageId, db.messages.id));

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessagesTableTableManager($_db, $_db.messages)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$MessageBlocksTableFilterComposer
    extends Composer<_$AppDatabase, $MessageBlocksTable> {
  $$MessageBlocksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get data => $composableBuilder(
      column: $table.data, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableFilterComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageBlocksTableOrderingComposer
    extends Composer<_$AppDatabase, $MessageBlocksTable> {
  $$MessageBlocksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get data => $composableBuilder(
      column: $table.data, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sortOrder => $composableBuilder(
      column: $table.sortOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableOrderingComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageBlocksTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessageBlocksTable> {
  $$MessageBlocksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$MessagesTableAnnotationComposer(
              $db: $db,
              $table: $db.messages,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$MessageBlocksTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessageBlocksTable,
    MessageBlock,
    $$MessageBlocksTableFilterComposer,
    $$MessageBlocksTableOrderingComposer,
    $$MessageBlocksTableAnnotationComposer,
    $$MessageBlocksTableCreateCompanionBuilder,
    $$MessageBlocksTableUpdateCompanionBuilder,
    (MessageBlock, $$MessageBlocksTableReferences),
    MessageBlock,
    PrefetchHooks Function({bool messageId})> {
  $$MessageBlocksTableTableManager(_$AppDatabase db, $MessageBlocksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessageBlocksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessageBlocksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessageBlocksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> messageId = const Value.absent(),
            Value<String> type = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String> data = const Value.absent(),
            Value<int> sortOrder = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageBlocksCompanion(
            id: id,
            messageId: messageId,
            type: type,
            status: status,
            data: data,
            sortOrder: sortOrder,
            deletedAt: deletedAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String messageId,
            required String type,
            Value<String> status = const Value.absent(),
            required String data,
            Value<int> sortOrder = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            required int createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageBlocksCompanion.insert(
            id: id,
            messageId: messageId,
            type: type,
            status: status,
            data: data,
            sortOrder: sortOrder,
            deletedAt: deletedAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$MessageBlocksTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({messageId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (messageId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.messageId,
                    referencedTable:
                        $$MessageBlocksTableReferences._messageIdTable(db),
                    referencedColumn:
                        $$MessageBlocksTableReferences._messageIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$MessageBlocksTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MessageBlocksTable,
    MessageBlock,
    $$MessageBlocksTableFilterComposer,
    $$MessageBlocksTableOrderingComposer,
    $$MessageBlocksTableAnnotationComposer,
    $$MessageBlocksTableCreateCompanionBuilder,
    $$MessageBlocksTableUpdateCompanionBuilder,
    (MessageBlock, $$MessageBlocksTableReferences),
    MessageBlock,
    PrefetchHooks Function({bool messageId})>;
typedef $$ProvidersTableCreateCompanionBuilder = ProvidersCompanion Function({
  required String id,
  required String displayName,
  required String apiBaseUrl,
  Value<bool> enabled,
  Value<String> capabilities,
  Value<String> customConfig,
  Value<String?> modelType,
  Value<String> visibleModels,
  Value<String> hiddenModels,
  Value<String> apiKeys,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$ProvidersTableUpdateCompanionBuilder = ProvidersCompanion Function({
  Value<String> id,
  Value<String> displayName,
  Value<String> apiBaseUrl,
  Value<bool> enabled,
  Value<String> capabilities,
  Value<String> customConfig,
  Value<String?> modelType,
  Value<String> visibleModels,
  Value<String> hiddenModels,
  Value<String> apiKeys,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$ProvidersTableFilterComposer
    extends Composer<_$AppDatabase, $ProvidersTable> {
  $$ProvidersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get apiBaseUrl => $composableBuilder(
      column: $table.apiBaseUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get capabilities => $composableBuilder(
      column: $table.capabilities, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get customConfig => $composableBuilder(
      column: $table.customConfig, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get modelType => $composableBuilder(
      column: $table.modelType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get visibleModels => $composableBuilder(
      column: $table.visibleModels, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get hiddenModels => $composableBuilder(
      column: $table.hiddenModels, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get apiKeys => $composableBuilder(
      column: $table.apiKeys, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ProvidersTableOrderingComposer
    extends Composer<_$AppDatabase, $ProvidersTable> {
  $$ProvidersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get apiBaseUrl => $composableBuilder(
      column: $table.apiBaseUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get enabled => $composableBuilder(
      column: $table.enabled, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get capabilities => $composableBuilder(
      column: $table.capabilities,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get customConfig => $composableBuilder(
      column: $table.customConfig,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get modelType => $composableBuilder(
      column: $table.modelType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get visibleModels => $composableBuilder(
      column: $table.visibleModels,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get hiddenModels => $composableBuilder(
      column: $table.hiddenModels,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get apiKeys => $composableBuilder(
      column: $table.apiKeys, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ProvidersTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProvidersTable> {
  $$ProvidersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
      column: $table.displayName, builder: (column) => column);

  GeneratedColumn<String> get apiBaseUrl => $composableBuilder(
      column: $table.apiBaseUrl, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<String> get capabilities => $composableBuilder(
      column: $table.capabilities, builder: (column) => column);

  GeneratedColumn<String> get customConfig => $composableBuilder(
      column: $table.customConfig, builder: (column) => column);

  GeneratedColumn<String> get modelType =>
      $composableBuilder(column: $table.modelType, builder: (column) => column);

  GeneratedColumn<String> get visibleModels => $composableBuilder(
      column: $table.visibleModels, builder: (column) => column);

  GeneratedColumn<String> get hiddenModels => $composableBuilder(
      column: $table.hiddenModels, builder: (column) => column);

  GeneratedColumn<String> get apiKeys =>
      $composableBuilder(column: $table.apiKeys, builder: (column) => column);

  GeneratedColumn<String> get conflictOf => $composableBuilder(
      column: $table.conflictOf, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get purgeAt =>
      $composableBuilder(column: $table.purgeAt, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ProvidersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ProvidersTable,
    Provider,
    $$ProvidersTableFilterComposer,
    $$ProvidersTableOrderingComposer,
    $$ProvidersTableAnnotationComposer,
    $$ProvidersTableCreateCompanionBuilder,
    $$ProvidersTableUpdateCompanionBuilder,
    (Provider, BaseReferences<_$AppDatabase, $ProvidersTable, Provider>),
    Provider,
    PrefetchHooks Function()> {
  $$ProvidersTableTableManager(_$AppDatabase db, $ProvidersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProvidersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProvidersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProvidersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> displayName = const Value.absent(),
            Value<String> apiBaseUrl = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<String> capabilities = const Value.absent(),
            Value<String> customConfig = const Value.absent(),
            Value<String?> modelType = const Value.absent(),
            Value<String> visibleModels = const Value.absent(),
            Value<String> hiddenModels = const Value.absent(),
            Value<String> apiKeys = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ProvidersCompanion(
            id: id,
            displayName: displayName,
            apiBaseUrl: apiBaseUrl,
            enabled: enabled,
            capabilities: capabilities,
            customConfig: customConfig,
            modelType: modelType,
            visibleModels: visibleModels,
            hiddenModels: hiddenModels,
            apiKeys: apiKeys,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String displayName,
            required String apiBaseUrl,
            Value<bool> enabled = const Value.absent(),
            Value<String> capabilities = const Value.absent(),
            Value<String> customConfig = const Value.absent(),
            Value<String?> modelType = const Value.absent(),
            Value<String> visibleModels = const Value.absent(),
            Value<String> hiddenModels = const Value.absent(),
            Value<String> apiKeys = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              ProvidersCompanion.insert(
            id: id,
            displayName: displayName,
            apiBaseUrl: apiBaseUrl,
            enabled: enabled,
            capabilities: capabilities,
            customConfig: customConfig,
            modelType: modelType,
            visibleModels: visibleModels,
            hiddenModels: hiddenModels,
            apiKeys: apiKeys,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ProvidersTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $ProvidersTable,
    Provider,
    $$ProvidersTableFilterComposer,
    $$ProvidersTableOrderingComposer,
    $$ProvidersTableAnnotationComposer,
    $$ProvidersTableCreateCompanionBuilder,
    $$ProvidersTableUpdateCompanionBuilder,
    (Provider, BaseReferences<_$AppDatabase, $ProvidersTable, Provider>),
    Provider,
    PrefetchHooks Function()>;
typedef $$SyncScopesTableCreateCompanionBuilder = SyncScopesCompanion Function({
  Value<String> enabledScopes,
  required int updatedAt,
  Value<int> id,
});
typedef $$SyncScopesTableUpdateCompanionBuilder = SyncScopesCompanion Function({
  Value<String> enabledScopes,
  Value<int> updatedAt,
  Value<int> id,
});

class $$SyncScopesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncScopesTable> {
  $$SyncScopesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get enabledScopes => $composableBuilder(
      column: $table.enabledScopes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));
}

class $$SyncScopesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncScopesTable> {
  $$SyncScopesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get enabledScopes => $composableBuilder(
      column: $table.enabledScopes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));
}

class $$SyncScopesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncScopesTable> {
  $$SyncScopesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get enabledScopes => $composableBuilder(
      column: $table.enabledScopes, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);
}

class $$SyncScopesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SyncScopesTable,
    SyncScope,
    $$SyncScopesTableFilterComposer,
    $$SyncScopesTableOrderingComposer,
    $$SyncScopesTableAnnotationComposer,
    $$SyncScopesTableCreateCompanionBuilder,
    $$SyncScopesTableUpdateCompanionBuilder,
    (SyncScope, BaseReferences<_$AppDatabase, $SyncScopesTable, SyncScope>),
    SyncScope,
    PrefetchHooks Function()> {
  $$SyncScopesTableTableManager(_$AppDatabase db, $SyncScopesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncScopesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncScopesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncScopesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> enabledScopes = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> id = const Value.absent(),
          }) =>
              SyncScopesCompanion(
            enabledScopes: enabledScopes,
            updatedAt: updatedAt,
            id: id,
          ),
          createCompanionCallback: ({
            Value<String> enabledScopes = const Value.absent(),
            required int updatedAt,
            Value<int> id = const Value.absent(),
          }) =>
              SyncScopesCompanion.insert(
            enabledScopes: enabledScopes,
            updatedAt: updatedAt,
            id: id,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncScopesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SyncScopesTable,
    SyncScope,
    $$SyncScopesTableFilterComposer,
    $$SyncScopesTableOrderingComposer,
    $$SyncScopesTableAnnotationComposer,
    $$SyncScopesTableCreateCompanionBuilder,
    $$SyncScopesTableUpdateCompanionBuilder,
    (SyncScope, BaseReferences<_$AppDatabase, $SyncScopesTable, SyncScope>),
    SyncScope,
    PrefetchHooks Function()>;
typedef $$SyncCursorsTableCreateCompanionBuilder = SyncCursorsCompanion
    Function({
  required String deviceId,
  Value<int> conversationsCursor,
  Value<int> messagesCursor,
  Value<int> providersCursor,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$SyncCursorsTableUpdateCompanionBuilder = SyncCursorsCompanion
    Function({
  Value<String> deviceId,
  Value<int> conversationsCursor,
  Value<int> messagesCursor,
  Value<int> providersCursor,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$SyncCursorsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get conversationsCursor => $composableBuilder(
      column: $table.conversationsCursor,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get messagesCursor => $composableBuilder(
      column: $table.messagesCursor,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get providersCursor => $composableBuilder(
      column: $table.providersCursor,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$SyncCursorsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
      column: $table.deviceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get conversationsCursor => $composableBuilder(
      column: $table.conversationsCursor,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get messagesCursor => $composableBuilder(
      column: $table.messagesCursor,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get providersCursor => $composableBuilder(
      column: $table.providersCursor,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$SyncCursorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get conversationsCursor => $composableBuilder(
      column: $table.conversationsCursor, builder: (column) => column);

  GeneratedColumn<int> get messagesCursor => $composableBuilder(
      column: $table.messagesCursor, builder: (column) => column);

  GeneratedColumn<int> get providersCursor => $composableBuilder(
      column: $table.providersCursor, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$SyncCursorsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SyncCursorsTable,
    SyncCursor,
    $$SyncCursorsTableFilterComposer,
    $$SyncCursorsTableOrderingComposer,
    $$SyncCursorsTableAnnotationComposer,
    $$SyncCursorsTableCreateCompanionBuilder,
    $$SyncCursorsTableUpdateCompanionBuilder,
    (SyncCursor, BaseReferences<_$AppDatabase, $SyncCursorsTable, SyncCursor>),
    SyncCursor,
    PrefetchHooks Function()> {
  $$SyncCursorsTableTableManager(_$AppDatabase db, $SyncCursorsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncCursorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncCursorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncCursorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> deviceId = const Value.absent(),
            Value<int> conversationsCursor = const Value.absent(),
            Value<int> messagesCursor = const Value.absent(),
            Value<int> providersCursor = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncCursorsCompanion(
            deviceId: deviceId,
            conversationsCursor: conversationsCursor,
            messagesCursor: messagesCursor,
            providersCursor: providersCursor,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String deviceId,
            Value<int> conversationsCursor = const Value.absent(),
            Value<int> messagesCursor = const Value.absent(),
            Value<int> providersCursor = const Value.absent(),
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncCursorsCompanion.insert(
            deviceId: deviceId,
            conversationsCursor: conversationsCursor,
            messagesCursor: messagesCursor,
            providersCursor: providersCursor,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncCursorsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $SyncCursorsTable,
    SyncCursor,
    $$SyncCursorsTableFilterComposer,
    $$SyncCursorsTableOrderingComposer,
    $$SyncCursorsTableAnnotationComposer,
    $$SyncCursorsTableCreateCompanionBuilder,
    $$SyncCursorsTableUpdateCompanionBuilder,
    (SyncCursor, BaseReferences<_$AppDatabase, $SyncCursorsTable, SyncCursor>),
    SyncCursor,
    PrefetchHooks Function()>;
typedef $$PendingOperationsTableCreateCompanionBuilder
    = PendingOperationsCompanion Function({
  required String opId,
  required String opType,
  required String opData,
  required int createdAt,
  Value<bool> synced,
  Value<int> rowid,
});
typedef $$PendingOperationsTableUpdateCompanionBuilder
    = PendingOperationsCompanion Function({
  Value<String> opId,
  Value<String> opType,
  Value<String> opData,
  Value<int> createdAt,
  Value<bool> synced,
  Value<int> rowid,
});

class $$PendingOperationsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get opId => $composableBuilder(
      column: $table.opId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get opType => $composableBuilder(
      column: $table.opType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get opData => $composableBuilder(
      column: $table.opData, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get synced => $composableBuilder(
      column: $table.synced, builder: (column) => ColumnFilters(column));
}

class $$PendingOperationsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get opId => $composableBuilder(
      column: $table.opId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get opType => $composableBuilder(
      column: $table.opType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get opData => $composableBuilder(
      column: $table.opData, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get synced => $composableBuilder(
      column: $table.synced, builder: (column) => ColumnOrderings(column));
}

class $$PendingOperationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get opType =>
      $composableBuilder(column: $table.opType, builder: (column) => column);

  GeneratedColumn<String> get opData =>
      $composableBuilder(column: $table.opData, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);
}

class $$PendingOperationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PendingOperationsTable,
    PendingOperation,
    $$PendingOperationsTableFilterComposer,
    $$PendingOperationsTableOrderingComposer,
    $$PendingOperationsTableAnnotationComposer,
    $$PendingOperationsTableCreateCompanionBuilder,
    $$PendingOperationsTableUpdateCompanionBuilder,
    (
      PendingOperation,
      BaseReferences<_$AppDatabase, $PendingOperationsTable, PendingOperation>
    ),
    PendingOperation,
    PrefetchHooks Function()> {
  $$PendingOperationsTableTableManager(
      _$AppDatabase db, $PendingOperationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingOperationsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> opId = const Value.absent(),
            Value<String> opType = const Value.absent(),
            Value<String> opData = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<bool> synced = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PendingOperationsCompanion(
            opId: opId,
            opType: opType,
            opData: opData,
            createdAt: createdAt,
            synced: synced,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String opId,
            required String opType,
            required String opData,
            required int createdAt,
            Value<bool> synced = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PendingOperationsCompanion.insert(
            opId: opId,
            opType: opType,
            opData: opData,
            createdAt: createdAt,
            synced: synced,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PendingOperationsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $PendingOperationsTable,
    PendingOperation,
    $$PendingOperationsTableFilterComposer,
    $$PendingOperationsTableOrderingComposer,
    $$PendingOperationsTableAnnotationComposer,
    $$PendingOperationsTableCreateCompanionBuilder,
    $$PendingOperationsTableUpdateCompanionBuilder,
    (
      PendingOperation,
      BaseReferences<_$AppDatabase, $PendingOperationsTable, PendingOperation>
    ),
    PendingOperation,
    PrefetchHooks Function()>;
typedef $$MemoriesTableCreateCompanionBuilder = MemoriesCompanion Function({
  required String id,
  required String content,
  Value<String?> embedding,
  Value<double> persistenceP,
  Value<double> emotionE,
  Value<double> infoI,
  Value<double> judgeJ,
  Value<double> infoImportance,
  Value<double> timeCoef,
  Value<double> importance,
  Value<int> useCount,
  Value<int?> lastActiveAt,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<bool> isSynced,
  Value<String> syncState,
  required int createdAt,
  required int updatedAt,
  Value<int> rowid,
});
typedef $$MemoriesTableUpdateCompanionBuilder = MemoriesCompanion Function({
  Value<String> id,
  Value<String> content,
  Value<String?> embedding,
  Value<double> persistenceP,
  Value<double> emotionE,
  Value<double> infoI,
  Value<double> judgeJ,
  Value<double> infoImportance,
  Value<double> timeCoef,
  Value<double> importance,
  Value<int> useCount,
  Value<int?> lastActiveAt,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<bool> isSynced,
  Value<String> syncState,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$MemoriesTableFilterComposer
    extends Composer<_$AppDatabase, $MemoriesTable> {
  $$MemoriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get embedding => $composableBuilder(
      column: $table.embedding, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get persistenceP => $composableBuilder(
      column: $table.persistenceP, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get emotionE => $composableBuilder(
      column: $table.emotionE, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get infoI => $composableBuilder(
      column: $table.infoI, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get judgeJ => $composableBuilder(
      column: $table.judgeJ, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get infoImportance => $composableBuilder(
      column: $table.infoImportance,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get timeCoef => $composableBuilder(
      column: $table.timeCoef, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get importance => $composableBuilder(
      column: $table.importance, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get useCount => $composableBuilder(
      column: $table.useCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastActiveAt => $composableBuilder(
      column: $table.lastActiveAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isSynced => $composableBuilder(
      column: $table.isSynced, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncState => $composableBuilder(
      column: $table.syncState, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$MemoriesTableOrderingComposer
    extends Composer<_$AppDatabase, $MemoriesTable> {
  $$MemoriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get embedding => $composableBuilder(
      column: $table.embedding, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get persistenceP => $composableBuilder(
      column: $table.persistenceP,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get emotionE => $composableBuilder(
      column: $table.emotionE, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get infoI => $composableBuilder(
      column: $table.infoI, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get judgeJ => $composableBuilder(
      column: $table.judgeJ, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get infoImportance => $composableBuilder(
      column: $table.infoImportance,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get timeCoef => $composableBuilder(
      column: $table.timeCoef, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get importance => $composableBuilder(
      column: $table.importance, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get useCount => $composableBuilder(
      column: $table.useCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastActiveAt => $composableBuilder(
      column: $table.lastActiveAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isSynced => $composableBuilder(
      column: $table.isSynced, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncState => $composableBuilder(
      column: $table.syncState, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$MemoriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MemoriesTable> {
  $$MemoriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get embedding =>
      $composableBuilder(column: $table.embedding, builder: (column) => column);

  GeneratedColumn<double> get persistenceP => $composableBuilder(
      column: $table.persistenceP, builder: (column) => column);

  GeneratedColumn<double> get emotionE =>
      $composableBuilder(column: $table.emotionE, builder: (column) => column);

  GeneratedColumn<double> get infoI =>
      $composableBuilder(column: $table.infoI, builder: (column) => column);

  GeneratedColumn<double> get judgeJ =>
      $composableBuilder(column: $table.judgeJ, builder: (column) => column);

  GeneratedColumn<double> get infoImportance => $composableBuilder(
      column: $table.infoImportance, builder: (column) => column);

  GeneratedColumn<double> get timeCoef =>
      $composableBuilder(column: $table.timeCoef, builder: (column) => column);

  GeneratedColumn<double> get importance => $composableBuilder(
      column: $table.importance, builder: (column) => column);

  GeneratedColumn<int> get useCount =>
      $composableBuilder(column: $table.useCount, builder: (column) => column);

  GeneratedColumn<int> get lastActiveAt => $composableBuilder(
      column: $table.lastActiveAt, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get purgeAt =>
      $composableBuilder(column: $table.purgeAt, builder: (column) => column);

  GeneratedColumn<bool> get isSynced =>
      $composableBuilder(column: $table.isSynced, builder: (column) => column);

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$MemoriesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MemoriesTable,
    Memory,
    $$MemoriesTableFilterComposer,
    $$MemoriesTableOrderingComposer,
    $$MemoriesTableAnnotationComposer,
    $$MemoriesTableCreateCompanionBuilder,
    $$MemoriesTableUpdateCompanionBuilder,
    (Memory, BaseReferences<_$AppDatabase, $MemoriesTable, Memory>),
    Memory,
    PrefetchHooks Function()> {
  $$MemoriesTableTableManager(_$AppDatabase db, $MemoriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MemoriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MemoriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MemoriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<String?> embedding = const Value.absent(),
            Value<double> persistenceP = const Value.absent(),
            Value<double> emotionE = const Value.absent(),
            Value<double> infoI = const Value.absent(),
            Value<double> judgeJ = const Value.absent(),
            Value<double> infoImportance = const Value.absent(),
            Value<double> timeCoef = const Value.absent(),
            Value<double> importance = const Value.absent(),
            Value<int> useCount = const Value.absent(),
            Value<int?> lastActiveAt = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            Value<bool> isSynced = const Value.absent(),
            Value<String> syncState = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MemoriesCompanion(
            id: id,
            content: content,
            embedding: embedding,
            persistenceP: persistenceP,
            emotionE: emotionE,
            infoI: infoI,
            judgeJ: judgeJ,
            infoImportance: infoImportance,
            timeCoef: timeCoef,
            importance: importance,
            useCount: useCount,
            lastActiveAt: lastActiveAt,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            isSynced: isSynced,
            syncState: syncState,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String content,
            Value<String?> embedding = const Value.absent(),
            Value<double> persistenceP = const Value.absent(),
            Value<double> emotionE = const Value.absent(),
            Value<double> infoI = const Value.absent(),
            Value<double> judgeJ = const Value.absent(),
            Value<double> infoImportance = const Value.absent(),
            Value<double> timeCoef = const Value.absent(),
            Value<double> importance = const Value.absent(),
            Value<int> useCount = const Value.absent(),
            Value<int?> lastActiveAt = const Value.absent(),
            Value<int?> deletedAt = const Value.absent(),
            Value<int?> purgeAt = const Value.absent(),
            Value<bool> isSynced = const Value.absent(),
            Value<String> syncState = const Value.absent(),
            required int createdAt,
            required int updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MemoriesCompanion.insert(
            id: id,
            content: content,
            embedding: embedding,
            persistenceP: persistenceP,
            emotionE: emotionE,
            infoI: infoI,
            judgeJ: judgeJ,
            infoImportance: infoImportance,
            timeCoef: timeCoef,
            importance: importance,
            useCount: useCount,
            lastActiveAt: lastActiveAt,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            isSynced: isSynced,
            syncState: syncState,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MemoriesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MemoriesTable,
    Memory,
    $$MemoriesTableFilterComposer,
    $$MemoriesTableOrderingComposer,
    $$MemoriesTableAnnotationComposer,
    $$MemoriesTableCreateCompanionBuilder,
    $$MemoriesTableUpdateCompanionBuilder,
    (Memory, BaseReferences<_$AppDatabase, $MemoriesTable, Memory>),
    Memory,
    PrefetchHooks Function()>;
typedef $$MemoryTombstonesTableCreateCompanionBuilder
    = MemoryTombstonesCompanion Function({
  required String tombstoneId,
  required String memoryId,
  required String reason,
  Value<String?> payloadHash,
  required int deletedAt,
  required int purgeAt,
  Value<int?> cloudSyncedAt,
  Value<int> rowid,
});
typedef $$MemoryTombstonesTableUpdateCompanionBuilder
    = MemoryTombstonesCompanion Function({
  Value<String> tombstoneId,
  Value<String> memoryId,
  Value<String> reason,
  Value<String?> payloadHash,
  Value<int> deletedAt,
  Value<int> purgeAt,
  Value<int?> cloudSyncedAt,
  Value<int> rowid,
});

class $$MemoryTombstonesTableFilterComposer
    extends Composer<_$AppDatabase, $MemoryTombstonesTable> {
  $$MemoryTombstonesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tombstoneId => $composableBuilder(
      column: $table.tombstoneId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get memoryId => $composableBuilder(
      column: $table.memoryId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadHash => $composableBuilder(
      column: $table.payloadHash, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get cloudSyncedAt => $composableBuilder(
      column: $table.cloudSyncedAt, builder: (column) => ColumnFilters(column));
}

class $$MemoryTombstonesTableOrderingComposer
    extends Composer<_$AppDatabase, $MemoryTombstonesTable> {
  $$MemoryTombstonesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tombstoneId => $composableBuilder(
      column: $table.tombstoneId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get memoryId => $composableBuilder(
      column: $table.memoryId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get reason => $composableBuilder(
      column: $table.reason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadHash => $composableBuilder(
      column: $table.payloadHash, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get purgeAt => $composableBuilder(
      column: $table.purgeAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get cloudSyncedAt => $composableBuilder(
      column: $table.cloudSyncedAt,
      builder: (column) => ColumnOrderings(column));
}

class $$MemoryTombstonesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MemoryTombstonesTable> {
  $$MemoryTombstonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tombstoneId => $composableBuilder(
      column: $table.tombstoneId, builder: (column) => column);

  GeneratedColumn<String> get memoryId =>
      $composableBuilder(column: $table.memoryId, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get payloadHash => $composableBuilder(
      column: $table.payloadHash, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<int> get purgeAt =>
      $composableBuilder(column: $table.purgeAt, builder: (column) => column);

  GeneratedColumn<int> get cloudSyncedAt => $composableBuilder(
      column: $table.cloudSyncedAt, builder: (column) => column);
}

class $$MemoryTombstonesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MemoryTombstonesTable,
    MemoryTombstone,
    $$MemoryTombstonesTableFilterComposer,
    $$MemoryTombstonesTableOrderingComposer,
    $$MemoryTombstonesTableAnnotationComposer,
    $$MemoryTombstonesTableCreateCompanionBuilder,
    $$MemoryTombstonesTableUpdateCompanionBuilder,
    (
      MemoryTombstone,
      BaseReferences<_$AppDatabase, $MemoryTombstonesTable, MemoryTombstone>
    ),
    MemoryTombstone,
    PrefetchHooks Function()> {
  $$MemoryTombstonesTableTableManager(
      _$AppDatabase db, $MemoryTombstonesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MemoryTombstonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MemoryTombstonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MemoryTombstonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> tombstoneId = const Value.absent(),
            Value<String> memoryId = const Value.absent(),
            Value<String> reason = const Value.absent(),
            Value<String?> payloadHash = const Value.absent(),
            Value<int> deletedAt = const Value.absent(),
            Value<int> purgeAt = const Value.absent(),
            Value<int?> cloudSyncedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MemoryTombstonesCompanion(
            tombstoneId: tombstoneId,
            memoryId: memoryId,
            reason: reason,
            payloadHash: payloadHash,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            cloudSyncedAt: cloudSyncedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String tombstoneId,
            required String memoryId,
            required String reason,
            Value<String?> payloadHash = const Value.absent(),
            required int deletedAt,
            required int purgeAt,
            Value<int?> cloudSyncedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MemoryTombstonesCompanion.insert(
            tombstoneId: tombstoneId,
            memoryId: memoryId,
            reason: reason,
            payloadHash: payloadHash,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            cloudSyncedAt: cloudSyncedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MemoryTombstonesTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MemoryTombstonesTable,
    MemoryTombstone,
    $$MemoryTombstonesTableFilterComposer,
    $$MemoryTombstonesTableOrderingComposer,
    $$MemoryTombstonesTableAnnotationComposer,
    $$MemoryTombstonesTableCreateCompanionBuilder,
    $$MemoryTombstonesTableUpdateCompanionBuilder,
    (
      MemoryTombstone,
      BaseReferences<_$AppDatabase, $MemoryTombstonesTable, MemoryTombstone>
    ),
    MemoryTombstone,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$MessageBlocksTableTableManager get messageBlocks =>
      $$MessageBlocksTableTableManager(_db, _db.messageBlocks);
  $$ProvidersTableTableManager get providers =>
      $$ProvidersTableTableManager(_db, _db.providers);
  $$SyncScopesTableTableManager get syncScopes =>
      $$SyncScopesTableTableManager(_db, _db.syncScopes);
  $$SyncCursorsTableTableManager get syncCursors =>
      $$SyncCursorsTableTableManager(_db, _db.syncCursors);
  $$PendingOperationsTableTableManager get pendingOperations =>
      $$PendingOperationsTableTableManager(_db, _db.pendingOperations);
  $$MemoriesTableTableManager get memories =>
      $$MemoriesTableTableManager(_db, _db.memories);
  $$MemoryTombstonesTableTableManager get memoryTombstones =>
      $$MemoryTombstonesTableTableManager(_db, _db.memoryTombstones);
}
