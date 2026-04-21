import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quick_actions/quick_actions.dart';

import '../../data/database/database.dart';
import 'settings_service.dart';

/// Prefix used for host-specific home-screen shortcut payloads.
const homeScreenShortcutHostTypePrefix = 'host:';

/// Maximum number of hosts surfaced in the app icon's quick actions.
const maxHomeScreenShortcutItems = 4;

bool get _supportsHomeScreenShortcuts =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Builds the platform shortcut payload for a host ID.
String buildHomeScreenShortcutHostType(int hostId) {
  if (hostId <= 0) {
    throw ArgumentError.value(hostId, 'hostId', 'Must be positive.');
  }
  return '$homeScreenShortcutHostTypePrefix$hostId';
}

/// Parses a host ID from a platform shortcut payload.
int? parseHomeScreenShortcutHostId(Object? shortcutType) {
  if (shortcutType is! String) {
    return null;
  }
  final normalizedShortcutType = shortcutType.trim();
  if (!normalizedShortcutType.startsWith(homeScreenShortcutHostTypePrefix)) {
    return null;
  }

  final hostId = int.tryParse(
    normalizedShortcutType.substring(homeScreenShortcutHostTypePrefix.length),
  );
  if (hostId == null || hostId <= 0) {
    return null;
  }
  return hostId;
}

/// Parses the stored pinned home-screen shortcut host IDs.
Set<int> parsePinnedHomeScreenShortcutHostIds(String? rawValue) {
  final normalizedRawValue = rawValue?.trim();
  if (normalizedRawValue == null || normalizedRawValue.isEmpty) {
    return <int>{};
  }

  try {
    final decodedValue = jsonDecode(normalizedRawValue);
    if (decodedValue is! List<Object?>) {
      return <int>{};
    }

    final hostIds = <int>{};
    for (final entry in decodedValue) {
      final hostId = switch (entry) {
        final int value => value,
        final String value => int.tryParse(value),
        _ => null,
      };
      if (hostId != null && hostId > 0) {
        hostIds.add(hostId);
      }
    }
    return hostIds;
  } on FormatException {
    return <int>{};
  }
}

int _compareNullableDateTimesDescending(DateTime? left, DateTime? right) {
  if (identical(left, right)) {
    return 0;
  }
  if (left == null) {
    return 1;
  }
  if (right == null) {
    return -1;
  }
  return right.compareTo(left);
}

/// Compares two hosts for home-screen shortcut priority.
int compareHomeScreenShortcutHosts(
  Host left,
  Host right, {
  required Set<int> pinnedHostIds,
}) {
  final leftPinned = pinnedHostIds.contains(left.id);
  final rightPinned = pinnedHostIds.contains(right.id);
  if (leftPinned != rightPinned) {
    return leftPinned ? -1 : 1;
  }

  if (left.isFavorite != right.isFavorite) {
    return left.isFavorite ? -1 : 1;
  }

  final lastConnectedComparison = _compareNullableDateTimesDescending(
    left.lastConnectedAt,
    right.lastConnectedAt,
  );
  if (lastConnectedComparison != 0) {
    return lastConnectedComparison;
  }

  final sortOrderComparison = left.sortOrder.compareTo(right.sortOrder);
  if (sortOrderComparison != 0) {
    return sortOrderComparison;
  }

  return left.id.compareTo(right.id);
}

/// Selects the highest-priority hosts for home-screen shortcuts.
List<Host> selectHomeScreenShortcutHosts(
  Iterable<Host> hosts, {
  required Set<int> pinnedHostIds,
  int limit = maxHomeScreenShortcutItems,
}) {
  if (limit <= 0) {
    return const <Host>[];
  }

  final rankedHosts = hosts.toList()
    ..sort(
      (left, right) => compareHomeScreenShortcutHosts(
        left,
        right,
        pinnedHostIds: pinnedHostIds,
      ),
    );
  return List<Host>.unmodifiable(rankedHosts.take(limit));
}

String _buildHomeScreenShortcutSubtitle(Host host) {
  final endpoint = '${host.username}@${host.hostname}';
  return host.port == 22 ? endpoint : '$endpoint:${host.port}';
}

/// Builds the platform shortcut items for the selected hosts.
List<ShortcutItem> buildHomeScreenShortcutItems(Iterable<Host> hosts) => hosts
    .map(
      (host) => ShortcutItem(
        type: buildHomeScreenShortcutHostType(host.id),
        localizedTitle: host.label,
        localizedSubtitle: _buildHomeScreenShortcutSubtitle(host),
      ),
    )
    .toList(growable: false);

/// Stores manual host pins for the limited home-screen shortcut set.
class HomeScreenShortcutPreferencesService {
  /// Creates a new [HomeScreenShortcutPreferencesService].
  HomeScreenShortcutPreferencesService(this._settingsService);

  final SettingsService _settingsService;

  /// Returns the currently pinned host IDs.
  Future<Set<int>> getPinnedHostIds() async {
    final rawValue = await _settingsService.getString(
      SettingKeys.homeScreenShortcutHostIds,
    );
    return parsePinnedHomeScreenShortcutHostIds(rawValue);
  }

