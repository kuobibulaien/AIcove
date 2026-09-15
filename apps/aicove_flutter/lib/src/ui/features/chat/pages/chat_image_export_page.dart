import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../features/chat/domain/message.dart';
import '../../../shared/widgets/index.dart';
import '../widgets/chat_image_export.dart';
import '../widgets/chat_message_list_media_save.dart';

class ChatImageExportPage extends StatefulWidget {
  const ChatImageExportPage({
    super.key,
    required this.messages,
    required this.title,
    required this.background,
    this.avatarUrl,
    this.wallpaper,
    this.wallpaperMaskOpacity = 0.8,
    this.wallpaperBlurSigma = 0,
  });

  final List<Message> messages;
  final String title;
  final String? avatarUrl;
  final Color background;
  final ImageProvider? wallpaper;
  final double wallpaperMaskOpacity;
  final double wallpaperBlurSigma;

  @override
  State<ChatImageExportPage> createState() => _ChatImageExportPageState();
}

class _ChatImageExportPageState extends State<ChatImageExportPage> {
  Uint8List? _bytes;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  Future<void> _render() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final bytes = await renderChatImage(
        context: context,
        messages: widget.messages,
        title: widget.title,
        avatarUrl: widget.avatarUrl,
        background: widget.background,
        wallpaper: widget.wallpaper,
        wallpaperMaskOpacity: widget.wallpaperMaskOpacity,
        wallpaperBlurSigma: widget.wallpaperBlurSigma,
      );
      if (mounted) setState(() => _bytes = bytes);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message.toString()
            : '图片生成失败，请重试',
      );
    }
  }

  Future<void> _save() async {
    if (_saving || _bytes == null) return;
    setState(() => _saving = true);
    try {
      await saveChatImageBytes(context, _bytes!);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => MoePageScaffold(
    backgroundColor: widget.background,
    body: SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('chat-export-scroll'),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      MoeFloatingSurface(
                        radius: 999,
                        child: IconButton(
                          tooltip: '返回',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: MoeFloatingSurface(
                          radius: 999,
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('导出图片', textAlign: TextAlign.center),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        MoeSecondaryButton(label: '重试', onPressed: _render),
                      ],
                    ),
                  )
                else if (_bytes == null)
                  const SizedBox(
                    height: 200,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  Image.memory(
                    _bytes!,
                    key: const ValueKey('chat-export-preview'),
                    semanticLabel: '${widget.messages.length} 条消息的导出图片',
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: MoeFloatingSurface(
                    radius: 999,
                    child: TextButton(
                      key: const ValueKey('chat-export-save'),
                      onPressed: _bytes == null || _saving ? null : _save,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(_saving ? '保存中…' : '保存图片'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
