import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../settings/mcp_api.dart';
import '../../../tts/tts_player.dart';

class TtsToolDetailPage extends ConsumerStatefulWidget {
  const TtsToolDetailPage({super.key});

  @override
  ConsumerState<TtsToolDetailPage> createState() => _TtsToolDetailPageState();
}

class _TtsToolDetailPageState extends ConsumerState<TtsToolDetailPage> {
  final McpApi _api = McpApi();

  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _audioUrlCtrl = TextEditingController();
  final TextEditingController _promptTextCtrl = TextEditingController();
  final TextEditingController _requestUrlCtrl = TextEditingController();
  final TextEditingController _speedCtrl = TextEditingController();
  final TextEditingController _testTextCtrl = TextEditingController(text: '你好呀，这是一段语音测试。');

  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _presetBusy = false;
  String? _lastResult;
  TtsToolConfigResponseDto? _response;
  List<TtsPresetDto> _presets = const <TtsPresetDto>[];
  String? _selectedPresetId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _audioUrlCtrl.dispose();
    _promptTextCtrl.dispose();
    _requestUrlCtrl.dispose();
    _speedCtrl.dispose();
    _testTextCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final res = await _api.fetchTtsConfig();
      if (!mounted) return;
      setState(() {
        _syncResponse(res);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e'), duration: const Duration(seconds: 1)));
      setState(() {
        _loading = false;
      });
    }
  }

  void _syncResponse(TtsToolConfigResponseDto res) {
    _response = res;
    _presets = res.presets;
    if (_presets.isEmpty) {
      _selectedPresetId = null;
    } else if (_selectedPresetId == null || !_presets.any((p) => p.id == _selectedPresetId)) {
      _selectedPresetId = _presets.first.id;
    }
    _applyConfigToFields(res.config);
    _loading = false;
  }

  void _applyConfigToFields(TtsToolConfigDto config) {
    final defaults = _response?.defaults;
    _apiKeyCtrl.text = config.apiKey.isNotEmpty
        ? config.apiKey
        : (defaults?.apiKey ?? '');
    _audioUrlCtrl.text = config.promptAudioUrl.isNotEmpty
        ? config.promptAudioUrl
        : (defaults?.promptAudioUrl ?? '');
    _promptTextCtrl.text = config.promptText.isNotEmpty
        ? config.promptText
        : (defaults?.promptText ?? '');
    _requestUrlCtrl.text = config.requestUrl.isNotEmpty
        ? config.requestUrl
        : (defaults?.requestUrl ?? '');
    final double? speed = config.speed ?? defaults?.speed;
    _speedCtrl.text = speed == null ? '' : speed.toString();
  }

