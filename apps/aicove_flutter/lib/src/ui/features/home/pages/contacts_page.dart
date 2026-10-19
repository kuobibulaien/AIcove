import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/contacts_list_content.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../character/pages/role_card_page.dart';

/// Chat list. Searching shows matching roles (including preset roles not
/// chatted with yet) and chat records across all conversations.
class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Scaffold(
      backgroundColor: MoeSurfaceGroup.contains(context)
          ? Colors.transparent
          : colors.surface,
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '聊天',
        centerTitle: true,
        bottom: MoeSearchField(
          hintText: '搜索',
          onChanged: (value) => setState(() => _query = value),
        ),
        bottomHeight: MoeSearchField.heightFor(context),
        actions: [
          MoeIconButton(
            icon: Icons.person_add_alt_1_outlined,
            tooltip: '新建聊天',
            onTap: () => MoeWorkspace.openLocation(context, '/contact/new'),
          ),
        ],
      ),
      body: _query.trim().isEmpty
          ? ContactsListContent(
              sortMode: ref.watch(sortModeProvider),
              isAscending: ref.watch(sortAscendingProvider),
            )
          : RoleCardContent(query: _query),
    );
  }
}
