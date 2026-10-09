import 'dart:async';

/// Typed key for a service registered in a [KernelScope].
class ServiceKey<T> {
  const ServiceKey(this.name);
  final String name;

  @override
  String toString() => 'ServiceKey<$T>($name)';
}

/// Handle returned by every registration; [revoke] undoes it once.
class Registration {
  Registration._(this.owner, this._undo);

  final String owner;
  final void Function() _undo;
  bool _revoked = false;

  bool get isRevoked => _revoked;

  void revoke() {
    if (_revoked) return;
    _revoked = true;
    _undo();
  }
}

/// Hierarchical resource scope. Services resolve child-first; [dispose]
/// releases children, then revokes registrations and closes resources in
/// reverse order, exactly once, even if some closers throw.
class KernelScope {
  KernelScope({KernelScope? parent}) : _parent = parent {
    parent?._children.add(this);
  }

  final KernelScope? _parent;
  final List<KernelScope> _children = [];
  final Map<ServiceKey<Object?>, Object?> _services = {};
  final List<Registration> _registrations = [];
  final List<FutureOr<void> Function()> _closers = [];
  bool _disposed = false;

  bool get isDisposed => _disposed;

  KernelScope child() {
    _checkAlive();
    return KernelScope(parent: this);
  }

  Registration provide<T>(ServiceKey<T> key, T service, {String owner = ''}) {
    _checkAlive();
    if (_services.containsKey(key)) {
      throw StateError('服务已注册：$key');
    }
    _services[key] = service;
    return track(owner, () => _services.remove(key));
  }

  T? lookup<T>(ServiceKey<T> key) {
    if (_services.containsKey(key)) return _services[key] as T;
    return _parent?.lookup(key);
  }

  T require<T>(ServiceKey<T> key) {
    final value = lookup(key);
    if (value == null) throw StateError('缺少服务：$key');
    return value;
  }

  /// Records an arbitrary registration so it is revoked on dispose.
  Registration track(String owner, void Function() undo) {
    _checkAlive();
    final registration = Registration._(owner, undo);
    _registrations.add(registration);
    return registration;
  }

  /// Registers a resource closer, run on dispose.
  void addCloser(FutureOr<void> Function() close) {
    _checkAlive();
    _closers.add(close);
  }

  /// Revokes every registration made by [owner] in this scope.
  void revokeOwner(String owner) {
    for (final registration in _registrations) {
      if (registration.owner == owner) registration.revoke();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Object? firstError;
    StackTrace? firstStack;
    for (final child in List.of(_children.reversed)) {
      try {
        await child.dispose();
      } catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
      }
    }
    for (final registration in _registrations.reversed) {
      registration.revoke();
    }
    for (final close in _closers.reversed) {
      try {
        await close();
      } catch (e, s) {
        firstError ??= e;
        firstStack ??= s;
      }
    }
    _parent?._children.remove(this);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  void _checkAlive() {
    if (_disposed) throw StateError('作用域已释放');
  }
}
