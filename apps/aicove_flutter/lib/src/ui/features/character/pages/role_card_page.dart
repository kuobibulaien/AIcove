import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/application/chat_page_queries.dart';
import '../../../../features/chat/data/preset_characters_loader.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/providers2.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../chat/widgets/message_search_results.dart';
import '../services/open_role_chat.dart';

class RoleCardPage extends StatefulWidget {
  const RoleCardPage({super.key});

  @override
  State<RoleCardPage> createState() => _RoleCardPageState();
}

class _RoleCardPageState extends State<RoleCardPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MoeSurfaceGroup.contains(context)
        ? Colors.transparent
        : context.moeColors.surface,
    extendBodyBehindAppBar: true,
    appBar: MoeAppBar(
      title: '角色',
      centerTitle: true,
      bottom: MoeSearchField(
        hintText: '搜索',
        onChanged: (value) => setState(() => _query = value),
      ),
      bottomHeight: MoeSearchField.heightFor(context),
      actions: [
        IconButton(
          tooltip: '创建角色',
          icon: const Icon(Icons.person_add_alt_1_outlined),
          onPressed: () => MoeWorkspace.openLocation(context, '/contact/new'),
        ),
      ],
    ),
    body: RoleCardContent(query: _query),
  );
}

/// Shared, ungrouped role directory with one row per role.
///
/// A non-empty [query] filters roles by name and also matches chat records
/// across all conversations.
class RoleCardContent extends ConsumerStatefulWidget {
  const RoleCardContent({super.key, this.query = ''});

  final String query;

  @override
  ConsumerState<RoleCardContent> createState() => _RoleCardContentState();
}

class _RoleCardContentState extends ConsumerState<RoleCardContent> {
  late final _presets = PresetCharactersLoader.load();

  Timer? _searchDebounce;
  int _searchSeq = 0;
  String _hitsQuery = '';
  List<ChatPageMessageSearchItem> _messageHits = const [];

  String get _query => widget.query.trim();

  @override
  void initState() {
    super.initState();
    if (_query.isNotEmpty) _scheduleMessageSearch();
  }

  @override
  void didUpdateWidget(covariant RoleCardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.trim() != _query) _scheduleMessageSearch();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _scheduleMessageSearch() {
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    final query = _query;
    if (query.isEmpty) {
      _hitsQuery = '';
      _messageHits = const [];
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final hits = await ref
            .read(chatPageQueriesProvider)
            .searchAllMessages(query);
        if (!mounted || seq != _searchSeq) return;
        setState(() {
          _hitsQuery = query;
          _messageHits = hits;
        });
      } on Object catch (error) {
        debugPrint('[RoleSearch] 聊天记录搜索失败: ${error.runtimeType}');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final conversations = ref.watch(conversationsProvider);
    return conversations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => MoeEmptyState(
        icon: Icons.error_outline,
        title: '角色加载失败',
        description: '$error',
      ),
      data: (items) => FutureBuilder<List<Conversation>>(
        future: _presets,
        builder: (context, snapshot) {
          final directory = {for (final role in items) role.id: role};
          for (final role in snapshot.data ?? <Conversation>[]) {
            directory.putIfAbsent(role.id, () => role);
          }
          final query = _query.toLowerCase();
          final roles = directory.values
              .where((c) => c.displayName.toLowerCase().contains(query))
              .toList(growable: false);
          final hits = query.isEmpty || _hitsQuery.toLowerCase() != query
              ? const <ChatPageMessageSearchItem>[]
              : [
                  for (final hit in _messageHits)
                    if (directory.containsKey(hit.conversationId)) hit,
                ];
          if (roles.isEmpty && hits.isEmpty) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            return MoeEmptyState(
              icon: Icons.search,
              title: query.isEmpty ? '暂无角色' : '没有找到角色或聊天记录',
            );
          }
          if (query.isNotEmpty) {
            // 搜索时分两段：先角色，再聊天记录。
            return ListView(
              padding: moeUnderBarPadding(context),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (roles.isNotEmpty) ...[
                  const MessageSearchSectionHeader('角色'),
                  for (final role in roles) _buildRoleRow(context, role),
                ],
                if (hits.isNotEmpty) ...[
                  const MessageSearchSectionHeader('聊天记录'),
                  for (final hit in hits)
                    MessageSearchHitTile(
                      key: ValueKey('message-hit-${hit.id}'),
                      conversation: directory[hit.conversationId]!,
                      hit: hit,
                      keyword: query,
                      onTap: () => openRoleChat(
                        context,
                        ref,
                        directory[hit.conversationId]!,
                      ),
                    ),
                ],
              ],
            );
          }
          return ListView.separated(
            padding: moeUnderBarPadding(context),
            itemCount: roles.length,
            separatorBuilder: (_, __) => Divider(
              height: borderWidth,
              thickness: borderWidth,
              indent: 72,
              color: colors.divider,
            ),
            itemBuilder: (context, index) =>
                _buildRoleRow(context, roles[index]),
          );
        },
      ),
    );
  }

  Widget _buildRoleRow(BuildContext context, Conversation role) {
    final colors = context.moeColors;
    final description = role.description?.trim();
    return MoeListTile(
      key: ValueKey('role-directory-${role.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      leading: MoeAvatar(
        name: role.displayName,
        avatarUrl: role.avatarUrl,
        characterImage: role.characterImage,
        size: 48,
      ),
      title: Text(
        role.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 16,
          color: colors.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: description?.isNotEmpty == true
          ? Text(
              description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.muted),
            )
          : null,
      onTap: () => openRoleChat(context, ref, role),
    );
  }
}
