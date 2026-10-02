import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/contacts_list_content.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class ContactsPage extends ConsumerWidget {
  const ContactsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    return Scaffold(
      backgroundColor: MoeSurfaceGroup.contains(context)
          ? Colors.transparent
          : colors.surface,
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '聊天',
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: '新建聊天',
            onPressed: () => MoeWorkspace.openLocation(context, '/contact/new'),
          ),
        ],
      ),
      body: ContactsListContent(
        sortMode: ref.watch(sortModeProvider),
        isAscending: ref.watch(sortAscendingProvider),
      ),
    );
  }
}
