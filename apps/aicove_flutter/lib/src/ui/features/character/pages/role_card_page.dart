import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/data/preset_characters_loader.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/providers2.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../services/open_role_chat.dart';

class RoleCardPage extends StatelessWidget {
  const RoleCardPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: MoeSurfaceGroup.contains(context)
        ? Colors.transparent
        : context.moeColors.surface,
    appBar: MoeAppBar(
      title: '角色',
      centerTitle: true,
      actions: [
        IconButton(
          tooltip: '创建角色',
          icon: const Icon(Icons.person_add_alt_1_outlined),
          onPressed: () => MoeWorkspace.openLocation(context, '/contact/new'),
        ),
      ],
    ),
    body: const RoleCardContent(),
  );
}

/// Shared, ungrouped role directory with one row per role.
class RoleCardContent extends ConsumerStatefulWidget {
  const RoleCardContent({super.key});
  @override
  ConsumerState<RoleCardContent> createState() => _RoleCardContentState();
}

class _RoleCardContentState extends ConsumerState<RoleCardContent> {
  late final _presets = PresetCharactersLoader.load();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final conversations = ref.watch(conversationsProvider);
    return Column(
      children: [
        MoeSearchField(
          hintText: '搜索',
          onChanged: (value) => setState(() => _query = value),
        ),
        Expanded(
          child: conversations.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => MoeEmptyState(
              icon: Icons.error_outline,
              title: '角色加载失败',
              description: '$error',
            ),
            data: (items) => FutureBuilder<List<Conversation>>(
              future: _presets,
              builder: (context, snapshot) {
                final query = _query.trim().toLowerCase();
                final directory = {for (final role in items) role.id: role};
                for (final role in snapshot.data ?? <Conversation>[]) {
                  directory.putIfAbsent(role.id, () => role);
                }
                final roles = directory.values
                    .where((c) => c.displayName.toLowerCase().contains(query))
                    .toList(growable: false);
                if (roles.isEmpty) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return MoeEmptyState(
                    icon: Icons.search,
                    title: query.isEmpty ? '暂无角色' : '没有找到角色',
                  );
                }
                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: roles.length,
                  separatorBuilder: (_, __) => Divider(
                    height: borderWidth,
                    thickness: borderWidth,
                    indent: 72,
                    color: colors.divider,
                  ),
                  itemBuilder: (context, index) {
                    final role = roles[index];
                    final description = role.description?.trim();
                    return MoeListTile(
                      key: ValueKey('role-directory-${role.id}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
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
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.muted,
                              ),
                            )
                          : null,
                      onTap: () => openRoleChat(context, ref, role),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
