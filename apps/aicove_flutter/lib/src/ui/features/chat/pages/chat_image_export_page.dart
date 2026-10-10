import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../features/chat/domain/message.dart';
import '../../../shared/widgets/index.dart';
import '../widgets/chat_image_export.dart';
import '../widgets/chat_message_list_media_save.dart';

/// Previews the long image live and rasterizes that same canvas on save.
class ChatImageExportPage extends StatefulWidget {
  const ChatImageExportPage({
    super.key,
    required this.messages,
    required this.title,
    required this.background,
    required this.chatSize,
    this.avatarUrl,
    this.characterImage,
    this.showBackButton = false,
    this.documentStyle = false,
  });

  final List<Message> messages;
  final String title;
  final String? avatarUrl;
  final String? characterImage;

  /// Chat background as the chat page paints it behind one screen.
  final Widget background;

  /// Size of the chat page: the export width and one background tile.
  final Size chatSize;
  final bool showBackButton;

  /// 与聊天页当前样式一致（ADR0047），文档模式导出无气泡的 Markdown 正文。
  final bool documentStyle;

  @override
  State<ChatImageExportPage> createState() => _ChatImageExportPageState();
}

class _ChatImageExportPageState extends State<ChatImageExportPage> {
  final _canvasKey = GlobalKey();
  bool _ready = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    final root = _canvasKey.currentContext;
    if (root == null) return;
    try {
      await waitForChatExportImages(root);
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      // Late or failed images keep their placeholder, as in the chat.
      if (mounted) {
        setState(() {
          _error = _describe(error);
          _ready = true;
        });
      }
    }
  }

  String _describe(Object error) =>
      error is StateError ? error.message.toString() : '图片生成失败，请重试';

  Future<void> _save() async {
    final boundary = _canvasKey.currentContext?.findRenderObject();
    if (_saving || !_ready || boundary is! RenderRepaintBoundary) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final bytes = await captureChatExportImage(
        boundary,
        pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(2.0, 3.0),
      );
      if (mounted) await saveChatImageBytes(context, bytes);
    } catch (error) {
      if (mounted) setState(() => _error = _describe(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => MoePageScaffold(
    body: SafeArea(
      child: Column(
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
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('chat-export-scroll'),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: widget.chatSize.width,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: FittedBox(
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topCenter,
                      child: RepaintBoundary(
                        key: _canvasKey,
                        child: Semantics(
                          label: '${widget.messages.length} 条消息的导出图片',
                          child: ChatExportCanvas(
                            key: const ValueKey('chat-export-preview'),
                            messages: widget.messages,
                            title: widget.title,
                            avatarUrl: widget.avatarUrl,
                            characterImage: widget.characterImage,
                            background: widget.background,
                            width: widget.chatSize.width,
                            screenHeight: widget.chatSize.height,
                            showBackButton: widget.showBackButton,
                            documentStyle: widget.documentStyle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: MoeFloatingSurface(
              radius: 999,
              child: TextButton(
                key: const ValueKey('chat-export-save'),
                onPressed: !_ready || _saving ? null : _save,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    !_ready && _error == null
                        ? '图片加载中…'
                        : _saving
                        ? '保存中…'
                        : '保存图片',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
