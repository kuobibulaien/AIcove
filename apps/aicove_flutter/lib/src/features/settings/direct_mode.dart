import 'package:shared_preferences/shared_preferences.dart';

class DirectConfig {
  final bool enabled;
  final String apiBase;
  final String apiKey;
  final String model;

  const DirectConfig({
    required this.enabled,
    required this.apiBase,
    required this.apiKey,
    required this.model,
  });
}

const _kDirectEnabled = 'direct.enable';
const _kDirectApiBase = 'direct.api_base';
const _kDirectApiKey = 'direct.api_key';
const _kDirectModel = 'direct.model';

Future<DirectConfig> loadDirectConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool(_kDirectEnabled) ?? true; // 默认开启（KISS）
  final apiBase = prefs.getString(_kDirectApiBase) ?? 'https://api.openai.com/v1';
  final apiKey = prefs.getString(_kDirectApiKey) ?? '';
  final model = prefs.getString(_kDirectModel) ?? 'gpt-4o-mini';
  return DirectConfig(enabled: enabled, apiBase: apiBase, apiKey: apiKey, model: model);
}

Future<void> setDirectEnabled(bool v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kDirectEnabled, v);
}

Future<void> setDirectApiBase(String v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kDirectApiBase, v.trim());
}

Future<void> setDirectApiKey(String v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kDirectApiKey, v.trim());
}

Future<void> setDirectModel(String v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kDirectModel, v.trim());
}