  TtsPresetDto? _findPreset(String? id) {
    if (id == null) return null;
    for (final preset in _presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  double? _parseSpeedInput() {
    final raw = _speedCtrl.text.trim();
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      throw const FormatException('语速必须是大于 0 的数字');
    }
    return value;
  }

  TtsToolConfigDto _buildConfigDto(double? speed) {
    return TtsToolConfigDto(
      apiKey: _apiKeyCtrl.text.trim(),
      promptAudioUrl: _audioUrlCtrl.text.trim(),
      promptText: _promptTextCtrl.text.trim(),
      requestUrl: _requestUrlCtrl.text.trim(),
      speed: speed,
    );
  }

  Future<void> _save() async {
    double? speed;
    try {
      speed = _parseSpeedInput();
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), duration: const Duration(seconds: 1)));
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      final dto = _buildConfigDto(speed);
      final res = await _api.updateTtsConfig(dto);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _syncResponse(res);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('音色配置已保存'), duration: Duration(seconds: 1)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 1)));
      setState(() {
        _saving = false;
      });
    }
  }

  Future<void> _savePresetDialog() async {
    double? speed;
    try {
      speed = _parseSpeedInput();
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), duration: const Duration(seconds: 1)));
      return;
    }

    final TextEditingController nameCtrl = TextEditingController(text: '我的预设${_presets.length}');
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('保存为预设'),
          content: TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(labelText: '预设名称'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(nameCtrl.text.trim()), child: const Text('保存')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) {
      nameCtrl.dispose();
      return;
    }

    setState(() {
      _presetBusy = true;
    });
    try {
      final res = await _api.createTtsPreset(name: name, dto: _buildConfigDto(speed));
      if (!mounted) return;
      setState(() {
        _presetBusy = false;
        _syncResponse(res);
        if (_presets.isNotEmpty) {
          _selectedPresetId = _presets.last.id;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存预设"$name"'), duration: const Duration(seconds: 1)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存预设失败: $e'), duration: const Duration(seconds: 1)));
      setState(() {
        _presetBusy = false;
      });
    }
    nameCtrl.dispose();
  }

  Future<void> _deletePreset(String presetId) async {
    final preset = _findPreset(presetId);
    if (preset == null || preset.builtin) {
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除预设'),
            content: Text('确定删除预设“${preset.name}”吗？'),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    setState(() {
      _presetBusy = true;
    });
    try {
      final res = await _api.deleteTtsPreset(presetId);
      if (!mounted) return;
      setState(() {
        _presetBusy = false;
        _syncResponse(res);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('预设"\${preset.name}"已删除'), duration: const Duration(seconds: 1)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败: $e'), duration: const Duration(seconds: 1)));
      setState(() {
        _presetBusy = false;
      });
    }
  }

  Future<void> _test() async {
    final text = _testTextCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先输入测试文本'), duration: Duration(seconds: 1)));
      return;
    }
    setState(() {
      _testing = true;
      _lastResult = null;
    });
    try {
      final resp = await _api.testTts(text);
      if (resp.audioUrl.isEmpty) {
        throw Exception('接口返回为空');
      }
      final player = ref.read(ttsPlayerProvider);
      await player.playUrl(resp.audioUrl);
      if (!mounted) return;
      setState(() {
        _lastResult = '测试成功，音频已播放${resp.cached ? "（命中缓存）" : ""}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastResult = '测试失败: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('测试失败: $e'), duration: const Duration(seconds: 1)));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('TTS 工具详情'),
        backgroundColor: moeSurface,
        foregroundColor: moeText,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(borderWidth),
          child: Divider(height: 0, color: moeBorderLight),
        ),
      ),
      backgroundColor: moeSurface,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _buildInfoCard(),
                const SizedBox(height: 16),
                _buildTestCard(),
              ],
            ),
    );
  }

  Widget _buildInfoCard() {
    final defaults = _response?.defaults;
    final selectedPreset = _findPreset(_selectedPresetId);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: moeBorderLight, width: borderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('音色配置', style: TextStyle(fontWeight: FontWeight.w700, color: moeText)),
            const SizedBox(height: 12),
            if (_presets.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedPresetId,
                      decoration: const InputDecoration(
                        labelText: '选择预设',
                        border: OutlineInputBorder(),
                      ),
                      items: _presets
                          .map(
                            (preset) => DropdownMenuItem<String>(
                              value: preset.id,
                              child: Text('${preset.name}${preset.builtin ? "（内置）" : ''}'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        final preset = _findPreset(value);
                        if (preset == null) return;
                        setState(() {
                          _selectedPresetId = value;
                          _applyConfigToFields(preset.config);
                        });
                      },
                    ),
                  ),
                  if (selectedPreset != null && !selectedPreset.builtin)
                    IconButton(
                      tooltip: '删除预设',
                      onPressed: _presetBusy ? null : () => _deletePreset(selectedPreset.id),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _apiKeyCtrl,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: defaults?.apiKey ?? '',
                border: const OutlineInputBorder(),
                helperText: '请填写 TTS 服务的 API Key',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _audioUrlCtrl,
              decoration: InputDecoration(
                labelText: '音频文件 URL',
                hintText: defaults?.promptAudioUrl ?? '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _requestUrlCtrl,
              decoration: InputDecoration(
                labelText: '请求地址（可选）',
                hintText: defaults?.requestUrl ?? '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _speedCtrl,
              decoration: InputDecoration(
                labelText: '默认语速（倍速，可选）',
                hintText: defaults?.speed?.toString() ?? '1.0',
                suffixText: 'x',
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptTextCtrl,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: '提示词（引导模型模仿音色）',
                hintText: defaults?.promptText ?? '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: (_saving || _presetBusy) ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存音色设置'),
                ),
                if (defaults != null)
                  TextButton.icon(
                    onPressed: (_saving || _presetBusy)
                        ? null
                        : () {
                            _applyConfigToFields(defaults);
                          },
                    icon: const Icon(Icons.settings_backup_restore),
                    label: const Text('恢复默认'),
                  ),
                TextButton.icon(
                  onPressed: (_saving || _presetBusy) ? null : _savePresetDialog,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('保存为预设'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestCard() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: moeBorderLight, width: borderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('联通性测试', style: TextStyle(fontWeight: FontWeight.w700, color: moeText)),
            const SizedBox(height: 8),
            const Text('输入一句话，点击“生成语音”验证当前音色是否可用。', style: TextStyle(color: moeTextSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: _testTextCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '测试文本',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow_outlined),
              label: const Text('生成语音并播放'),
            ),
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              Text(
                _lastResult!,
                style: TextStyle(color: _lastResult!.startsWith('测试失败') ? Colors.redAccent : moeTextSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
