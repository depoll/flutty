mixin Observable {
  final _listeners = <void Function()>{};

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    // Snapshot the set so callbacks can safely add or remove listeners.
    for (var listener in List.of(_listeners)) {
      listener();
    }
  }
}
