import 'stages.dart';
import 'types.dart';

/// Replaces registered secret values (API keys, tokens) in text bound for the
/// model. A safety net only: tools must still never return secrets.
class SecretRedactor {
  static const mask = '［已隐藏］';

  final Set<String> _secrets = {};

  /// Every registered value is masked, however short; blank values are not
  /// registered. Callers register real credentials only.
  void register(String secret) {
    final value = secret.trim();
    if (value.isNotEmpty) _secrets.add(value);
  }

  void unregister(String secret) => _secrets.remove(secret.trim());

  String redact(String text) {
    if (_secrets.isEmpty || text.isEmpty) return text;
    final ordered = _secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var out = text;
    for (final secret in ordered) {
      out = out.replaceAll(secret, mask);
    }
    return out;
  }
}

/// ⑦ decorator that redacts [KernelToolResult.content] before it reaches the
/// model. Rewritten results discard images and carry an explicit marker so
/// the continuation cannot restore unredacted fields from an opaque payload.
class RedactingToolExecutor implements ToolBatchExecutor {
  RedactingToolExecutor(this._inner, this._redactor);

  final ToolBatchExecutor _inner;
  final SecretRedactor _redactor;

  @override
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx) =>
      _inner.modeFor(calls, ctx);

  @override
  Future<KernelToolResult> executeOne(
    KernelToolCall call,
    TurnContext ctx,
  ) async {
    final result = await _inner.executeOne(call, ctx);
    final content = _redactor.redact(result.content);
    if (content == result.content) return result;
    return KernelToolResult(
      callId: result.callId,
      name: result.name,
      content: content,
      isError: result.isError,
      payload: result.payload,
      terminationReason: result.terminationReason,
      outputRewritten: true,
    );
  }
}
