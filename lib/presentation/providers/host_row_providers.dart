import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/home_screen_shortcut_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/connection_preview_snippet.dart';

/// Arguments for [hostRowDataProvider].
///
/// [hostId] identifies the host. [lightThemeId] and [darkThemeId] are the
/// host-specific terminal theme overrides (nullable). [isDark] is the current
/// brightness, derived from [Theme.of(context).brightness].
typedef HostRowProviderArgs = ({
  int hostId,
  String? lightThemeId,
  String? darkThemeId,
  bool isDark,
});

/// Value-equal snapshot of all reactive data required to render one host row.
///
/// All fields use primitive or value-equal types so that Riverpod's equality
/// check can skip widget rebuilds when nothing relevant to this host changed.
@immutable
final class HostRowData {
  /// Creates a [HostRowData].
  const HostRowData({
    required this.connectionIds,
    required this.isConnected,
    required this.isConnectionStarting,
    required this.previewEntries,
    required this.isPinnedToHomeScreen,
    required this.hasHostThemeAccess,
    this.connectionAttemptMessage,
  });

  /// Active connection IDs for this host, oldest first.
  final List<int> connectionIds;

  /// Whether any connection is in [SshConnectionState.connected].
  final bool isConnected;

  /// Whether a connection is being established or actively progressing.
  final bool isConnectionStarting;

  /// Latest progress message while a connection attempt is in progress.
  ///
  /// Non-null only when a connect or reconnect attempt is actively progressing.
  final String? connectionAttemptMessage;

  /// Preview cards for each active connection, in connection-ID order.
  final List<ConnectionPreviewStackEntry> previewEntries;

  /// Whether this host is pinned to the OS home screen (iOS/macOS shortcuts).
  final bool isPinnedToHomeScreen;

  /// Whether the current plan allows per-host terminal theme overrides.
  final bool hasHostThemeAccess;

  /// Convenience: number of active connections.
  int get connectionCount => connectionIds.length;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HostRowData &&
        listEquals(other.connectionIds, connectionIds) &&
        other.isConnected == isConnected &&
        other.isConnectionStarting == isConnectionStarting &&
        other.connectionAttemptMessage == connectionAttemptMessage &&
        listEquals(other.previewEntries, previewEntries) &&
        other.isPinnedToHomeScreen == isPinnedToHomeScreen &&
        other.hasHostThemeAccess == hasHostThemeAccess;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(connectionIds),
    isConnected,
    isConnectionStarting,
    connectionAttemptMessage,
    Object.hashAll(previewEntries),
    isPinnedToHomeScreen,
    hasHostThemeAccess,
  );
}

/// Per-host auto-disposing provider for all reactive data needed to render a
/// host row on the home screen.
///
/// This provider watches [activeSessionsProvider] (the full connection-state
/// map) but only notifies consumers when the projected [HostRowData] for THIS
/// host actually changes. As a result, changing connection state for host B
/// does not rebuild the row widget for host A.
///
/// Hosts with no active connections return an empty [HostRowData] that is
/// stable across the 150 ms live-preview refresh ticks, so their rows are
/// never rebuilt by preview updates that don't belong to them.
final hostRowDataProvider = Provider.autoDispose
    .family<HostRowData, HostRowProviderArgs>((ref, args) {
      // Watch the full connection-state map. The provider re-evaluates on each
      // map change, but Riverpod only notifies downstream widgets when the
      // returned HostRowData differs by value (== check).
      final allStates = ref.watch(activeSessionsProvider);
      final notifier = ref.read(activeSessionsProvider.notifier);

      final connectionIds = notifier.getConnectionsForHost(args.hostId);
      final attempt = notifier.getConnectionAttempt(args.hostId);

      final hostStates = connectionIds
          .map((id) => allStates[id])
          .whereType<SshConnectionState>()
          .toList(growable: false);

      final isConnected = hostStates.any(
        (s) => s == SshConnectionState.connected,
      );
      final isConnecting = hostStates.any(
        (s) =>
            s == SshConnectionState.connecting ||
            s == SshConnectionState.authenticating,
      );
      final isConnectionStarting =
          isConnecting || (attempt?.isInProgress ?? false);
      final connectionAttemptMessage = (attempt?.isInProgress ?? false)
          ? attempt!.latestMessage
          : null;

      // Terminal theme data for preview card rendering.
      final themeSettings = ref.watch(terminalThemeSettingsProvider);
      final themes =
          ref.watch(allTerminalThemesProvider).asData?.value ??
          TerminalThemes.all;

      // Monetization: whether per-host theme overrides are unlocked.
      final monetizationState =
          ref.watch(monetizationStateProvider).asData?.value ??
          ref.read(monetizationServiceProvider).currentState;
      final hasHostThemeAccess = monetizationState.allowsFeature(
        MonetizationFeature.hostSpecificThemes,
      );

      // Home-screen pin state for this specific host.
      final pinnedIds =
          ref.watch(pinnedHomeScreenShortcutHostIdsProvider).asData?.value ??
          const <int>{};
      final isPinnedToHomeScreen =
          supportsHomeScreenShortcutActions && pinnedIds.contains(args.hostId);

      // Build per-connection preview entries. Entries are value-equal
      // (ConnectionPreviewStackEntry implements ==), so identical previews
      // don't trigger a rebuild even when allStates emits a new map reference.
      final brightness = args.isDark ? Brightness.dark : Brightness.light;
      final previewEntries = connectionIds
          .map((connectionId) {
            final connection = notifier.getActiveConnection(connectionId);
            final state =
                allStates[connectionId] ?? SshConnectionState.connected;
            return buildConnectionPreviewStackEntry(
              connectionId: connectionId,
              state: state,
              brightness: brightness,
              themeSettings: themeSettings,
              availableThemes: themes,
              preview: connection?.preview,
              windowTitle: connection?.windowTitle,
              iconName: connection?.iconName,
              workingDirectory: connection?.workingDirectory,
              shellStatus: connection?.shellStatus,
              lastExitCode: connection?.lastExitCode,
              hostLightThemeId: hasHostThemeAccess ? args.lightThemeId : null,
              hostDarkThemeId: hasHostThemeAccess ? args.darkThemeId : null,
              connectionLightThemeId: connection?.terminalThemeLightId,
              connectionDarkThemeId: connection?.terminalThemeDarkId,
            );
          })
          .toList(growable: false);

      return HostRowData(
        connectionIds: connectionIds,
        isConnected: isConnected,
        isConnectionStarting: isConnectionStarting,
        connectionAttemptMessage: connectionAttemptMessage,
        previewEntries: previewEntries,
        isPinnedToHomeScreen: isPinnedToHomeScreen,
        hasHostThemeAccess: hasHostThemeAccess,
      );
    });
