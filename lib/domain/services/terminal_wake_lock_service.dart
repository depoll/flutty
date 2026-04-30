import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'diagnostics_log_service.dart';

/// Coordinates process-wide terminal wake-lock ownership.
class TerminalWakeLockService {
  final Set<int> _activeOwnerIds = <int>{};
  int _nextOwnerId = 0;
  bool _targetEnabled = false;
  bool _isEnabled = false;
  Future<void> _writeChain = Future<void>.value();

  /// Creates a unique owner ID for a terminal screen instance.
  int createOwner() => _nextOwnerId++;

  /// Marks whether [ownerId] currently needs the terminal wake lock.
  Future<void> setOwnerActive(int ownerId, {required bool active}) {
    final didChange = active
        ? _activeOwnerIds.add(ownerId)
        : _activeOwnerIds.remove(ownerId);
    if (!didChange) {
      return _writeChain;
    }
    return _sync();
  }

  /// Releases all wake-lock ownership for [ownerId].
  Future<void> releaseOwner(int ownerId) =>
      setOwnerActive(ownerId, active: false);

  /// Releases all owners and disables the wake lock.
  Future<void> dispose() {
    if (_activeOwnerIds.isEmpty) {
      return _writeChain;
    }
    _activeOwnerIds.clear();
    return _sync();
  }

  Future<void> _sync() => _setEnabled(enabled: _activeOwnerIds.isNotEmpty);

  Future<void> _setEnabled({required bool enabled}) async {
    if (_targetEnabled == enabled && _isEnabled == enabled) {
      return;
    }
    _targetEnabled = enabled;
    final nextWrite = _writeChain
        .catchError((Object error, StackTrace stackTrace) {
          _reportWakeLockError(error, stackTrace, enabled: _targetEnabled);
        })
        .then((_) async {
          final target = _targetEnabled;
          if (_isEnabled == target) {
            return;
          }

          try {
            await WakelockPlus.toggle(enable: target);
            _isEnabled = target;
          } on MissingPluginException catch (error, stackTrace) {
            _reportWakeLockError(error, stackTrace, enabled: target);
          } on PlatformException catch (error, stackTrace) {
            _reportWakeLockError(error, stackTrace, enabled: target);
          } on Object catch (error, stackTrace) {
            _reportWakeLockError(error, stackTrace, enabled: target);
          }
        });
    _writeChain = nextWrite;
    await nextWrite;
  }

  void _reportWakeLockError(
    Object error,
    StackTrace stackTrace, {
    required bool enabled,
  }) {
    DiagnosticsLogService.instance.error(
      'terminal',
      'wake_lock_failed',
      fields: {'enabled': enabled, 'errorType': error.runtimeType},
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'terminal',
        context: ErrorDescription(
          'while ${enabled ? 'enabling' : 'disabling'} the terminal wake lock',
        ),
      ),
    );
  }
}

/// Provider for [TerminalWakeLockService].
final terminalWakeLockServiceProvider = Provider<TerminalWakeLockService>((
  ref,
) {
  final service = TerminalWakeLockService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