  /// Watches the currently pinned host IDs.
  Stream<Set<int>> watchPinnedHostIds() => _settingsService
      .watchString(SettingKeys.homeScreenShortcutHostIds)
      .map(parsePinnedHomeScreenShortcutHostIds)
      .distinct(setEquals);

  /// Pins or unpins a host from the home-screen shortcut set.
  Future<void> setHostPinned(int hostId, {required bool pinned}) async {
    if (hostId <= 0) {
      throw ArgumentError.value(hostId, 'hostId', 'Must be positive.');
    }

    final pinnedHostIds = await getPinnedHostIds();
    if (pinned) {
      pinnedHostIds.add(hostId);
    } else {
      pinnedHostIds.remove(hostId);
    }
    await _writePinnedHostIds(pinnedHostIds);
  }

  Future<void> _writePinnedHostIds(Set<int> hostIds) async {
    if (hostIds.isEmpty) {
      await _settingsService.delete(SettingKeys.homeScreenShortcutHostIds);
      return;
    }

    final orderedHostIds = hostIds.toList()..sort();
    await _settingsService.setString(
      SettingKeys.homeScreenShortcutHostIds,
      jsonEncode(orderedHostIds),
    );
  }
}

/// Service that keeps platform home-screen quick actions in sync with hosts.
class HomeScreenShortcutService {
  /// Creates a new [HomeScreenShortcutService].
  HomeScreenShortcutService({QuickActions? quickActions})
    : _quickActions = quickActions ?? const QuickActions();

  final QuickActions _quickActions;
  final Queue<int> _pendingHostLaunches = Queue<int>();
  late final StreamController<int> _hostLaunchController =
      StreamController<int>.broadcast(
        onListen: _handleHostLaunchListenerAttached,
        onCancel: _handleHostLaunchListenerDetached,
      );
  Future<void>? _initializeFuture;
  int _hostLaunchListenerCount = 0;

  /// Stream of host IDs launched from a home-screen shortcut.
  Stream<int> get hostLaunches {
    unawaited(initialize());
    return _hostLaunchController.stream;
  }

  /// Ensures the quick-action integration is initialized once.
  Future<void> initialize() =>
      _initializeFuture ??= _supportsHomeScreenShortcuts
      ? _initializeInternal()
      : Future<void>.value();

  /// Updates the dynamic home-screen shortcut items.
  Future<void> updateShortcuts({
    required List<Host> hosts,
    required Set<int> pinnedHostIds,
  }) async {
    if (!_supportsHomeScreenShortcuts) {
      return;
    }

    await initialize();
    final shortcutItems = buildHomeScreenShortcutItems(
      selectHomeScreenShortcutHosts(hosts, pinnedHostIds: pinnedHostIds),
    );

    try {
      await _quickActions.setShortcutItems(shortcutItems);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  Future<void> _initializeInternal() async {
    try {
      await _quickActions.initialize((shortcutType) {
        final hostId = parseHomeScreenShortcutHostId(shortcutType);
        if (hostId == null) {
          return;
        }
        _dispatchHostLaunch(hostId);
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  void _dispatchHostLaunch(int hostId) {
    if (_hostLaunchListenerCount == 0) {
      _pendingHostLaunches.add(hostId);
      return;
    }
    _hostLaunchController.add(hostId);
  }

  void _handleHostLaunchListenerAttached() {
    _hostLaunchListenerCount += 1;
    if (_hostLaunchListenerCount == 1) {
      Future<void>.microtask(_flushPendingHostLaunches);
    }
  }

  void _handleHostLaunchListenerDetached() {
    if (_hostLaunchListenerCount > 0) {
      _hostLaunchListenerCount -= 1;
    }
  }

  void _flushPendingHostLaunches() {
    if (_hostLaunchController.isClosed || _hostLaunchListenerCount == 0) {
      return;
    }

    while (_pendingHostLaunches.isNotEmpty && _hostLaunchListenerCount > 0) {
      _hostLaunchController.add(_pendingHostLaunches.removeFirst());
    }
  }

  /// Injects a host launch in tests without going through the platform plugin.
  @visibleForTesting
  void debugEmitHostLaunch(int hostId) => _dispatchHostLaunch(hostId);

  /// Releases resources held by the service.
  Future<void> dispose() async {
    await _hostLaunchController.close();
  }
}

/// Provider for [HomeScreenShortcutPreferencesService].
final homeScreenShortcutPreferencesServiceProvider =
    Provider<HomeScreenShortcutPreferencesService>(
      (ref) => HomeScreenShortcutPreferencesService(
        ref.watch(settingsServiceProvider),
      ),
    );

/// Stream of host IDs pinned into the limited home-screen shortcut set.
final pinnedHomeScreenShortcutHostIdsProvider = StreamProvider<Set<int>>((ref) {
  final preferencesService = ref.watch(
    homeScreenShortcutPreferencesServiceProvider,
  );
  return preferencesService.watchPinnedHostIds();
});

/// Provider for [HomeScreenShortcutService].
final homeScreenShortcutServiceProvider = Provider<HomeScreenShortcutService>((
  ref,
) {
  final service = HomeScreenShortcutService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
