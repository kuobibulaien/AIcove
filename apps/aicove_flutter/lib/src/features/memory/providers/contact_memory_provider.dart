import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/markdown_contact_memory_store.dart';
import '../domain/contact_memory_port.dart';

final contactMemoryPortProvider = Provider<ContactMemoryPort>((ref) {
  return MarkdownContactMemoryStore(() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'contact_memories'));
  });
});
