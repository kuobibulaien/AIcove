import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../sheets/moe_bottom_sheet.dart';
import 'moe_text_field.dart';

/// Debounces edits and serializes writes. Failed edits remain pending for retry.
class MoeAutoSaveController extends ChangeNotifier {
  MoeAutoSaveController({this.delay = const Duration(milliseconds: 450)});

  final Duration delay;
  Future<void> Function()? _save;
  Object? Function()? _snapshot;
  Object? _observed;
  int _revision = 0, _savedRevision = 0;
  int _epoch = 0;
  Timer? _timer;
  Future<bool>? _running;
  bool _disposed = false;
  Object? error;
  List<TextEditingController> _fields = [];

  bool get pending => _revision != _savedRevision;
  bool get saving => _running != null;
  bool get composing => _fields
      .any((c) => c.value.composing.isValid && !c.value.composing.isCollapsed);

  void configure({
    required Future<void> Function() save,
    required Object? Function() snapshot,
    Iterable<TextEditingController> fields = const [],
  }) {
    _epoch++;
    _timer?.cancel();
    for (final field in _fields) {
      field.removeListener(changed);
    }
    _save = save;
    _snapshot = snapshot;
    _observed = snapshot();
    _revision = _savedRevision = 0;
    error = null;
    _fields = fields.toList();
    for (final field in _fields) {
      field.addListener(changed);
    }
  }

  void changed() {
    if (_disposed || _snapshot == null) return;
    final next = _snapshot!();
    if (next != _observed) {
      _observed = next;
      _revision++;
      error = null;
      notifyListeners();
    }
    _timer?.cancel();
    if (pending && !composing) _timer = Timer(delay, flush);
  }

  Future<bool> flush() {
    _timer?.cancel();
    if (_disposed) return Future.value(false);
    if (_running != null) return _running!;
    if (!pending) return Future.value(true);
    if (composing) return Future.value(false);
    // Assign the future before invoking the writer, which may notify listeners.
    final completion = Completer<bool>();
    _running = completion.future;
    notifyListeners();
    unawaited(_drain(completion));
    return completion.future;
  }

  Future<void> _drain(Completer<bool> completion) async {
    var success = true;
    try {
      while (!_disposed && pending) {
        if (composing) {
          success = false;
          break;
        }
        final revision = _revision;
        final epoch = _epoch;
        try {
          await _save!();
        } catch (failure) {
          // An edit made during a failed write still gets its own attempt.
          if (_epoch != epoch || _revision != revision) continue;
          rethrow;
        }
        if (_epoch != epoch) continue;
        _savedRevision = revision;
        error = null;
      }
    } catch (failure) {
      error = failure;
      success = false;
    } finally {
      _running = null;
      if (!_disposed) notifyListeners();
      completion.complete(success && !pending);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final field in _fields) {
      field.removeListener(changed);
    }
    super.dispose();
  }
}

/// Tracks form state changes as well as registered text controllers.
mixin MoeAutoSaveState<T extends StatefulWidget> on State<T> {
  final autoSave = MoeAutoSaveController();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    autoSave.changed();
  }

  Widget autoSavePage(Widget child) =>
      MoeAutoSaveScope(controller: autoSave, child: child);

  @override
  void dispose() {
    autoSave.dispose();
    super.dispose();
  }
}

String moeAutoSaveSignature(Object? value) => jsonEncode(value);

/// Flushes before returning and exposes errors without discarding the form.
class MoeAutoSaveScope extends StatefulWidget {
  const MoeAutoSaveScope(
      {super.key, required this.controller, required this.child});
  final MoeAutoSaveController controller;
  final Widget child;

  @override
  State<MoeAutoSaveScope> createState() => _MoeAutoSaveScopeState();
}

