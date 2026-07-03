import 'dart:async';

/// A counting semaphore that bounds how many asynchronous operations may run
/// concurrently. Used to throttle image decodes so a burst of Kitty graphics
/// transmissions (e.g. a window-switch replay) cannot start dozens of decodes
/// at once and exhaust memory.
class AsyncSemaphore {
  AsyncSemaphore(this._permits) : assert(_permits > 0);

  int _permits;
  final List<Completer<void>> _waiters = [];

  /// Acquires a permit, waiting if none are currently available.
  Future<void> acquire() {
    if (_permits > 0) {
      _permits -= 1;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Releases a permit, waking the longest-waiting acquirer if any.
  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _permits += 1;
    }
  }
}
