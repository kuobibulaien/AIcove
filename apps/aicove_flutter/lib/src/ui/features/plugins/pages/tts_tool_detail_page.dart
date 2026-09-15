import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/mcp_api.dart';
import '../../../shared/widgets/index.dart';

class TtsToolDetailPage extends ConsumerStatefulWidget {
  const TtsToolDetailPage({super.key});

  @override
  ConsumerState<TtsToolDetailPage> createState() => _TtsToolDetailPageState();
}

class _TtsToolDetailPageState extends ConsumerState<TtsToolDetailPage>
    with MoeAutoSaveState<TtsToolDetailPage> {
  final McpApi _api = McpApi();

  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _requestUrlCtrl = TextEditingController();
  final TextEditingController _audioUrlCtrl = TextEditingController();
  final TextEditingController _promptTextCtrl = TextEditingController();
  final TextEditingController _speedCtrl = TextEditingController();
  final TextEditingController _testTextCtrl = TextEditingController(
    text: '你好，这是一个 TTS 连通性测试。',
  );

  bool _loading = true;
  bool _testing = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _requestUrlCtrl.dispose();
    _audioUrlCtrl.dispose();
    _promptTextCtrl.dispose();
    _speedCtrl.dispose();
    _testTextCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final response = await _api.fetchTtsConfig();
      final config = response.config;
      final defaults = response.defaults;

      _apiKeyCtrl.text = config.apiKey.isNotEmpty
          ? config.apiKey
          : defaults.apiKey;
      _requestUrlCtrl.text = config.requestUrl.isNotEmpty
          ? config.requestUrl
          : defaults.requestUrl;
      _audioUrlCtrl.text = config.promptAudioUrl.isNotEmpty
          ? config.promptAudioUrl
          : defaults.promptAudioUrl;
      _promptTextCtrl.text = config.promptText.isNotEmpty
          ? config.promptText
          : defaults.promptText;
      final speed = config.speed ?? defaults.speed;
      _speedCtrl.text = speed?.toString() ?? '';
      autoSave.configure(
        save: _save,
        snapshot: () => moeAutoSaveSignature([
          for (final c in [
            _apiKeyCtrl,
            _requestUrlCtrl,
            _audioUrlCtrl,
            _promptTextCtrl,
            _speedCtrl,
          ])
            c.text,
        ]),
        fields: [
          _apiKeyCtrl,
          _requestUrlCtrl,
          _audioUrlCtrl,
          _promptTextCtrl,
          _speedCtrl,
        ],
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  double? _parseSpeed() {
    final text = _speedCtrl.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || value <= 0) {
      throw const FormatException('语速必须是大于 0 的数字');
    }
    return value;
  }

  TtsToolConfigDto _buildDto(double? speed) {
    return TtsToolConfigDto(
      apiKey: _apiKeyCtrl.text.trim(),
      requestUrl: _requestUrlCtrl.text.trim(),
      promptAudioUrl: _audioUrlCtrl.text.trim(),
      promptText: _promptTextCtrl.text.trim(),
      speed: speed,
    );
  }

  Future<void> _save() async {
    await _api.updateTtsConfig(_buildDto(_parseSpeed()));
  }

  Future<void> _test() async {
    final text = _testTextCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先输入测试文本')));
      return;
    }

    setState(() {
      _testing = true;
      _result = null;
    });

    try {
      final resp = await _api.testTts(text);
      if (resp.audioUrl.isEmpty) {
        throw Exception('接口未返回音频地址');
      }

      setState(() {
        _result = '测试成功，音频地址: ${resp.audioUrl}';
      });
    } catch (e) {
      setState(() {
        _result = '测试失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return autoSavePage(
      MoePageScaffold(
        appBar: AppBar(title: const Text('TTS 工具设置')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _apiKeyCtrl,
                    obscureText: false,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _requestUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: '请求地址',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _audioUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: '参考音频 URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _speedCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: '语速(可选)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _promptTextCtrl,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '提示词',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 32),
                  TextField(
                    controller: _testTextCtrl,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '测试文本',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow_outlined),
                    label: const Text('测试 TTS'),
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 12),
                    Text(_result!),
                  ],
                ],
              ),
      ),
    );
  }
}
