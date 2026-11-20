import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class DisplayRefreshRateController with WidgetsBindingObserver {
  DisplayRefreshRateController({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel('aicove/display_rate'),
      isSupported = !kIsWeb && (isAndroid ?? Platform.isAndroid);

  static final instance = DisplayRefreshRateController();
  static const _routePulse = Duration(milliseconds: 600);
  static const _cooldown = Duration(seconds: 1);

  final MethodChannel _channel;
  final bool isSupported;
  final _pointers = <int>{};
  Timer? _routeTimer;
  Timer? _cooldownTimer;
  bool _installed = false;
  bool _foreground = false;
  bool _scrolling = false;
  bool _high = false;

  void install() {
    if (!isSupported || _installed) return;
    final binding = WidgetsBinding.instance;
    _installed = true;
    _foreground =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void uninstall() {
    if (!_installed) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    WidgetsBinding.instance.removeObserver(this);
    _installed = false;
    _foreground = false;
    _reset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_installed) return;
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _reset();
  }

  void _onPointer(PointerEvent event) {
    if (!_foreground) return;
    if (event is PointerDownEvent || event is PointerPanZoomStartEvent) {
      _pointers.add(event.pointer);
      _requestHigh();
    } else if (event is PointerMoveEvent ||
        event is PointerPanZoomUpdateEvent) {
      _requestHigh();
      _scheduleCooldown();
    } else if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerPanZoomEndEvent) {
      if (_pointers.remove(event.pointer)) _scheduleCooldown();
    }
  }

  void onScrollNotification(ScrollNotification notification) {
    if (!_foreground) return;
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _scrolling = true;
      _requestHigh();
    } else if (notification is ScrollEndNotification) {
      _scrolling = false;
      _scheduleCooldown();
    }
  }

  void notifyRouteTransition() {
    if (!_foreground) return;
    _requestHigh();
    _routeTimer?.cancel();
    _routeTimer = Timer(_routePulse, () {
      _routeTimer = null;
      _scheduleCooldown();
    });
  }

  void _requestHigh() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _setHigh(true);
  }

  void _scheduleCooldown() {
    if (!_high || _pointers.isNotEmpty || _scrolling || _routeTimer != null) {
      return;
    }
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(_cooldown, () {
      _cooldownTimer = null;
      _setHigh(false);
    });
  }

  void _reset() {
    _pointers.clear();
    _scrolling = false;
    _routeTimer?.cancel();
    _routeTimer = null;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _setHigh(false);
  }

  void _setHigh(bool enabled) {
    if (_high == enabled) return;
    _high = enabled;
    unawaited(_applyHigh(enabled));
  }

  Future<void> _applyHigh(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setHighRefreshRate', {
        'enabled': enabled,
      });
    } on MissingPluginException catch (error) {
      debugPrint('Display refresh rate channel unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('Display refresh rate request failed: $error');
    }
  }
}
