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
  static const VerificationMeta _chatBackgroundImageMeta =
      const VerificationMeta('chatBackgroundImage');
  @override
  late final GeneratedColumn<String> chatBackgroundImage =
      GeneratedColumn<String>('chat_background_image', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _chatBackgroundMaskOpacityMeta =
      const VerificationMeta('chatBackgroundMaskOpacity');
  @override
  late final GeneratedColumn<double> chatBackgroundMaskOpacity =
      GeneratedColumn<double>('chat_background_mask_opacity', aliasedName, true,
          type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _chatBackgroundBlurSigmaMeta =
      const VerificationMeta('chatBackgroundBlurSigma');
  @override
  late final GeneratedColumn<double> chatBackgroundBlurSigma =
      GeneratedColumn<double>('chat_background_blur_sigma', aliasedName, true,
          type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _blurredBackgroundMeta =
      const VerificationMeta('blurredBackground');
  @override
  late final GeneratedColumn<String> blurredBackground =
      GeneratedColumn<String>('blurred_background', aliasedName, true,
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
  static const VerificationMeta _enabledPluginsMeta =
      const VerificationMeta('enabledPlugins');
  @override
  late final GeneratedColumn<String> enabledPlugins = GeneratedColumn<String>(
      'enabled_plugins', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _recipeIdMeta =
      const VerificationMeta('recipeId');
  @override
  late final GeneratedColumn<String> recipeId = GeneratedColumn<String>(
      'recipe_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _thinkingLevelsMeta =
      const VerificationMeta('thinkingLevels');
  @override
  late final GeneratedColumn<String> thinkingLevels = GeneratedColumn<String>(
      'thinking_levels', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
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
  static const VerificationMeta _contextStartMessageIdMeta =
      const VerificationMeta('contextStartMessageId');
  @override
  late final GeneratedColumn<String> contextStartMessageId =
      GeneratedColumn<String>('context_start_message_id', aliasedName, true,
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
        chatBackgroundImage,
        chatBackgroundMaskOpacity,
        chatBackgroundBlurSigma,
        blurredBackground,
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
        enabledPlugins,
        recipeId,
        thinkingLevels,
        lastMessage,
        lastMessageTime,
        unreadCount,
        parentConversationId,
        forkFromMessageId,
        conflictOf,
        contextStartMessageId,
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
    if (data.containsKey('chat_background_image')) {
      context.handle(
          _chatBackgroundImageMeta,
          chatBackgroundImage.isAcceptableOrUnknown(
              data['chat_background_image']!, _chatBackgroundImageMeta));
    }
    if (data.containsKey('chat_background_mask_opacity')) {
      context.handle(
          _chatBackgroundMaskOpacityMeta,
          chatBackgroundMaskOpacity.isAcceptableOrUnknown(
              data['chat_background_mask_opacity']!,
              _chatBackgroundMaskOpacityMeta));
    }
    if (data.containsKey('chat_background_blur_sigma')) {
      context.handle(
          _chatBackgroundBlurSigmaMeta,
          chatBackgroundBlurSigma.isAcceptableOrUnknown(
              data['chat_background_blur_sigma']!,
              _chatBackgroundBlurSigmaMeta));
    }
    if (data.containsKey('blurred_background')) {
      context.handle(
          _blurredBackgroundMeta,
          blurredBackground.isAcceptableOrUnknown(
              data['blurred_background']!, _blurredBackgroundMeta));
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
    if (data.containsKey('enabled_plugins')) {
      context.handle(
          _enabledPluginsMeta,
          enabledPlugins.isAcceptableOrUnknown(
              data['enabled_plugins']!, _enabledPluginsMeta));
    }
    if (data.containsKey('recipe_id')) {
      context.handle(_recipeIdMeta,
          recipeId.isAcceptableOrUnknown(data['recipe_id']!, _recipeIdMeta));
    }
    if (data.containsKey('thinking_levels')) {
      context.handle(
          _thinkingLevelsMeta,
          thinkingLevels.isAcceptableOrUnknown(
              data['thinking_levels']!, _thinkingLevelsMeta));
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
    if (data.containsKey('context_start_message_id')) {
      context.handle(
          _contextStartMessageIdMeta,
          contextStartMessageId.isAcceptableOrUnknown(
              data['context_start_message_id']!, _contextStartMessageIdMeta));
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
      chatBackgroundImage: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}chat_background_image']),
      chatBackgroundMaskOpacity: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}chat_background_mask_opacity']),
      chatBackgroundBlurSigma: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}chat_background_blur_sigma']),
      blurredBackground: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}blurred_background']),
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
      enabledPlugins: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}enabled_plugins']),
      recipeId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}recipe_id']),
      thinkingLevels: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thinking_levels']),
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
      contextStartMessageId: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}context_start_message_id']),
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
  final String? chatBackgroundImage;
  final double? chatBackgroundMaskOpacity;
  final double? chatBackgroundBlurSigma;
  final String? blurredBackground;
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
  final String? enabledPlugins;
  final String? recipeId;
  final String? thinkingLevels;
  final String? lastMessage;
  final int? lastMessageTime;
  final int unreadCount;
  final String? parentConversationId;
  final String? forkFromMessageId;
  final String? conflictOf;
  final String? contextStartMessageId;
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
      this.chatBackgroundImage,
      this.chatBackgroundMaskOpacity,
      this.chatBackgroundBlurSigma,
      this.blurredBackground,
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
      this.enabledPlugins,
      this.recipeId,
      this.thinkingLevels,
      this.lastMessage,
      this.lastMessageTime,
      required this.unreadCount,
      this.parentConversationId,
      this.forkFromMessageId,
      this.conflictOf,
      this.contextStartMessageId,
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
    if (!nullToAbsent || chatBackgroundImage != null) {
      map['chat_background_image'] = Variable<String>(chatBackgroundImage);
    }
    if (!nullToAbsent || chatBackgroundMaskOpacity != null) {
      map['chat_background_mask_opacity'] =
          Variable<double>(chatBackgroundMaskOpacity);
    }
    if (!nullToAbsent || chatBackgroundBlurSigma != null) {
      map['chat_background_blur_sigma'] =
          Variable<double>(chatBackgroundBlurSigma);
    }
    if (!nullToAbsent || blurredBackground != null) {
      map['blurred_background'] = Variable<String>(blurredBackground);
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
    if (!nullToAbsent || enabledPlugins != null) {
      map['enabled_plugins'] = Variable<String>(enabledPlugins);
    }
    if (!nullToAbsent || recipeId != null) {
      map['recipe_id'] = Variable<String>(recipeId);
    }
    if (!nullToAbsent || thinkingLevels != null) {
      map['thinking_levels'] = Variable<String>(thinkingLevels);
    }
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
    if (!nullToAbsent || contextStartMessageId != null) {
      map['context_start_message_id'] = Variable<String>(contextStartMessageId);
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
      chatBackgroundImage: chatBackgroundImage == null && nullToAbsent
          ? const Value.absent()
          : Value(chatBackgroundImage),
      chatBackgroundMaskOpacity:
          chatBackgroundMaskOpacity == null && nullToAbsent
              ? const Value.absent()
              : Value(chatBackgroundMaskOpacity),
      chatBackgroundBlurSigma: chatBackgroundBlurSigma == null && nullToAbsent
          ? const Value.absent()
          : Value(chatBackgroundBlurSigma),
      blurredBackground: blurredBackground == null && nullToAbsent
          ? const Value.absent()
          : Value(blurredBackground),
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
      enabledPlugins: enabledPlugins == null && nullToAbsent
          ? const Value.absent()
          : Value(enabledPlugins),
      recipeId: recipeId == null && nullToAbsent
          ? const Value.absent()
          : Value(recipeId),
      thinkingLevels: thinkingLevels == null && nullToAbsent
          ? const Value.absent()
          : Value(thinkingLevels),
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
      contextStartMessageId: contextStartMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(contextStartMessageId),
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
      chatBackgroundImage:
          serializer.fromJson<String?>(json['chatBackgroundImage']),
      chatBackgroundMaskOpacity:
          serializer.fromJson<double?>(json['chatBackgroundMaskOpacity']),
      chatBackgroundBlurSigma:
          serializer.fromJson<double?>(json['chatBackgroundBlurSigma']),
      blurredBackground:
          serializer.fromJson<String?>(json['blurredBackground']),
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
      enabledPlugins: serializer.fromJson<String?>(json['enabledPlugins']),
      recipeId: serializer.fromJson<String?>(json['recipeId']),
      thinkingLevels: serializer.fromJson<String?>(json['thinkingLevels']),
      lastMessage: serializer.fromJson<String?>(json['lastMessage']),
      lastMessageTime: serializer.fromJson<int?>(json['lastMessageTime']),
      unreadCount: serializer.fromJson<int>(json['unreadCount']),
      parentConversationId:
          serializer.fromJson<String?>(json['parentConversationId']),
      forkFromMessageId:
          serializer.fromJson<String?>(json['forkFromMessageId']),
      conflictOf: serializer.fromJson<String?>(json['conflictOf']),
      contextStartMessageId:
          serializer.fromJson<String?>(json['contextStartMessageId']),
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
      'chatBackgroundImage': serializer.toJson<String?>(chatBackgroundImage),
      'chatBackgroundMaskOpacity':
          serializer.toJson<double?>(chatBackgroundMaskOpacity),
      'chatBackgroundBlurSigma':
          serializer.toJson<double?>(chatBackgroundBlurSigma),
      'blurredBackground': serializer.toJson<String?>(blurredBackground),
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
      'enabledPlugins': serializer.toJson<String?>(enabledPlugins),
      'recipeId': serializer.toJson<String?>(recipeId),
      'thinkingLevels': serializer.toJson<String?>(thinkingLevels),
      'lastMessage': serializer.toJson<String?>(lastMessage),
      'lastMessageTime': serializer.toJson<int?>(lastMessageTime),
      'unreadCount': serializer.toJson<int>(unreadCount),
      'parentConversationId': serializer.toJson<String?>(parentConversationId),
      'forkFromMessageId': serializer.toJson<String?>(forkFromMessageId),
      'conflictOf': serializer.toJson<String?>(conflictOf),
      'contextStartMessageId':
          serializer.toJson<String?>(contextStartMessageId),
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
          Value<String?> chatBackgroundImage = const Value.absent(),
          Value<double?> chatBackgroundMaskOpacity = const Value.absent(),
          Value<double?> chatBackgroundBlurSigma = const Value.absent(),
          Value<String?> blurredBackground = const Value.absent(),
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
          Value<String?> enabledPlugins = const Value.absent(),
          Value<String?> recipeId = const Value.absent(),
          Value<String?> thinkingLevels = const Value.absent(),
          Value<String?> lastMessage = const Value.absent(),
          Value<int?> lastMessageTime = const Value.absent(),
          int? unreadCount,
          Value<String?> parentConversationId = const Value.absent(),
          Value<String?> forkFromMessageId = const Value.absent(),
          Value<String?> conflictOf = const Value.absent(),
          Value<String?> contextStartMessageId = const Value.absent(),
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
        chatBackgroundImage: chatBackgroundImage.present
            ? chatBackgroundImage.value
            : this.chatBackgroundImage,
        chatBackgroundMaskOpacity: chatBackgroundMaskOpacity.present
            ? chatBackgroundMaskOpacity.value
            : this.chatBackgroundMaskOpacity,
        chatBackgroundBlurSigma: chatBackgroundBlurSigma.present
            ? chatBackgroundBlurSigma.value
            : this.chatBackgroundBlurSigma,
        blurredBackground: blurredBackground.present
            ? blurredBackground.value
            : this.blurredBackground,
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
        enabledPlugins:
            enabledPlugins.present ? enabledPlugins.value : this.enabledPlugins,
        recipeId: recipeId.present ? recipeId.value : this.recipeId,
        thinkingLevels:
            thinkingLevels.present ? thinkingLevels.value : this.thinkingLevels,
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
        contextStartMessageId: contextStartMessageId.present
            ? contextStartMessageId.value
            : this.contextStartMessageId,
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
      chatBackgroundImage: data.chatBackgroundImage.present
          ? data.chatBackgroundImage.value
          : this.chatBackgroundImage,
      chatBackgroundMaskOpacity: data.chatBackgroundMaskOpacity.present
          ? data.chatBackgroundMaskOpacity.value
          : this.chatBackgroundMaskOpacity,
      chatBackgroundBlurSigma: data.chatBackgroundBlurSigma.present
          ? data.chatBackgroundBlurSigma.value
          : this.chatBackgroundBlurSigma,
      blurredBackground: data.blurredBackground.present
          ? data.blurredBackground.value
          : this.blurredBackground,
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
      enabledPlugins: data.enabledPlugins.present
          ? data.enabledPlugins.value
          : this.enabledPlugins,
      recipeId: data.recipeId.present ? data.recipeId.value : this.recipeId,
      thinkingLevels: data.thinkingLevels.present
          ? data.thinkingLevels.value
          : this.thinkingLevels,
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
      contextStartMessageId: data.contextStartMessageId.present
          ? data.contextStartMessageId.value
          : this.contextStartMessageId,
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
          ..write('chatBackgroundImage: $chatBackgroundImage, ')
          ..write('chatBackgroundMaskOpacity: $chatBackgroundMaskOpacity, ')
          ..write('chatBackgroundBlurSigma: $chatBackgroundBlurSigma, ')
          ..write('blurredBackground: $blurredBackground, ')
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
          ..write('enabledPlugins: $enabledPlugins, ')
          ..write('recipeId: $recipeId, ')
          ..write('thinkingLevels: $thinkingLevels, ')
          ..write('lastMessage: $lastMessage, ')
          ..write('lastMessageTime: $lastMessageTime, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('parentConversationId: $parentConversationId, ')
          ..write('forkFromMessageId: $forkFromMessageId, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('contextStartMessageId: $contextStartMessageId, ')
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
        chatBackgroundImage,
        chatBackgroundMaskOpacity,
        chatBackgroundBlurSigma,
        blurredBackground,
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
        enabledPlugins,
        recipeId,
        thinkingLevels,
        lastMessage,
        lastMessageTime,
        unreadCount,
        parentConversationId,
        forkFromMessageId,
        conflictOf,
        contextStartMessageId,
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
          other.chatBackgroundImage == this.chatBackgroundImage &&
          other.chatBackgroundMaskOpacity == this.chatBackgroundMaskOpacity &&
          other.chatBackgroundBlurSigma == this.chatBackgroundBlurSigma &&
          other.blurredBackground == this.blurredBackground &&
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
          other.enabledPlugins == this.enabledPlugins &&
          other.recipeId == this.recipeId &&
          other.thinkingLevels == this.thinkingLevels &&
          other.lastMessage == this.lastMessage &&
          other.lastMessageTime == this.lastMessageTime &&
          other.unreadCount == this.unreadCount &&
          other.parentConversationId == this.parentConversationId &&
          other.forkFromMessageId == this.forkFromMessageId &&
          other.conflictOf == this.conflictOf &&
          other.contextStartMessageId == this.contextStartMessageId &&
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
  final Value<String?> chatBackgroundImage;
  final Value<double?> chatBackgroundMaskOpacity;
  final Value<double?> chatBackgroundBlurSigma;
  final Value<String?> blurredBackground;
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
  final Value<String?> enabledPlugins;
  final Value<String?> recipeId;
  final Value<String?> thinkingLevels;
  final Value<String?> lastMessage;
  final Value<int?> lastMessageTime;
  final Value<int> unreadCount;
  final Value<String?> parentConversationId;
  final Value<String?> forkFromMessageId;
  final Value<String?> conflictOf;
  final Value<String?> contextStartMessageId;
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
    this.chatBackgroundImage = const Value.absent(),
    this.chatBackgroundMaskOpacity = const Value.absent(),
    this.chatBackgroundBlurSigma = const Value.absent(),
    this.blurredBackground = const Value.absent(),
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
    this.enabledPlugins = const Value.absent(),
    this.recipeId = const Value.absent(),
    this.thinkingLevels = const Value.absent(),
    this.lastMessage = const Value.absent(),
    this.lastMessageTime = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.parentConversationId = const Value.absent(),
    this.forkFromMessageId = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.contextStartMessageId = const Value.absent(),
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
    this.chatBackgroundImage = const Value.absent(),
    this.chatBackgroundMaskOpacity = const Value.absent(),
    this.chatBackgroundBlurSigma = const Value.absent(),
    this.blurredBackground = const Value.absent(),
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
    this.enabledPlugins = const Value.absent(),
    this.recipeId = const Value.absent(),
    this.thinkingLevels = const Value.absent(),
    this.lastMessage = const Value.absent(),
    this.lastMessageTime = const Value.absent(),
    this.unreadCount = const Value.absent(),
    this.parentConversationId = const Value.absent(),
    this.forkFromMessageId = const Value.absent(),
    this.conflictOf = const Value.absent(),
    this.contextStartMessageId = const Value.absent(),
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
    Expression<String>? chatBackgroundImage,
    Expression<double>? chatBackgroundMaskOpacity,
    Expression<double>? chatBackgroundBlurSigma,
    Expression<String>? blurredBackground,
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
    Expression<String>? enabledPlugins,
    Expression<String>? recipeId,
    Expression<String>? thinkingLevels,
    Expression<String>? lastMessage,
    Expression<int>? lastMessageTime,
    Expression<int>? unreadCount,
    Expression<String>? parentConversationId,
    Expression<String>? forkFromMessageId,
    Expression<String>? conflictOf,
    Expression<String>? contextStartMessageId,
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
      if (chatBackgroundImage != null)
        'chat_background_image': chatBackgroundImage,
      if (chatBackgroundMaskOpacity != null)
        'chat_background_mask_opacity': chatBackgroundMaskOpacity,
      if (chatBackgroundBlurSigma != null)
        'chat_background_blur_sigma': chatBackgroundBlurSigma,
      if (blurredBackground != null) 'blurred_background': blurredBackground,
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
      if (enabledPlugins != null) 'enabled_plugins': enabledPlugins,
      if (recipeId != null) 'recipe_id': recipeId,
      if (thinkingLevels != null) 'thinking_levels': thinkingLevels,
      if (lastMessage != null) 'last_message': lastMessage,
      if (lastMessageTime != null) 'last_message_time': lastMessageTime,
      if (unreadCount != null) 'unread_count': unreadCount,
      if (parentConversationId != null)
        'parent_conversation_id': parentConversationId,
      if (forkFromMessageId != null) 'fork_from_message_id': forkFromMessageId,
      if (conflictOf != null) 'conflict_of': conflictOf,
      if (contextStartMessageId != null)
        'context_start_message_id': contextStartMessageId,
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
      Value<String?>? chatBackgroundImage,
      Value<double?>? chatBackgroundMaskOpacity,
      Value<double?>? chatBackgroundBlurSigma,
      Value<String?>? blurredBackground,
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
      Value<String?>? enabledPlugins,
      Value<String?>? recipeId,
      Value<String?>? thinkingLevels,
      Value<String?>? lastMessage,
      Value<int?>? lastMessageTime,
      Value<int>? unreadCount,
      Value<String?>? parentConversationId,
      Value<String?>? forkFromMessageId,
      Value<String?>? conflictOf,
      Value<String?>? contextStartMessageId,
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
      chatBackgroundImage: chatBackgroundImage ?? this.chatBackgroundImage,
      chatBackgroundMaskOpacity:
          chatBackgroundMaskOpacity ?? this.chatBackgroundMaskOpacity,
      chatBackgroundBlurSigma:
          chatBackgroundBlurSigma ?? this.chatBackgroundBlurSigma,
      blurredBackground: blurredBackground ?? this.blurredBackground,
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
      enabledPlugins: enabledPlugins ?? this.enabledPlugins,
      recipeId: recipeId ?? this.recipeId,
      thinkingLevels: thinkingLevels ?? this.thinkingLevels,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      parentConversationId: parentConversationId ?? this.parentConversationId,
      forkFromMessageId: forkFromMessageId ?? this.forkFromMessageId,
      conflictOf: conflictOf ?? this.conflictOf,
      contextStartMessageId:
          contextStartMessageId ?? this.contextStartMessageId,
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
    if (chatBackgroundImage.present) {
      map['chat_background_image'] =
          Variable<String>(chatBackgroundImage.value);
    }
    if (chatBackgroundMaskOpacity.present) {
      map['chat_background_mask_opacity'] =
          Variable<double>(chatBackgroundMaskOpacity.value);
    }
    if (chatBackgroundBlurSigma.present) {
      map['chat_background_blur_sigma'] =
          Variable<double>(chatBackgroundBlurSigma.value);
    }
    if (blurredBackground.present) {
      map['blurred_background'] = Variable<String>(blurredBackground.value);
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
    if (enabledPlugins.present) {
      map['enabled_plugins'] = Variable<String>(enabledPlugins.value);
    }
    if (recipeId.present) {
      map['recipe_id'] = Variable<String>(recipeId.value);
    }
    if (thinkingLevels.present) {
      map['thinking_levels'] = Variable<String>(thinkingLevels.value);
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
    if (contextStartMessageId.present) {
      map['context_start_message_id'] =
          Variable<String>(contextStartMessageId.value);
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
          ..write('chatBackgroundImage: $chatBackgroundImage, ')
          ..write('chatBackgroundMaskOpacity: $chatBackgroundMaskOpacity, ')
          ..write('chatBackgroundBlurSigma: $chatBackgroundBlurSigma, ')
          ..write('blurredBackground: $blurredBackground, ')
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
          ..write('enabledPlugins: $enabledPlugins, ')
          ..write('recipeId: $recipeId, ')
          ..write('thinkingLevels: $thinkingLevels, ')
          ..write('lastMessage: $lastMessage, ')
          ..write('lastMessageTime: $lastMessageTime, ')
          ..write('unreadCount: $unreadCount, ')
          ..write('parentConversationId: $parentConversationId, ')
          ..write('forkFromMessageId: $forkFromMessageId, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('contextStartMessageId: $contextStartMessageId, ')
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
  static const VerificationMeta _summarizedMeta =
      const VerificationMeta('summarized');
  @override
  late final GeneratedColumn<bool> summarized = GeneratedColumn<bool>(
      'summarized', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("summarized" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _summarizedAtMeta =
      const VerificationMeta('summarizedAt');
  @override
  late final GeneratedColumn<int> summarizedAt = GeneratedColumn<int>(
      'summarized_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _replacedByMeta =
      const VerificationMeta('replacedBy');
  @override
  late final GeneratedColumn<String> replacedBy = GeneratedColumn<String>(
      'replaced_by', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sourceMessageIdMeta =
      const VerificationMeta('sourceMessageId');
  @override
  late final GeneratedColumn<String> sourceMessageId = GeneratedColumn<String>(
      'source_message_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _rawPayloadMeta =
      const VerificationMeta('rawPayload');
  @override
  late final GeneratedColumn<String> rawPayload = GeneratedColumn<String>(
      'raw_payload', aliasedName, true,
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
        summarized,
        summarizedAt,
        replacedBy,
        sourceMessageId,
        rawPayload,
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
    if (data.containsKey('summarized')) {
      context.handle(
          _summarizedMeta,
          summarized.isAcceptableOrUnknown(
              data['summarized']!, _summarizedMeta));
    }
    if (data.containsKey('summarized_at')) {
      context.handle(
          _summarizedAtMeta,
          summarizedAt.isAcceptableOrUnknown(
              data['summarized_at']!, _summarizedAtMeta));
    }
    if (data.containsKey('replaced_by')) {
      context.handle(
          _replacedByMeta,
          replacedBy.isAcceptableOrUnknown(
              data['replaced_by']!, _replacedByMeta));
    }
    if (data.containsKey('source_message_id')) {
      context.handle(
          _sourceMessageIdMeta,
          sourceMessageId.isAcceptableOrUnknown(
              data['source_message_id']!, _sourceMessageIdMeta));
    }
    if (data.containsKey('raw_payload')) {
      context.handle(
          _rawPayloadMeta,
          rawPayload.isAcceptableOrUnknown(
              data['raw_payload']!, _rawPayloadMeta));
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
      summarized: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}summarized'])!,
      summarizedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}summarized_at']),
      replacedBy: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}replaced_by']),
      sourceMessageId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}source_message_id']),
      rawPayload: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw_payload']),
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
  final bool summarized;
  final int? summarizedAt;
  final String? replacedBy;
  final String? sourceMessageId;
  final String? rawPayload;
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
      required this.summarized,
      this.summarizedAt,
      this.replacedBy,
      this.sourceMessageId,
      this.rawPayload,
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
    map['summarized'] = Variable<bool>(summarized);
    if (!nullToAbsent || summarizedAt != null) {
      map['summarized_at'] = Variable<int>(summarizedAt);
    }
    if (!nullToAbsent || replacedBy != null) {
      map['replaced_by'] = Variable<String>(replacedBy);
    }
    if (!nullToAbsent || sourceMessageId != null) {
      map['source_message_id'] = Variable<String>(sourceMessageId);
    }
    if (!nullToAbsent || rawPayload != null) {
      map['raw_payload'] = Variable<String>(rawPayload);
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
      summarized: Value(summarized),
      summarizedAt: summarizedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(summarizedAt),
      replacedBy: replacedBy == null && nullToAbsent
          ? const Value.absent()
          : Value(replacedBy),
      sourceMessageId: sourceMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceMessageId),
      rawPayload: rawPayload == null && nullToAbsent
          ? const Value.absent()
          : Value(rawPayload),
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
      summarized: serializer.fromJson<bool>(json['summarized']),
      summarizedAt: serializer.fromJson<int?>(json['summarizedAt']),
      replacedBy: serializer.fromJson<String?>(json['replacedBy']),
      sourceMessageId: serializer.fromJson<String?>(json['sourceMessageId']),
      rawPayload: serializer.fromJson<String?>(json['rawPayload']),
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
      'summarized': serializer.toJson<bool>(summarized),
      'summarizedAt': serializer.toJson<int?>(summarizedAt),
      'replacedBy': serializer.toJson<String?>(replacedBy),
      'sourceMessageId': serializer.toJson<String?>(sourceMessageId),
      'rawPayload': serializer.toJson<String?>(rawPayload),
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
          bool? summarized,
          Value<int?> summarizedAt = const Value.absent(),
          Value<String?> replacedBy = const Value.absent(),
          Value<String?> sourceMessageId = const Value.absent(),
          Value<String?> rawPayload = const Value.absent(),
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
        summarized: summarized ?? this.summarized,
        summarizedAt:
            summarizedAt.present ? summarizedAt.value : this.summarizedAt,
        replacedBy: replacedBy.present ? replacedBy.value : this.replacedBy,
        sourceMessageId: sourceMessageId.present
            ? sourceMessageId.value
            : this.sourceMessageId,
        rawPayload: rawPayload.present ? rawPayload.value : this.rawPayload,
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
      summarized:
          data.summarized.present ? data.summarized.value : this.summarized,
      summarizedAt: data.summarizedAt.present
          ? data.summarizedAt.value
          : this.summarizedAt,
      replacedBy:
          data.replacedBy.present ? data.replacedBy.value : this.replacedBy,
      sourceMessageId: data.sourceMessageId.present
          ? data.sourceMessageId.value
          : this.sourceMessageId,
      rawPayload:
          data.rawPayload.present ? data.rawPayload.value : this.rawPayload,
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
          ..write('summarized: $summarized, ')
          ..write('summarizedAt: $summarizedAt, ')
          ..write('replacedBy: $replacedBy, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('rawPayload: $rawPayload, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      conversationId,
      role,
      content,
      status,
      summarized,
      summarizedAt,
      replacedBy,
      sourceMessageId,
      rawPayload,
      conflictOf,
      deletedAt,
      purgeAt,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.role == this.role &&
          other.content == this.content &&
          other.status == this.status &&
          other.summarized == this.summarized &&
          other.summarizedAt == this.summarizedAt &&
          other.replacedBy == this.replacedBy &&
          other.sourceMessageId == this.sourceMessageId &&
          other.rawPayload == this.rawPayload &&
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
  final Value<bool> summarized;
  final Value<int?> summarizedAt;
  final Value<String?> replacedBy;
  final Value<String?> sourceMessageId;
  final Value<String?> rawPayload;
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
    this.summarized = const Value.absent(),
    this.summarizedAt = const Value.absent(),
    this.replacedBy = const Value.absent(),
    this.sourceMessageId = const Value.absent(),
    this.rawPayload = const Value.absent(),
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
    this.summarized = const Value.absent(),
    this.summarizedAt = const Value.absent(),
    this.replacedBy = const Value.absent(),
    this.sourceMessageId = const Value.absent(),
    this.rawPayload = const Value.absent(),
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
    Expression<bool>? summarized,
    Expression<int>? summarizedAt,
    Expression<String>? replacedBy,
    Expression<String>? sourceMessageId,
    Expression<String>? rawPayload,
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
      if (summarized != null) 'summarized': summarized,
      if (summarizedAt != null) 'summarized_at': summarizedAt,
      if (replacedBy != null) 'replaced_by': replacedBy,
      if (sourceMessageId != null) 'source_message_id': sourceMessageId,
      if (rawPayload != null) 'raw_payload': rawPayload,
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
      Value<bool>? summarized,
      Value<int?>? summarizedAt,
      Value<String?>? replacedBy,
      Value<String?>? sourceMessageId,
      Value<String?>? rawPayload,
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
      summarized: summarized ?? this.summarized,
      summarizedAt: summarizedAt ?? this.summarizedAt,
      replacedBy: replacedBy ?? this.replacedBy,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      rawPayload: rawPayload ?? this.rawPayload,
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
    if (summarized.present) {
      map['summarized'] = Variable<bool>(summarized.value);
    }
    if (summarizedAt.present) {
      map['summarized_at'] = Variable<int>(summarizedAt.value);
    }
    if (replacedBy.present) {
      map['replaced_by'] = Variable<String>(replacedBy.value);
    }
    if (sourceMessageId.present) {
      map['source_message_id'] = Variable<String>(sourceMessageId.value);
    }
    if (rawPayload.present) {
      map['raw_payload'] = Variable<String>(rawPayload.value);
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
          ..write('summarized: $summarized, ')
          ..write('summarizedAt: $summarizedAt, ')
          ..write('replacedBy: $replacedBy, ')
          ..write('sourceMessageId: $sourceMessageId, ')
          ..write('rawPayload: $rawPayload, ')
          ..write('conflictOf: $conflictOf, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('purgeAt: $purgeAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessageProjectionMappingsTable extends MessageProjectionMappings
    with TableInfo<$MessageProjectionMappingsTable, MessageProjectionMapping> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessageProjectionMappingsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _rawMessageIdMeta =
      const VerificationMeta('rawMessageId');
  @override
  late final GeneratedColumn<String> rawMessageId = GeneratedColumn<String>(
      'raw_message_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES messages (id)'));
  static const VerificationMeta _projectedMessageIdMeta =
      const VerificationMeta('projectedMessageId');
  @override
  late final GeneratedColumn<String> projectedMessageId =
      GeneratedColumn<String>('projected_message_id', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _projectionKindMeta =
      const VerificationMeta('projectionKind');
  @override
  late final GeneratedColumn<String> projectionKind = GeneratedColumn<String>(
      'projection_kind', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('message'));
  static const VerificationMeta _segmentIndexMeta =
      const VerificationMeta('segmentIndex');
  @override
  late final GeneratedColumn<int> segmentIndex = GeneratedColumn<int>(
      'segment_index', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _projectionVersionMeta =
      const VerificationMeta('projectionVersion');
  @override
  late final GeneratedColumn<String> projectionVersion =
      GeneratedColumn<String>('projection_version', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
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
        rawMessageId,
        projectedMessageId,
        projectionKind,
        segmentIndex,
        projectionVersion,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_projection_mappings';
  @override
  VerificationContext validateIntegrity(
      Insertable<MessageProjectionMapping> instance,
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
    if (data.containsKey('raw_message_id')) {
      context.handle(
          _rawMessageIdMeta,
          rawMessageId.isAcceptableOrUnknown(
              data['raw_message_id']!, _rawMessageIdMeta));
    } else if (isInserting) {
      context.missing(_rawMessageIdMeta);
    }
    if (data.containsKey('projected_message_id')) {
      context.handle(
          _projectedMessageIdMeta,
          projectedMessageId.isAcceptableOrUnknown(
              data['projected_message_id']!, _projectedMessageIdMeta));
    } else if (isInserting) {
      context.missing(_projectedMessageIdMeta);
    }
    if (data.containsKey('projection_kind')) {
      context.handle(
          _projectionKindMeta,
          projectionKind.isAcceptableOrUnknown(
              data['projection_kind']!, _projectionKindMeta));
    }
    if (data.containsKey('segment_index')) {
      context.handle(
          _segmentIndexMeta,
          segmentIndex.isAcceptableOrUnknown(
              data['segment_index']!, _segmentIndexMeta));
    }
    if (data.containsKey('projection_version')) {
      context.handle(
          _projectionVersionMeta,
          projectionVersion.isAcceptableOrUnknown(
              data['projection_version']!, _projectionVersionMeta));
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
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {rawMessageId, projectedMessageId},
      ];
  @override
  MessageProjectionMapping map(Map<String, dynamic> data,
      {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageProjectionMapping(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}conversation_id'])!,
      rawMessageId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}raw_message_id'])!,
      projectedMessageId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}projected_message_id'])!,
      projectionKind: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}projection_kind'])!,
      segmentIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}segment_index'])!,
      projectionVersion: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}projection_version']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessageProjectionMappingsTable createAlias(String alias) {
    return $MessageProjectionMappingsTable(attachedDatabase, alias);
  }
}

class MessageProjectionMapping extends DataClass
    implements Insertable<MessageProjectionMapping> {
  final String id;
  final String conversationId;
  final String rawMessageId;
  final String projectedMessageId;
  final String projectionKind;
  final int segmentIndex;
  final String? projectionVersion;
  final int createdAt;
  const MessageProjectionMapping(
      {required this.id,
      required this.conversationId,
      required this.rawMessageId,
      required this.projectedMessageId,
      required this.projectionKind,
      required this.segmentIndex,
      this.projectionVersion,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['raw_message_id'] = Variable<String>(rawMessageId);
    map['projected_message_id'] = Variable<String>(projectedMessageId);
    map['projection_kind'] = Variable<String>(projectionKind);
    map['segment_index'] = Variable<int>(segmentIndex);
    if (!nullToAbsent || projectionVersion != null) {
      map['projection_version'] = Variable<String>(projectionVersion);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MessageProjectionMappingsCompanion toCompanion(bool nullToAbsent) {
    return MessageProjectionMappingsCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      rawMessageId: Value(rawMessageId),
      projectedMessageId: Value(projectedMessageId),
      projectionKind: Value(projectionKind),
      segmentIndex: Value(segmentIndex),
      projectionVersion: projectionVersion == null && nullToAbsent
          ? const Value.absent()
          : Value(projectionVersion),
      createdAt: Value(createdAt),
    );
  }

  factory MessageProjectionMapping.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageProjectionMapping(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      rawMessageId: serializer.fromJson<String>(json['rawMessageId']),
      projectedMessageId:
          serializer.fromJson<String>(json['projectedMessageId']),
      projectionKind: serializer.fromJson<String>(json['projectionKind']),
      segmentIndex: serializer.fromJson<int>(json['segmentIndex']),
      projectionVersion:
          serializer.fromJson<String?>(json['projectionVersion']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'rawMessageId': serializer.toJson<String>(rawMessageId),
      'projectedMessageId': serializer.toJson<String>(projectedMessageId),
      'projectionKind': serializer.toJson<String>(projectionKind),
      'segmentIndex': serializer.toJson<int>(segmentIndex),
      'projectionVersion': serializer.toJson<String?>(projectionVersion),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  MessageProjectionMapping copyWith(
          {String? id,
          String? conversationId,
          String? rawMessageId,
          String? projectedMessageId,
          String? projectionKind,
          int? segmentIndex,
          Value<String?> projectionVersion = const Value.absent(),
          int? createdAt}) =>
      MessageProjectionMapping(
        id: id ?? this.id,
        conversationId: conversationId ?? this.conversationId,
        rawMessageId: rawMessageId ?? this.rawMessageId,
        projectedMessageId: projectedMessageId ?? this.projectedMessageId,
        projectionKind: projectionKind ?? this.projectionKind,
        segmentIndex: segmentIndex ?? this.segmentIndex,
        projectionVersion: projectionVersion.present
            ? projectionVersion.value
            : this.projectionVersion,
        createdAt: createdAt ?? this.createdAt,
      );
  MessageProjectionMapping copyWithCompanion(
      MessageProjectionMappingsCompanion data) {
    return MessageProjectionMapping(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      rawMessageId: data.rawMessageId.present
          ? data.rawMessageId.value
          : this.rawMessageId,
      projectedMessageId: data.projectedMessageId.present
          ? data.projectedMessageId.value
          : this.projectedMessageId,
      projectionKind: data.projectionKind.present
          ? data.projectionKind.value
          : this.projectionKind,
      segmentIndex: data.segmentIndex.present
          ? data.segmentIndex.value
          : this.segmentIndex,
      projectionVersion: data.projectionVersion.present
          ? data.projectionVersion.value
          : this.projectionVersion,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageProjectionMapping(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('rawMessageId: $rawMessageId, ')
          ..write('projectedMessageId: $projectedMessageId, ')
          ..write('projectionKind: $projectionKind, ')
          ..write('segmentIndex: $segmentIndex, ')
          ..write('projectionVersion: $projectionVersion, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      conversationId,
      rawMessageId,
      projectedMessageId,
      projectionKind,
      segmentIndex,
      projectionVersion,
      createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageProjectionMapping &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.rawMessageId == this.rawMessageId &&
          other.projectedMessageId == this.projectedMessageId &&
          other.projectionKind == this.projectionKind &&
          other.segmentIndex == this.segmentIndex &&
          other.projectionVersion == this.projectionVersion &&
          other.createdAt == this.createdAt);
}

class MessageProjectionMappingsCompanion
    extends UpdateCompanion<MessageProjectionMapping> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> rawMessageId;
  final Value<String> projectedMessageId;
  final Value<String> projectionKind;
  final Value<int> segmentIndex;
  final Value<String?> projectionVersion;
  final Value<int> createdAt;
  final Value<int> rowid;
  const MessageProjectionMappingsCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.rawMessageId = const Value.absent(),
    this.projectedMessageId = const Value.absent(),
    this.projectionKind = const Value.absent(),
    this.segmentIndex = const Value.absent(),
    this.projectionVersion = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessageProjectionMappingsCompanion.insert({
    required String id,
    required String conversationId,
    required String rawMessageId,
    required String projectedMessageId,
    this.projectionKind = const Value.absent(),
    this.segmentIndex = const Value.absent(),
    this.projectionVersion = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        conversationId = Value(conversationId),
        rawMessageId = Value(rawMessageId),
        projectedMessageId = Value(projectedMessageId),
        createdAt = Value(createdAt);
  static Insertable<MessageProjectionMapping> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? rawMessageId,
    Expression<String>? projectedMessageId,
    Expression<String>? projectionKind,
    Expression<int>? segmentIndex,
    Expression<String>? projectionVersion,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (rawMessageId != null) 'raw_message_id': rawMessageId,
      if (projectedMessageId != null)
        'projected_message_id': projectedMessageId,
      if (projectionKind != null) 'projection_kind': projectionKind,
      if (segmentIndex != null) 'segment_index': segmentIndex,
      if (projectionVersion != null) 'projection_version': projectionVersion,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessageProjectionMappingsCompanion copyWith(
      {Value<String>? id,
      Value<String>? conversationId,
      Value<String>? rawMessageId,
      Value<String>? projectedMessageId,
      Value<String>? projectionKind,
      Value<int>? segmentIndex,
      Value<String?>? projectionVersion,
      Value<int>? createdAt,
      Value<int>? rowid}) {
    return MessageProjectionMappingsCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      rawMessageId: rawMessageId ?? this.rawMessageId,
      projectedMessageId: projectedMessageId ?? this.projectedMessageId,
      projectionKind: projectionKind ?? this.projectionKind,
      segmentIndex: segmentIndex ?? this.segmentIndex,
      projectionVersion: projectionVersion ?? this.projectionVersion,
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
    if (rawMessageId.present) {
      map['raw_message_id'] = Variable<String>(rawMessageId.value);
    }
    if (projectedMessageId.present) {
      map['projected_message_id'] = Variable<String>(projectedMessageId.value);
    }
    if (projectionKind.present) {
      map['projection_kind'] = Variable<String>(projectionKind.value);
    }
    if (segmentIndex.present) {
      map['segment_index'] = Variable<int>(segmentIndex.value);
    }
    if (projectionVersion.present) {
      map['projection_version'] = Variable<String>(projectionVersion.value);
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
    return (StringBuffer('MessageProjectionMappingsCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('rawMessageId: $rawMessageId, ')
          ..write('projectedMessageId: $projectedMessageId, ')
          ..write('projectionKind: $projectionKind, ')
          ..write('segmentIndex: $segmentIndex, ')
          ..write('projectionVersion: $projectionVersion, ')
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
  static const VerificationMeta _sourceBlockIdMeta =
      const VerificationMeta('sourceBlockId');
  @override
  late final GeneratedColumn<String> sourceBlockId = GeneratedColumn<String>(
      'source_block_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
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
  List<GeneratedColumn> get $columns => [
        id,
        messageId,
        sourceBlockId,
        type,
        status,
        data,
        sortOrder,
        deletedAt,
        createdAt
      ];
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
    if (data.containsKey('source_block_id')) {
      context.handle(
          _sourceBlockIdMeta,
          sourceBlockId.isAcceptableOrUnknown(
              data['source_block_id']!, _sourceBlockIdMeta));
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
      sourceBlockId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_block_id']),
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
  final String? sourceBlockId;
  final String type;
  final String status;
  final String data;
  final int sortOrder;
  final int? deletedAt;
  final int createdAt;
  const MessageBlock(
      {required this.id,
      required this.messageId,
      this.sourceBlockId,
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
    if (!nullToAbsent || sourceBlockId != null) {
      map['source_block_id'] = Variable<String>(sourceBlockId);
    }
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
      sourceBlockId: sourceBlockId == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceBlockId),
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
      sourceBlockId: serializer.fromJson<String?>(json['sourceBlockId']),
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
      'sourceBlockId': serializer.toJson<String?>(sourceBlockId),
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
          Value<String?> sourceBlockId = const Value.absent(),
          String? type,
          String? status,
          String? data,
          int? sortOrder,
          Value<int?> deletedAt = const Value.absent(),
          int? createdAt}) =>
      MessageBlock(
        id: id ?? this.id,
        messageId: messageId ?? this.messageId,
        sourceBlockId:
            sourceBlockId.present ? sourceBlockId.value : this.sourceBlockId,
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
      sourceBlockId: data.sourceBlockId.present
          ? data.sourceBlockId.value
          : this.sourceBlockId,
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
          ..write('sourceBlockId: $sourceBlockId, ')
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
  int get hashCode => Object.hash(id, messageId, sourceBlockId, type, status,
      data, sortOrder, deletedAt, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageBlock &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.sourceBlockId == this.sourceBlockId &&
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
  final Value<String?> sourceBlockId;
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
    this.sourceBlockId = const Value.absent(),
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
    this.sourceBlockId = const Value.absent(),
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
    Expression<String>? sourceBlockId,
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
      if (sourceBlockId != null) 'source_block_id': sourceBlockId,
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
      Value<String?>? sourceBlockId,
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
      sourceBlockId: sourceBlockId ?? this.sourceBlockId,
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
    if (sourceBlockId.present) {
      map['source_block_id'] = Variable<String>(sourceBlockId.value);
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
          ..write('sourceBlockId: $sourceBlockId, ')
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

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $MessageProjectionMappingsTable messageProjectionMappings =
      $MessageProjectionMappingsTable(this);
  late final $MessageBlocksTable messageBlocks = $MessageBlocksTable(this);
  late final $ProvidersTable providers = $ProvidersTable(this);
  late final $SyncScopesTable syncScopes = $SyncScopesTable(this);
  late final $SyncCursorsTable syncCursors = $SyncCursorsTable(this);
  late final $PendingOperationsTable pendingOperations =
      $PendingOperationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        conversations,
        messages,
        messageProjectionMappings,
        messageBlocks,
        providers,
        syncScopes,
        syncCursors,
        pendingOperations
      ];
}

typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion
    Function({
  required String id,
  required String title,
  required String displayName,
  Value<String?> avatarUrl,
  Value<String?> characterImage,
  Value<String?> chatBackgroundImage,
  Value<double?> chatBackgroundMaskOpacity,
  Value<double?> chatBackgroundBlurSigma,
  Value<String?> blurredBackground,
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
  Value<String?> enabledPlugins,
  Value<String?> recipeId,
  Value<String?> thinkingLevels,
  Value<String?> lastMessage,
  Value<int?> lastMessageTime,
  Value<int> unreadCount,
  Value<String?> parentConversationId,
  Value<String?> forkFromMessageId,
  Value<String?> conflictOf,
  Value<String?> contextStartMessageId,
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
  Value<String?> chatBackgroundImage,
  Value<double?> chatBackgroundMaskOpacity,
  Value<double?> chatBackgroundBlurSigma,
  Value<String?> blurredBackground,
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
  Value<String?> enabledPlugins,
  Value<String?> recipeId,
  Value<String?> thinkingLevels,
  Value<String?> lastMessage,
  Value<int?> lastMessageTime,
  Value<int> unreadCount,
  Value<String?> parentConversationId,
  Value<String?> forkFromMessageId,
  Value<String?> conflictOf,
  Value<String?> contextStartMessageId,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int> rowid,
});

class $$ConversationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ConversationsTable,
    Conversation,
    $$ConversationsTableFilterComposer,
    $$ConversationsTableOrderingComposer,
    $$ConversationsTableCreateCompanionBuilder,
    $$ConversationsTableUpdateCompanionBuilder> {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$ConversationsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$ConversationsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> displayName = const Value.absent(),
            Value<String?> avatarUrl = const Value.absent(),
            Value<String?> characterImage = const Value.absent(),
            Value<String?> chatBackgroundImage = const Value.absent(),
            Value<double?> chatBackgroundMaskOpacity = const Value.absent(),
            Value<double?> chatBackgroundBlurSigma = const Value.absent(),
            Value<String?> blurredBackground = const Value.absent(),
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
            Value<String?> enabledPlugins = const Value.absent(),
            Value<String?> recipeId = const Value.absent(),
            Value<String?> thinkingLevels = const Value.absent(),
            Value<String?> lastMessage = const Value.absent(),
            Value<int?> lastMessageTime = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> parentConversationId = const Value.absent(),
            Value<String?> forkFromMessageId = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<String?> contextStartMessageId = const Value.absent(),
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
            chatBackgroundImage: chatBackgroundImage,
            chatBackgroundMaskOpacity: chatBackgroundMaskOpacity,
            chatBackgroundBlurSigma: chatBackgroundBlurSigma,
            blurredBackground: blurredBackground,
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
            enabledPlugins: enabledPlugins,
            recipeId: recipeId,
            thinkingLevels: thinkingLevels,
            lastMessage: lastMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: unreadCount,
            parentConversationId: parentConversationId,
            forkFromMessageId: forkFromMessageId,
            conflictOf: conflictOf,
            contextStartMessageId: contextStartMessageId,
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
            Value<String?> chatBackgroundImage = const Value.absent(),
            Value<double?> chatBackgroundMaskOpacity = const Value.absent(),
            Value<double?> chatBackgroundBlurSigma = const Value.absent(),
            Value<String?> blurredBackground = const Value.absent(),
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
            Value<String?> enabledPlugins = const Value.absent(),
            Value<String?> recipeId = const Value.absent(),
            Value<String?> thinkingLevels = const Value.absent(),
            Value<String?> lastMessage = const Value.absent(),
            Value<int?> lastMessageTime = const Value.absent(),
            Value<int> unreadCount = const Value.absent(),
            Value<String?> parentConversationId = const Value.absent(),
            Value<String?> forkFromMessageId = const Value.absent(),
            Value<String?> conflictOf = const Value.absent(),
            Value<String?> contextStartMessageId = const Value.absent(),
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
            chatBackgroundImage: chatBackgroundImage,
            chatBackgroundMaskOpacity: chatBackgroundMaskOpacity,
            chatBackgroundBlurSigma: chatBackgroundBlurSigma,
            blurredBackground: blurredBackground,
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
            enabledPlugins: enabledPlugins,
            recipeId: recipeId,
            thinkingLevels: thinkingLevels,
            lastMessage: lastMessage,
            lastMessageTime: lastMessageTime,
            unreadCount: unreadCount,
            parentConversationId: parentConversationId,
            forkFromMessageId: forkFromMessageId,
            conflictOf: conflictOf,
            contextStartMessageId: contextStartMessageId,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
        ));
}

class $$ConversationsTableFilterComposer
    extends FilterComposer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer(super.$state);
  ColumnFilters<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get title => $state.composableBuilder(
      column: $state.table.title,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get displayName => $state.composableBuilder(
      column: $state.table.displayName,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get avatarUrl => $state.composableBuilder(
      column: $state.table.avatarUrl,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get characterImage => $state.composableBuilder(
      column: $state.table.characterImage,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get chatBackgroundImage => $state.composableBuilder(
      column: $state.table.chatBackgroundImage,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<double> get chatBackgroundMaskOpacity =>
      $state.composableBuilder(
          column: $state.table.chatBackgroundMaskOpacity,
          builder: (column, joinBuilders) =>
              ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<double> get chatBackgroundBlurSigma => $state.composableBuilder(
      column: $state.table.chatBackgroundBlurSigma,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get blurredBackground => $state.composableBuilder(
      column: $state.table.blurredBackground,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get selfAddress => $state.composableBuilder(
      column: $state.table.selfAddress,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get addressUser => $state.composableBuilder(
      column: $state.table.addressUser,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get voiceFile => $state.composableBuilder(
      column: $state.table.voiceFile,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get personaPrompt => $state.composableBuilder(
      column: $state.table.personaPrompt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get defaultProvider => $state.composableBuilder(
      column: $state.table.defaultProvider,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get sessionProvider => $state.composableBuilder(
      column: $state.table.sessionProvider,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get isPinned => $state.composableBuilder(
      column: $state.table.isPinned,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get isFavorite => $state.composableBuilder(
      column: $state.table.isFavorite,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get isMuted => $state.composableBuilder(
      column: $state.table.isMuted,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get notificationSound => $state.composableBuilder(
      column: $state.table.notificationSound,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get enabledPlugins => $state.composableBuilder(
      column: $state.table.enabledPlugins,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get recipeId => $state.composableBuilder(
      column: $state.table.recipeId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get thinkingLevels => $state.composableBuilder(
      column: $state.table.thinkingLevels,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get lastMessage => $state.composableBuilder(
      column: $state.table.lastMessage,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get lastMessageTime => $state.composableBuilder(
      column: $state.table.lastMessageTime,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get unreadCount => $state.composableBuilder(
      column: $state.table.unreadCount,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get parentConversationId => $state.composableBuilder(
      column: $state.table.parentConversationId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get forkFromMessageId => $state.composableBuilder(
      column: $state.table.forkFromMessageId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get contextStartMessageId => $state.composableBuilder(
      column: $state.table.contextStartMessageId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ComposableFilter messagesRefs(
      ComposableFilter Function($$MessagesTableFilterComposer f) f) {
    final $$MessagesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.messages,
        getReferencedColumn: (t) => t.conversationId,
        builder: (joinBuilder, parentComposers) =>
            $$MessagesTableFilterComposer(ComposerState(
                $state.db, $state.db.messages, joinBuilder, parentComposers)));
    return f(composer);
  }

  ComposableFilter messageProjectionMappingsRefs(
      ComposableFilter Function(
              $$MessageProjectionMappingsTableFilterComposer f)
          f) {
    final $$MessageProjectionMappingsTableFilterComposer composer =
        $state.composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $state.db.messageProjectionMappings,
            getReferencedColumn: (t) => t.conversationId,
            builder: (joinBuilder, parentComposers) =>
                $$MessageProjectionMappingsTableFilterComposer(ComposerState(
                    $state.db,
                    $state.db.messageProjectionMappings,
                    joinBuilder,
                    parentComposers)));
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer(super.$state);
  ColumnOrderings<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get title => $state.composableBuilder(
      column: $state.table.title,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get displayName => $state.composableBuilder(
      column: $state.table.displayName,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get avatarUrl => $state.composableBuilder(
      column: $state.table.avatarUrl,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get characterImage => $state.composableBuilder(
      column: $state.table.characterImage,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get chatBackgroundImage => $state.composableBuilder(
      column: $state.table.chatBackgroundImage,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<double> get chatBackgroundMaskOpacity => $state
      .composableBuilder(
          column: $state.table.chatBackgroundMaskOpacity,
          builder: (column, joinBuilders) =>
              ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<double> get chatBackgroundBlurSigma =>
      $state.composableBuilder(
          column: $state.table.chatBackgroundBlurSigma,
          builder: (column, joinBuilders) =>
              ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get blurredBackground => $state.composableBuilder(
      column: $state.table.blurredBackground,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get selfAddress => $state.composableBuilder(
      column: $state.table.selfAddress,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get addressUser => $state.composableBuilder(
      column: $state.table.addressUser,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get voiceFile => $state.composableBuilder(
      column: $state.table.voiceFile,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get personaPrompt => $state.composableBuilder(
      column: $state.table.personaPrompt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get defaultProvider => $state.composableBuilder(
      column: $state.table.defaultProvider,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get sessionProvider => $state.composableBuilder(
      column: $state.table.sessionProvider,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get isPinned => $state.composableBuilder(
      column: $state.table.isPinned,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get isFavorite => $state.composableBuilder(
      column: $state.table.isFavorite,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get isMuted => $state.composableBuilder(
      column: $state.table.isMuted,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get notificationSound => $state.composableBuilder(
      column: $state.table.notificationSound,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get enabledPlugins => $state.composableBuilder(
      column: $state.table.enabledPlugins,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get recipeId => $state.composableBuilder(
      column: $state.table.recipeId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get thinkingLevels => $state.composableBuilder(
      column: $state.table.thinkingLevels,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get lastMessage => $state.composableBuilder(
      column: $state.table.lastMessage,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get lastMessageTime => $state.composableBuilder(
      column: $state.table.lastMessageTime,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get unreadCount => $state.composableBuilder(
      column: $state.table.unreadCount,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get parentConversationId => $state.composableBuilder(
      column: $state.table.parentConversationId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get forkFromMessageId => $state.composableBuilder(
      column: $state.table.forkFromMessageId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get contextStartMessageId => $state.composableBuilder(
      column: $state.table.contextStartMessageId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String role,
  required String content,
  Value<String> status,
  Value<bool> summarized,
  Value<int?> summarizedAt,
  Value<String?> replacedBy,
  Value<String?> sourceMessageId,
  Value<String?> rawPayload,
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
  Value<bool> summarized,
  Value<int?> summarizedAt,
  Value<String?> replacedBy,
  Value<String?> sourceMessageId,
  Value<String?> rawPayload,
  Value<String?> conflictOf,
  Value<int?> deletedAt,
  Value<int?> purgeAt,
  Value<int> createdAt,
  Value<int> rowid,
});

class $$MessagesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessagesTable,
    Message,
    $$MessagesTableFilterComposer,
    $$MessagesTableOrderingComposer,
    $$MessagesTableCreateCompanionBuilder,
    $$MessagesTableUpdateCompanionBuilder> {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$MessagesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$MessagesTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> role = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<bool> summarized = const Value.absent(),
            Value<int?> summarizedAt = const Value.absent(),
            Value<String?> replacedBy = const Value.absent(),
            Value<String?> sourceMessageId = const Value.absent(),
            Value<String?> rawPayload = const Value.absent(),
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
            summarized: summarized,
            summarizedAt: summarizedAt,
            replacedBy: replacedBy,
            sourceMessageId: sourceMessageId,
            rawPayload: rawPayload,
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
            Value<bool> summarized = const Value.absent(),
            Value<int?> summarizedAt = const Value.absent(),
            Value<String?> replacedBy = const Value.absent(),
            Value<String?> sourceMessageId = const Value.absent(),
            Value<String?> rawPayload = const Value.absent(),
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
            summarized: summarized,
            summarizedAt: summarizedAt,
            replacedBy: replacedBy,
            sourceMessageId: sourceMessageId,
            rawPayload: rawPayload,
            conflictOf: conflictOf,
            deletedAt: deletedAt,
            purgeAt: purgeAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
        ));
}

class $$MessagesTableFilterComposer
    extends FilterComposer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer(super.$state);
  ColumnFilters<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get role => $state.composableBuilder(
      column: $state.table.role,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get content => $state.composableBuilder(
      column: $state.table.content,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get status => $state.composableBuilder(
      column: $state.table.status,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get summarized => $state.composableBuilder(
      column: $state.table.summarized,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get summarizedAt => $state.composableBuilder(
      column: $state.table.summarizedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get replacedBy => $state.composableBuilder(
      column: $state.table.replacedBy,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get sourceMessageId => $state.composableBuilder(
      column: $state.table.sourceMessageId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get rawPayload => $state.composableBuilder(
      column: $state.table.rawPayload,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $state.db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ConversationsTableFilterComposer(ComposerState($state.db,
                $state.db.conversations, joinBuilder, parentComposers)));
    return composer;
  }

  ComposableFilter messageProjectionMappingsRefs(
      ComposableFilter Function(
              $$MessageProjectionMappingsTableFilterComposer f)
          f) {
    final $$MessageProjectionMappingsTableFilterComposer composer =
        $state.composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.id,
            referencedTable: $state.db.messageProjectionMappings,
            getReferencedColumn: (t) => t.rawMessageId,
            builder: (joinBuilder, parentComposers) =>
                $$MessageProjectionMappingsTableFilterComposer(ComposerState(
                    $state.db,
                    $state.db.messageProjectionMappings,
                    joinBuilder,
                    parentComposers)));
    return f(composer);
  }

  ComposableFilter messageBlocksRefs(
      ComposableFilter Function($$MessageBlocksTableFilterComposer f) f) {
    final $$MessageBlocksTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.messageBlocks,
        getReferencedColumn: (t) => t.messageId,
        builder: (joinBuilder, parentComposers) =>
            $$MessageBlocksTableFilterComposer(ComposerState($state.db,
                $state.db.messageBlocks, joinBuilder, parentComposers)));
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer(super.$state);
  ColumnOrderings<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get role => $state.composableBuilder(
      column: $state.table.role,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get content => $state.composableBuilder(
      column: $state.table.content,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get status => $state.composableBuilder(
      column: $state.table.status,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get summarized => $state.composableBuilder(
      column: $state.table.summarized,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get summarizedAt => $state.composableBuilder(
      column: $state.table.summarizedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get replacedBy => $state.composableBuilder(
      column: $state.table.replacedBy,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get sourceMessageId => $state.composableBuilder(
      column: $state.table.sourceMessageId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get rawPayload => $state.composableBuilder(
      column: $state.table.rawPayload,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer =
        $state.composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.conversationId,
            referencedTable: $state.db.conversations,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder, parentComposers) =>
                $$ConversationsTableOrderingComposer(ComposerState($state.db,
                    $state.db.conversations, joinBuilder, parentComposers)));
    return composer;
  }
}

typedef $$MessageProjectionMappingsTableCreateCompanionBuilder
    = MessageProjectionMappingsCompanion Function({
  required String id,
  required String conversationId,
  required String rawMessageId,
  required String projectedMessageId,
  Value<String> projectionKind,
  Value<int> segmentIndex,
  Value<String?> projectionVersion,
  required int createdAt,
  Value<int> rowid,
});
typedef $$MessageProjectionMappingsTableUpdateCompanionBuilder
    = MessageProjectionMappingsCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> rawMessageId,
  Value<String> projectedMessageId,
  Value<String> projectionKind,
  Value<int> segmentIndex,
  Value<String?> projectionVersion,
  Value<int> createdAt,
  Value<int> rowid,
});

class $$MessageProjectionMappingsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessageProjectionMappingsTable,
    MessageProjectionMapping,
    $$MessageProjectionMappingsTableFilterComposer,
    $$MessageProjectionMappingsTableOrderingComposer,
    $$MessageProjectionMappingsTableCreateCompanionBuilder,
    $$MessageProjectionMappingsTableUpdateCompanionBuilder> {
  $$MessageProjectionMappingsTableTableManager(
      _$AppDatabase db, $MessageProjectionMappingsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer: $$MessageProjectionMappingsTableFilterComposer(
              ComposerState(db, table)),
          orderingComposer: $$MessageProjectionMappingsTableOrderingComposer(
              ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> conversationId = const Value.absent(),
            Value<String> rawMessageId = const Value.absent(),
            Value<String> projectedMessageId = const Value.absent(),
            Value<String> projectionKind = const Value.absent(),
            Value<int> segmentIndex = const Value.absent(),
            Value<String?> projectionVersion = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageProjectionMappingsCompanion(
            id: id,
            conversationId: conversationId,
            rawMessageId: rawMessageId,
            projectedMessageId: projectedMessageId,
            projectionKind: projectionKind,
            segmentIndex: segmentIndex,
            projectionVersion: projectionVersion,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String conversationId,
            required String rawMessageId,
            required String projectedMessageId,
            Value<String> projectionKind = const Value.absent(),
            Value<int> segmentIndex = const Value.absent(),
            Value<String?> projectionVersion = const Value.absent(),
            required int createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              MessageProjectionMappingsCompanion.insert(
            id: id,
            conversationId: conversationId,
            rawMessageId: rawMessageId,
            projectedMessageId: projectedMessageId,
            projectionKind: projectionKind,
            segmentIndex: segmentIndex,
            projectionVersion: projectionVersion,
            createdAt: createdAt,
            rowid: rowid,
          ),
        ));
}

class $$MessageProjectionMappingsTableFilterComposer
    extends FilterComposer<_$AppDatabase, $MessageProjectionMappingsTable> {
  $$MessageProjectionMappingsTableFilterComposer(super.$state);
  ColumnFilters<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get projectedMessageId => $state.composableBuilder(
      column: $state.table.projectedMessageId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get projectionKind => $state.composableBuilder(
      column: $state.table.projectionKind,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get segmentIndex => $state.composableBuilder(
      column: $state.table.segmentIndex,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get projectionVersion => $state.composableBuilder(
      column: $state.table.projectionVersion,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.conversationId,
        referencedTable: $state.db.conversations,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ConversationsTableFilterComposer(ComposerState($state.db,
                $state.db.conversations, joinBuilder, parentComposers)));
    return composer;
  }

  $$MessagesTableFilterComposer get rawMessageId {
    final $$MessagesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.rawMessageId,
        referencedTable: $state.db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$MessagesTableFilterComposer(ComposerState(
                $state.db, $state.db.messages, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$MessageProjectionMappingsTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $MessageProjectionMappingsTable> {
  $$MessageProjectionMappingsTableOrderingComposer(super.$state);
  ColumnOrderings<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get projectedMessageId => $state.composableBuilder(
      column: $state.table.projectedMessageId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get projectionKind => $state.composableBuilder(
      column: $state.table.projectionKind,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get segmentIndex => $state.composableBuilder(
      column: $state.table.segmentIndex,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get projectionVersion => $state.composableBuilder(
      column: $state.table.projectionVersion,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer =
        $state.composerBuilder(
            composer: this,
            getCurrentColumn: (t) => t.conversationId,
            referencedTable: $state.db.conversations,
            getReferencedColumn: (t) => t.id,
            builder: (joinBuilder, parentComposers) =>
                $$ConversationsTableOrderingComposer(ComposerState($state.db,
                    $state.db.conversations, joinBuilder, parentComposers)));
    return composer;
  }

  $$MessagesTableOrderingComposer get rawMessageId {
    final $$MessagesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.rawMessageId,
        referencedTable: $state.db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$MessagesTableOrderingComposer(ComposerState(
                $state.db, $state.db.messages, joinBuilder, parentComposers)));
    return composer;
  }
}

typedef $$MessageBlocksTableCreateCompanionBuilder = MessageBlocksCompanion
    Function({
  required String id,
  required String messageId,
  Value<String?> sourceBlockId,
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
  Value<String?> sourceBlockId,
  Value<String> type,
  Value<String> status,
  Value<String> data,
  Value<int> sortOrder,
  Value<int?> deletedAt,
  Value<int> createdAt,
  Value<int> rowid,
});

class $$MessageBlocksTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MessageBlocksTable,
    MessageBlock,
    $$MessageBlocksTableFilterComposer,
    $$MessageBlocksTableOrderingComposer,
    $$MessageBlocksTableCreateCompanionBuilder,
    $$MessageBlocksTableUpdateCompanionBuilder> {
  $$MessageBlocksTableTableManager(_$AppDatabase db, $MessageBlocksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$MessageBlocksTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$MessageBlocksTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> messageId = const Value.absent(),
            Value<String?> sourceBlockId = const Value.absent(),
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
            sourceBlockId: sourceBlockId,
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
            Value<String?> sourceBlockId = const Value.absent(),
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
            sourceBlockId: sourceBlockId,
            type: type,
            status: status,
            data: data,
            sortOrder: sortOrder,
            deletedAt: deletedAt,
            createdAt: createdAt,
            rowid: rowid,
          ),
        ));
}

class $$MessageBlocksTableFilterComposer
    extends FilterComposer<_$AppDatabase, $MessageBlocksTable> {
  $$MessageBlocksTableFilterComposer(super.$state);
  ColumnFilters<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get sourceBlockId => $state.composableBuilder(
      column: $state.table.sourceBlockId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get type => $state.composableBuilder(
      column: $state.table.type,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get status => $state.composableBuilder(
      column: $state.table.status,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get data => $state.composableBuilder(
      column: $state.table.data,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get sortOrder => $state.composableBuilder(
      column: $state.table.sortOrder,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $state.db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$MessagesTableFilterComposer(ComposerState(
                $state.db, $state.db.messages, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$MessageBlocksTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $MessageBlocksTable> {
  $$MessageBlocksTableOrderingComposer(super.$state);
  ColumnOrderings<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get sourceBlockId => $state.composableBuilder(
      column: $state.table.sourceBlockId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get type => $state.composableBuilder(
      column: $state.table.type,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get status => $state.composableBuilder(
      column: $state.table.status,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get data => $state.composableBuilder(
      column: $state.table.data,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get sortOrder => $state.composableBuilder(
      column: $state.table.sortOrder,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.messageId,
        referencedTable: $state.db.messages,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$MessagesTableOrderingComposer(ComposerState(
                $state.db, $state.db.messages, joinBuilder, parentComposers)));
    return composer;
  }
}

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

class $$ProvidersTableTableManager extends RootTableManager<
    _$AppDatabase,
    $ProvidersTable,
    Provider,
    $$ProvidersTableFilterComposer,
    $$ProvidersTableOrderingComposer,
    $$ProvidersTableCreateCompanionBuilder,
    $$ProvidersTableUpdateCompanionBuilder> {
  $$ProvidersTableTableManager(_$AppDatabase db, $ProvidersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$ProvidersTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$ProvidersTableOrderingComposer(ComposerState(db, table)),
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
        ));
}

class $$ProvidersTableFilterComposer
    extends FilterComposer<_$AppDatabase, $ProvidersTable> {
  $$ProvidersTableFilterComposer(super.$state);
  ColumnFilters<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get displayName => $state.composableBuilder(
      column: $state.table.displayName,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get apiBaseUrl => $state.composableBuilder(
      column: $state.table.apiBaseUrl,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get enabled => $state.composableBuilder(
      column: $state.table.enabled,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get capabilities => $state.composableBuilder(
      column: $state.table.capabilities,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get customConfig => $state.composableBuilder(
      column: $state.table.customConfig,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get modelType => $state.composableBuilder(
      column: $state.table.modelType,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get visibleModels => $state.composableBuilder(
      column: $state.table.visibleModels,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get hiddenModels => $state.composableBuilder(
      column: $state.table.hiddenModels,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get apiKeys => $state.composableBuilder(
      column: $state.table.apiKeys,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));
}

class $$ProvidersTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $ProvidersTable> {
  $$ProvidersTableOrderingComposer(super.$state);
  ColumnOrderings<String> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get displayName => $state.composableBuilder(
      column: $state.table.displayName,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get apiBaseUrl => $state.composableBuilder(
      column: $state.table.apiBaseUrl,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get enabled => $state.composableBuilder(
      column: $state.table.enabled,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get capabilities => $state.composableBuilder(
      column: $state.table.capabilities,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get customConfig => $state.composableBuilder(
      column: $state.table.customConfig,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get modelType => $state.composableBuilder(
      column: $state.table.modelType,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get visibleModels => $state.composableBuilder(
      column: $state.table.visibleModels,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get hiddenModels => $state.composableBuilder(
      column: $state.table.hiddenModels,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get apiKeys => $state.composableBuilder(
      column: $state.table.apiKeys,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get conflictOf => $state.composableBuilder(
      column: $state.table.conflictOf,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get deletedAt => $state.composableBuilder(
      column: $state.table.deletedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get purgeAt => $state.composableBuilder(
      column: $state.table.purgeAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

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

class $$SyncScopesTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SyncScopesTable,
    SyncScope,
    $$SyncScopesTableFilterComposer,
    $$SyncScopesTableOrderingComposer,
    $$SyncScopesTableCreateCompanionBuilder,
    $$SyncScopesTableUpdateCompanionBuilder> {
  $$SyncScopesTableTableManager(_$AppDatabase db, $SyncScopesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$SyncScopesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$SyncScopesTableOrderingComposer(ComposerState(db, table)),
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
        ));
}

class $$SyncScopesTableFilterComposer
    extends FilterComposer<_$AppDatabase, $SyncScopesTable> {
  $$SyncScopesTableFilterComposer(super.$state);
  ColumnFilters<String> get enabledScopes => $state.composableBuilder(
      column: $state.table.enabledScopes,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));
}

class $$SyncScopesTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $SyncScopesTable> {
  $$SyncScopesTableOrderingComposer(super.$state);
  ColumnOrderings<String> get enabledScopes => $state.composableBuilder(
      column: $state.table.enabledScopes,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

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

class $$SyncCursorsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $SyncCursorsTable,
    SyncCursor,
    $$SyncCursorsTableFilterComposer,
    $$SyncCursorsTableOrderingComposer,
    $$SyncCursorsTableCreateCompanionBuilder,
    $$SyncCursorsTableUpdateCompanionBuilder> {
  $$SyncCursorsTableTableManager(_$AppDatabase db, $SyncCursorsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$SyncCursorsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$SyncCursorsTableOrderingComposer(ComposerState(db, table)),
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
        ));
}

class $$SyncCursorsTableFilterComposer
    extends FilterComposer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableFilterComposer(super.$state);
  ColumnFilters<String> get deviceId => $state.composableBuilder(
      column: $state.table.deviceId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get conversationsCursor => $state.composableBuilder(
      column: $state.table.conversationsCursor,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get messagesCursor => $state.composableBuilder(
      column: $state.table.messagesCursor,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get providersCursor => $state.composableBuilder(
      column: $state.table.providersCursor,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));
}

class $$SyncCursorsTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableOrderingComposer(super.$state);
  ColumnOrderings<String> get deviceId => $state.composableBuilder(
      column: $state.table.deviceId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get conversationsCursor => $state.composableBuilder(
      column: $state.table.conversationsCursor,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get messagesCursor => $state.composableBuilder(
      column: $state.table.messagesCursor,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get providersCursor => $state.composableBuilder(
      column: $state.table.providersCursor,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get updatedAt => $state.composableBuilder(
      column: $state.table.updatedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

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

class $$PendingOperationsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $PendingOperationsTable,
    PendingOperation,
    $$PendingOperationsTableFilterComposer,
    $$PendingOperationsTableOrderingComposer,
    $$PendingOperationsTableCreateCompanionBuilder,
    $$PendingOperationsTableUpdateCompanionBuilder> {
  $$PendingOperationsTableTableManager(
      _$AppDatabase db, $PendingOperationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$PendingOperationsTableFilterComposer(ComposerState(db, table)),
          orderingComposer: $$PendingOperationsTableOrderingComposer(
              ComposerState(db, table)),
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
        ));
}

class $$PendingOperationsTableFilterComposer
    extends FilterComposer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableFilterComposer(super.$state);
  ColumnFilters<String> get opId => $state.composableBuilder(
      column: $state.table.opId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get opType => $state.composableBuilder(
      column: $state.table.opType,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get opData => $state.composableBuilder(
      column: $state.table.opData,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get synced => $state.composableBuilder(
      column: $state.table.synced,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));
}

class $$PendingOperationsTableOrderingComposer
    extends OrderingComposer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableOrderingComposer(super.$state);
  ColumnOrderings<String> get opId => $state.composableBuilder(
      column: $state.table.opId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get opType => $state.composableBuilder(
      column: $state.table.opType,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get opData => $state.composableBuilder(
      column: $state.table.opData,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get synced => $state.composableBuilder(
      column: $state.table.synced,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$MessageProjectionMappingsTableTableManager get messageProjectionMappings =>
      $$MessageProjectionMappingsTableTableManager(
          _db, _db.messageProjectionMappings);
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
}
