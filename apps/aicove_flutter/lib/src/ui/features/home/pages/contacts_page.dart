import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/contacts_list_content.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

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
          onChanged: (query) => setState(() => _query = query),
        ),
        bottomHeight: MoeSearchField.heightFor(context),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: '新建聊天',
            onPressed: () => MoeWorkspace.openLocation(context, '/contact/new'),
          ),
        ],
      ),
      body: ContactsListContent(
        searchQuery: _query,
        sortMode: ref.watch(sortModeProvider),
        isAscending: ref.watch(sortAscendingProvider),
      ),
    );
  }
}