class _MoeAutoSaveScopeState extends State<MoeAutoSaveScope>
    with WidgetsBindingObserver
    implements PopEntry<Object?> {
  bool _leaving = false;
  ModalRoute<Object?>? _route;
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(true);

  void _syncCanPop() {
    canPopNotifier.value =
        !widget.controller.pending && !widget.controller.saving;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_syncCanPop);
    _syncCanPop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    _route?.unregisterPopEntry(this);
    _route = route;
    _route?.registerPopEntry(this);
  }

  @override
  void didUpdateWidget(covariant MoeAutoSaveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncCanPop);
      widget.controller.addListener(_syncCanPop);
      _syncCanPop();
    }
  }

  @override
  void onPopInvoked(bool didPop) {}

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) _leave(result);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) widget.controller.flush();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _route?.unregisterPopEntry(this);
    widget.controller.removeListener(_syncCanPop);
    canPopNotifier.dispose();
    super.dispose();
  }

  Future<void> _leave(Object? result) async {
    if (_leaving) return;
    _leaving = true;
    FocusScope.of(context).unfocus();
    final saved = await widget.controller.flush();
    if (mounted && saved) {
      await Navigator.of(context).maybePop(result);
    }
    _leaving = false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: widget.child),
          if (widget.controller.error != null)
            Material(
              color: context.moeColors.surfaceAlt,
              child: SafeArea(
                  top: false,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      Expanded(
                          child: Text(widget.controller.error is FormatException
                              ? (widget.controller.error as FormatException)
                                  .message
                              : '自动保存失败，修改已保留，请重试。')),
                      TextButton(
                          onPressed: widget.controller.saving
                              ? null
                              : () => widget.controller.flush(),
                          child: const Text('重试')),
                    ]),
                  )),
            ),
        ]),
      );
}

class MoeAutoSaveForm extends StatefulWidget {
  const MoeAutoSaveForm(
      {super.key,
      required this.save,
      required this.snapshot,
      this.fields = const [],
      this.disposeFields = false,
      required this.builder});
  final Future<void> Function() save;
  final Object? Function() snapshot;
  final List<TextEditingController> fields;

  /// Transfers ownership of modal-local controllers to the form.
  final bool disposeFields;
  final Widget Function(BuildContext, StateSetter) builder;

  @override
  State<MoeAutoSaveForm> createState() => _MoeAutoSaveFormState();
}

class _MoeAutoSaveFormState extends State<MoeAutoSaveForm>
    with MoeAutoSaveState<MoeAutoSaveForm> {
  @override
  void initState() {
    super.initState();
    autoSave.configure(
        save: () => widget.save(),
        snapshot: () => widget.snapshot(),
        fields: widget.fields);
  }

  @override
  void dispose() {
    if (widget.disposeFields) {
      for (final field in widget.fields) {
        field.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      autoSavePage(widget.builder(context, setState));
}

Future<void> showMoeAutoSaveTextEditor({
  required BuildContext context,
  required String title,
  required String initialValue,
  required Future<void> Function(String) onSave,
  String? hint,
  TextInputType? keyboardType,
  int maxLines = 1,
  bool obscureText = false,
}) =>
    showMoeBottomSheet<void>(
      context: context,
      title: title,
      showCloseButton: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _AutoSaveTextEditor(
          initialValue: initialValue,
          onSave: onSave,
          hint: hint,
          keyboardType: keyboardType,
          maxLines: maxLines,
          obscureText: obscureText),
    );

class _AutoSaveTextEditor extends StatefulWidget {
  const _AutoSaveTextEditor(
      {required this.initialValue,
      required this.onSave,
      this.hint,
      this.keyboardType,
      required this.maxLines,
      required this.obscureText});
  final String initialValue;
  final Future<void> Function(String) onSave;
  final String? hint;
  final TextInputType? keyboardType;
  final int maxLines;
  final bool obscureText;
  @override
  State<_AutoSaveTextEditor> createState() => _AutoSaveTextEditorState();
}

class _AutoSaveTextEditorState extends State<_AutoSaveTextEditor>
    with MoeAutoSaveState<_AutoSaveTextEditor> {
  late final _text = TextEditingController(text: widget.initialValue);
  @override
  void initState() {
    super.initState();
    autoSave.configure(
        save: () => widget.onSave(_text.text),
        snapshot: () => _text.text,
        fields: [_text]);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => autoSavePage(SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: MoeTextField(
            controller: _text,
            hint: widget.hint,
            autofocus: true,
            maxLines: widget.maxLines,
            obscureText: widget.obscureText,
            keyboardType: widget.keyboardType),
      ));
}
