import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_metadata.dart';
import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/models/tmux_state.dart';
import '../../domain/services/agent_session_discovery_service.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../../domain/services/tmux_service.dart';
import '../../domain/services/transfer_intent_service.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/connection_attempt_dialog.dart';
import '../widgets/connection_preview_snippet.dart';
import '../widgets/file_picker_helpers.dart';
import '../widgets/premium_access.dart';
import '../widgets/reorder_helpers.dart';
import '../widgets/tmux_window_status_badge.dart';
import 'transfer_screen.dart';

/// The main home screen - Termius-style sidebar layout.
class HomeScreen extends ConsumerStatefulWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;

  /// Switches to the Connections tab so the user lands there when
  /// returning from the terminal.
  void switchToConnectionsTab() {
    if (_selectedIndex != 1) setState(() => _selectedIndex = 1);
  }

  /// Switches back to the Hosts tab.
  void switchToHostsTab() {
    if (_selectedIndex != 0) setState(() => _selectedIndex = 0);
  }

  StreamSubscription<String>? _incomingTransferSubscription;
  final Queue<String> _incomingTransferQueue = Queue<String>();
  String? _activeIncomingTransferPayload;
  bool _isHandlingIncomingTransfer = false;

  // Breakpoint for switching between mobile and desktop layout
  static const double _mobileBreakpoint = 600;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final transferIntentService = ref.read(transferIntentServiceProvider);
    _incomingTransferSubscription = transferIntentService.incomingPayloads
        .listen((payload) {
          if (payload.isNotEmpty && mounted) {
            _enqueueIncomingTransferPayload(payload);
          }
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_checkIncomingTransferPayload());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_incomingTransferSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkIncomingTransferPayload());
    }
  }

  Future<void> _checkIncomingTransferPayload() async {
    final payload = await ref
        .read(transferIntentServiceProvider)
        .consumeIncomingTransferPayload();
    if (!mounted || payload == null || payload.isEmpty) {
      return;
    }
    _enqueueIncomingTransferPayload(payload);
  }

  void _enqueueIncomingTransferPayload(String encodedPayload) {
    final normalizedPayload = encodedPayload.trim();
    if (normalizedPayload.isEmpty ||
        normalizedPayload == _activeIncomingTransferPayload ||
        _incomingTransferQueue.contains(normalizedPayload)) {
      return;
    }
    _incomingTransferQueue.add(normalizedPayload);
    unawaited(_processIncomingTransferQueue());
  }

  Future<void> _processIncomingTransferQueue() async {
    if (_isHandlingIncomingTransfer) {
      return;
    }
    while (mounted && _incomingTransferQueue.isNotEmpty) {
      _isHandlingIncomingTransfer = true;
      final encodedPayload = _incomingTransferQueue.removeFirst();
      _activeIncomingTransferPayload = encodedPayload;
      try {
        await _handleIncomingTransferPayload(encodedPayload);
      } finally {
        _activeIncomingTransferPayload = null;
        _isHandlingIncomingTransfer = false;
      }
    }
  }

  Future<void> _handleIncomingTransferPayload(String encodedPayload) async {
    try {
      final hasAccess = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.encryptedTransfers,
      );
      if (!hasAccess || !mounted) {
        return;
      }
      final transferPassphrase = await showTransferPassphraseDialog(
        context: context,
        title: 'Incoming transfer passphrase',
      );
      if (!mounted || transferPassphrase == null) {
        return;
      }

      final transferService = ref.read(secureTransferServiceProvider);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );

      switch (payload.type) {
        case TransferPayloadType.host:
          final host = await transferService.importHostPayload(payload);
          ref.invalidate(allHostsProvider);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported host: ${host.label}')),
          );
          break;
        case TransferPayloadType.key:
          final key = await transferService.importKeyPayload(payload);
          ref.invalidate(allKeysProvider);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Imported key: ${key.name}')));
          break;
        case TransferPayloadType.fullMigration:
          final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
          final preview = transferService.previewMigrationPayload(payload);
          if (!mounted) {
            return;
          }
          final mode = await showMigrationImportModeDialog(
            context: context,
            preview: preview,
            title: 'Incoming migration package',
            message: 'Choose how to apply the incoming data.',
          );
          if (mode == null || !mounted) {
            return;
          }
          await transferService.importFullMigrationPayload(
            payload: payload,
            mode: mode,
          );
          if (mode == MigrationImportMode.replace) {
            await sessionsNotifier.disconnectAll();
          }
          ref
            ..invalidate(themeModeNotifierProvider)
            ..invalidate(fontSizeNotifierProvider)
            ..invalidate(fontFamilyNotifierProvider)
            ..invalidate(cursorStyleNotifierProvider)
            ..invalidate(bellSoundNotifierProvider)
            ..invalidate(terminalThemeSettingsProvider);
          invalidateImportedEntityProviders(ref.invalidate);
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Imported full migration package')),
          );
          break;
      }
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<int, SshConnectionState>>(activeSessionsProvider, (
      previous,
      next,
    ) {
      final hadConnections = previous?.isNotEmpty ?? false;
      if (!hadConnections || next.isNotEmpty || _selectedIndex != 1) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedIndex != 1) {
          return;
        }
        switchToHostsTab();
      });
    });

    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= _mobileBreakpoint;

    return isWide ? _buildDesktopLayout() : _buildMobileLayout();
  }

  Widget _buildMobileLayout() => Scaffold(
    appBar: AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/icons/monkeyssh_icon.png',
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 8),
          Text(ref.watch(appDisplayNameProvider)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push('/settings'),
        ),
      ],
    ),
    body: _buildContent(),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      height: 65,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dns_outlined),
          selectedIcon: Icon(Icons.dns_rounded),
          label: 'Hosts',
        ),
        NavigationDestination(
          icon: Icon(Icons.link_outlined),
          selectedIcon: Icon(Icons.link),
          label: 'Connections',
        ),
        NavigationDestination(
          icon: Icon(Icons.key_outlined),
          selectedIcon: Icon(Icons.key_rounded),
          label: 'Keys',
        ),
        NavigationDestination(
          icon: Icon(Icons.code_outlined),
          selectedIcon: Icon(Icons.code_rounded),
          label: 'Snippets',
        ),
      ],
    ),
  );

  Widget _buildDesktopLayout() {
    final appName = ref.watch(appDisplayNameProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Row(
        children: [
          // Sidebar navigation
          Container(
            width: 230,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F0F14) : Colors.grey.shade50,
              border: Border(
                right: BorderSide(color: colorScheme.outline.withAlpha(60)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // App header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/icons/monkeyssh_icon.png',
                            width: 32,
                            height: 32,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          appName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),

                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colorScheme.outline.withAlpha(40),
                  ),
                  const SizedBox(height: 12),

                  // Navigation items
                  _NavItem(
                    icon: Icons.dns_rounded,
                    label: 'Hosts',
                    selected: _selectedIndex == 0,
                    onTap: () => setState(() => _selectedIndex = 0),
                  ),
                  _NavItem(
                    icon: Icons.link,
                    label: 'Connections',
                    selected: _selectedIndex == 1,
                    onTap: () => setState(() => _selectedIndex = 1),
                  ),
                  _NavItem(
                    icon: Icons.key_rounded,
                    label: 'Keys',
                    selected: _selectedIndex == 2,
                    onTap: () => setState(() => _selectedIndex = 2),
                  ),
                  _NavItem(
                    icon: Icons.code_rounded,
                    label: 'Snippets',
                    selected: _selectedIndex == 3,
                    onTap: () => setState(() => _selectedIndex = 3),
                  ),

                  const Spacer(),

                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colorScheme.outline.withAlpha(40),
                  ),
                  const SizedBox(height: 8),

                  // Settings at bottom
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    onTap: () => context.push('/settings'),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Main content
          Expanded(
            child: SafeArea(
              left: false,
              right: false,
              bottom: false,
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() => switch (_selectedIndex) {
    0 => const HostsPanel(),
    1 => const _ConnectionsPanel(),
    2 => const _KeysPanel(),
    3 => const SnippetsPanel(),
    _ => const HostsPanel(),
  };
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? colorScheme.primary.withAlpha(isDark ? 25 : 20)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: colorScheme.primary.withAlpha(isDark ? 12 : 8),
          splashColor: colorScheme.primary.withAlpha(isDark ? 20 : 15),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurface.withAlpha(200),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Panel for displaying and managing hosts inline.
class HostsPanel extends ConsumerWidget {
  /// Creates a [HostsPanel].
  const HostsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostsAsync = ref.watch(allHostsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'Hosts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'New Host',
                onTap: () => context.push('/hosts/add'),
                primary: true,
              ),
            ],
          ),
        ),

        Expanded(child: _buildHostsBody(context, ref, hostsAsync)),
      ],
    );
  }

  Widget _buildHostsBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Host>> hostsAsync,
  ) => RefreshIndicator(
    onRefresh: () => _refreshHosts(context, ref),
    child: hostsAsync.when(
      loading: () => _buildCenteredHostsState(
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (error, _) => _buildCenteredHostsState(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text('Error: $error'),
          ],
        ),
      ),
      data: (hosts) => hosts.isEmpty
          ? _buildEmptyState(context)
          : _buildHostsList(context, ref, hosts),
    ),
  );

  Widget _buildEmptyState(BuildContext context) => _buildCenteredHostsState(
    child: FluttyTheme.buildEmptyState(
      context: context,
      icon: Icons.dns_outlined,
      title: 'No hosts yet',
      subtitle: 'Add a host to get started',
      onAction: () => context.push('/hosts/add'),
      actionLabel: 'Add Host',
      centered: false,
      padded: false,
    ),
  );

  Widget _buildCenteredHostsState({required Widget child}) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: child,
          ),
        ),
      ),
    ],
  );

  Widget _buildHostsList(
    BuildContext context,
    WidgetRef ref,
    List<Host> hosts,
  ) => ReorderableListView.builder(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(vertical: 4),
    buildDefaultDragHandles: false,
    itemCount: hosts.length,
    onReorder: (oldIndex, newIndex) => unawaited(
      _reorderHosts(
        ref: ref,
        hosts: hosts,
        oldIndex: oldIndex,
        newIndex: newIndex,
      ),
    ),
    itemBuilder: (context, index) {
      final host = hosts[index];
      return _HostRow(
        key: ValueKey('home-host-${host.id}'),
        host: host,
        reorderHandle: ReorderGrip(index: index),
      );
    },
  );

  Future<void> _reorderHosts({
    required WidgetRef ref,
    required List<Host> hosts,
    required int oldIndex,
    required int newIndex,
  }) async {
    final reorderedIds = reorderVisibleIdsInFullOrder(
      allIds: hosts.map((host) => host.id).toList(growable: false),
      visibleIds: hosts.map((host) => host.id).toList(growable: false),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    await ref.read(hostRepositoryProvider).reorderByIds(reorderedIds);
  }

  Future<void> _refreshHosts(BuildContext context, WidgetRef ref) async {
    ref.invalidate(allHostsProvider);
    await ref.read(allHostsProvider.future);
  }
}

enum _HostContextAction {
  connect,
  newConnection,
  edit,
  duplicate,
  export,
  delete,
}

class _HostRow extends ConsumerWidget {
  const _HostRow({required this.host, required this.reorderHandle, super.key});

  final Host host;
  final Widget reorderHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionStates = ref.watch(activeSessionsProvider);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);
    final hostConnectionStates = connectionIds
        .map((connectionId) => connectionStates[connectionId])
        .whereType<SshConnectionState>()
        .toList(growable: false);
    final isConnected = hostConnectionStates.any(
      (state) => state == SshConnectionState.connected,
    );
    final isConnecting = hostConnectionStates.any(
      (state) =>
          state == SshConnectionState.connecting ||
          state == SshConnectionState.authenticating,
    );
    final connectionAttempt = sessionsNotifier.getConnectionAttempt(host.id);
    final isConnectionStarting =
        isConnecting || (connectionAttempt?.isInProgress ?? false);
    final connectionCount = connectionIds.length;
    final terminalThemeSettings = ref.watch(terminalThemeSettingsProvider);
    final terminalThemes =
        ref.watch(allTerminalThemesProvider).asData?.value ??
        TerminalThemes.all;
    final monetizationState =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final hasHostThemeAccess = monetizationState.allowsFeature(
      MonetizationFeature.hostSpecificThemes,
    );
    final previewEntries = connectionIds
        .map((connectionId) {
          final connection = sessionsNotifier.getActiveConnection(connectionId);
          final state =
              connectionStates[connectionId] ?? SshConnectionState.connected;
          return buildConnectionPreviewStackEntry(
            connectionId: connectionId,
            state: state,
            preview: connection?.preview,
            windowTitle: connection?.windowTitle,
            iconName: connection?.iconName,
            workingDirectory: connection?.workingDirectory,
            shellStatus: connection?.shellStatus,
            lastExitCode: connection?.lastExitCode,
            brightness: theme.brightness,
            themeSettings: terminalThemeSettings,
            availableThemes: terminalThemes,
            hostLightThemeId: hasHostThemeAccess
                ? host.terminalThemeLightId
                : null,
            hostDarkThemeId: hasHostThemeAccess
                ? host.terminalThemeDarkId
                : null,
            connectionLightThemeId: connection?.terminalThemeLightId,
            connectionDarkThemeId: connection?.terminalThemeDarkId,
          );
        })
        .toList(growable: false);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openHostConnection(context, ref)),
        onLongPress: () => unawaited(_showContextMenuAtCenter(context, ref)),
        onSecondaryTapDown: (details) =>
            unawaited(_showContextMenu(context, ref, details.globalPosition)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status indicator
                  SizedBox(
                    height: 28,
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isConnected
                              ? colorScheme.primary
                              : isConnectionStarting
                              ? Colors.orange
                              : colorScheme.onSurface.withAlpha(40),
                          boxShadow: isConnected && isDark
                              ? [
                                  BoxShadow(
                                    color: colorScheme.primary.withAlpha(100),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Host info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              host.label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (connectionCount > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withAlpha(20),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$connectionCount',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            if (host.isFavorite) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.star_rounded,
                                size: 14,
                                color: Colors.amber.shade600,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${host.username}@${host.hostname}',
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 11,
                            color: colorScheme.onSurface.withAlpha(100),
                          ),
                        ),
                        if (connectionAttempt?.isInProgress ?? false) ...[
                          const SizedBox(height: 4),
                          Text(
                            connectionAttempt!.latestMessage,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.outline.withAlpha(40),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          ':${host.port}',
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurface.withAlpha(120),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SmallIconButton(
                        icon: Icons.add,
                        tooltip: 'New connection',
                        onTap: () =>
                            unawaited(_openNewConnection(context, ref)),
                      ),
                      reorderHandle,
                    ],
                  ),
                ],
              ),
              if (previewEntries.isNotEmpty) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: ConnectionPreviewStack(entries: previewEntries),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openHostConnection(BuildContext context, WidgetRef ref) async {
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);

    if (connectionIds.isEmpty) {
      await _openNewConnection(context, ref);
      return;
    }

    if (connectionIds.length == 1) {
      if (context.mounted) {
        context
            .findAncestorStateOfType<_HomeScreenState>()
            ?.switchToConnectionsTab();
        unawaited(
          context.push(
            '/terminal/${host.id}?connectionId=${connectionIds.first}',
          ),
        );
      }
      return;
    }

    final selection = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final connectionStates = ref.read(activeSessionsProvider);
        final terminalThemeSettings = ref.read(terminalThemeSettingsProvider);
        final terminalThemes =
            ref.read(allTerminalThemesProvider).asData?.value ??
            TerminalThemes.all;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(host.label),
                subtitle: Text('${connectionIds.length} active connections'),
              ),
              for (final connectionId in connectionIds.reversed)
                () {
                  final connection = sessionsNotifier.getActiveConnection(
                    connectionId,
                  );
                  return _ConnectionSelectionTile(
                    connectionId: connectionId,
                    state:
                        connectionStates[connectionId] ??
                        SshConnectionState.disconnected,
                    endpoint: '${host.username}@${host.hostname}:${host.port}',
                    preview: connection?.preview,
                    windowTitle: connection?.windowTitle,
                    iconName: connection?.iconName,
                    workingDirectory: connection?.workingDirectory,
                    shellStatus: connection?.shellStatus,
                    lastExitCode: connection?.lastExitCode,
                    terminalTheme: resolveConnectionPreviewTheme(
                      brightness: Theme.of(context).brightness,
                      themeSettings: terminalThemeSettings,
                      availableThemes: terminalThemes,
                      lightThemeId:
                          connection?.terminalThemeLightId ??
                          host.terminalThemeLightId,
                      darkThemeId:
                          connection?.terminalThemeDarkId ??
                          host.terminalThemeDarkId,
                    ),
                    createdAt: sessionsNotifier
                        .getSession(connectionId)
                        ?.createdAt,
                    onTap: () =>
                        Navigator.pop(context, 'connection:$connectionId'),
                  );
                }(),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New connection'),
                onTap: () => Navigator.pop(context, 'new'),
              ),
            ],
          ),
        );
      },
    );

    if (!context.mounted || selection == null) {
      return;
    }

    if (selection == 'new') {
      await _openNewConnection(context, ref);
      return;
    }

    final selectedId = int.tryParse(selection.replaceFirst('connection:', ''));
    if (selectedId != null) {
      context
          .findAncestorStateOfType<_HomeScreenState>()
          ?.switchToConnectionsTab();
      unawaited(context.push('/terminal/${host.id}?connectionId=$selectedId'));
    }
  }

  Future<void> _showContextMenuAtCenter(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return;
    }

    final globalPosition = renderBox.localToGlobal(
      renderBox.size.center(Offset.zero),
    );
    await _showContextMenu(context, ref, globalPosition);
  }

  Future<void> _openNewConnection(BuildContext context, WidgetRef ref) async {
    final result = await connectToHostWithProgressDialog(context, ref, host);

    if (!context.mounted) {
      return;
    }

    if (!result.success || result.connectionId == null) {
      return;
    }

    unawaited(
      context.push('/terminal/${host.id}?connectionId=${result.connectionId}'),
    );
    if (context.mounted) {
      context
          .findAncestorStateOfType<_HomeScreenState>()
          ?.switchToConnectionsTab();
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;

    final overlay = Overlay.maybeOf(context);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) {
      return;
    }
    final selection = await showMenu<_HostContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: [
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.connect,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.link),
            title: Text('Connect'),
          ),
        ),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.newConnection,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add),
            title: Text('New connection'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.edit,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
          ),
        ),
        const PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.duplicate,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.copy),
            title: Text('Duplicate'),
          ),
        ),
        PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.export,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(useShareSheet ? Icons.share : Icons.save_alt),
            title: Text(
              useShareSheet
                  ? 'Share Encrypted (Pro)'
                  : 'Export Encrypted File (Pro)',
            ),
          ),
        ),
        PopupMenuItem<_HostContextAction>(
          value: _HostContextAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: colorScheme.error),
            title: Text('Delete', style: TextStyle(color: colorScheme.error)),
          ),
        ),
      ],
    );

    if (!context.mounted || selection == null) {
      return;
    }

    switch (selection) {
      case _HostContextAction.connect:
        await _openHostConnection(context, ref);
        return;
      case _HostContextAction.newConnection:
        await _openNewConnection(context, ref);
        return;
      case _HostContextAction.edit:
        unawaited(context.push('/hosts/edit/${host.id}'));
        return;
      case _HostContextAction.duplicate:
        await _duplicateHost(context, ref);
        return;
      case _HostContextAction.export:
        await _exportEncryptedFile(context, ref);
        return;
      case _HostContextAction.delete:
        await _confirmDelete(context, ref);
        return;
    }
  }

  Future<void> _exportEncryptedFile(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    if ((host.password?.isNotEmpty ?? false) || host.keyId != null) {
      final isAuthorized = await authorizeSensitiveTransferExport(
        context: context,
        authService: ref.read(authServiceProvider),
        readAuthState: () => ref.read(authStateProvider),
        reason: 'Authenticate to export host credentials',
      );
      if (!context.mounted) {
        return;
      }
      if (!isAuthorized) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication required for host export'),
          ),
        );
        return;
      }
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Host transfer passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    final payload = await ref
        .read(secureTransferServiceProvider)
        .createHostPayload(
          host: host,
          transferPassphrase: transferPassphrase,
          includeReferencedKey: host.keyId != null,
        );

    if (!context.mounted) {
      return;
    }

    final defaultFileName = sanitizeTransferFileBaseName(
      'host-${host.label.toLowerCase().replaceAll(' ', '-')}',
    );

    await saveTransferPayloadToFile(
      context: context,
      payload: payload,
      defaultFileName: defaultFileName,
      sharePositionOrigin: shareOriginFromContext(context),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Host'),
        content: Text('Delete "${host.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(hostRepositoryProvider).delete(host.id);
    }
  }

  Future<void> _duplicateHost(BuildContext context, WidgetRef ref) async {
    await ref.read(hostRepositoryProvider).duplicate(host);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Host duplicated')));
    }
  }
}

class _ConnectionSelectionTile extends StatelessWidget {
  const _ConnectionSelectionTile({
    required this.connectionId,
    required this.state,
    required this.endpoint,
    required this.onTap,
    this.preview,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.terminalTheme,
    this.createdAt,
  });

  final int connectionId;
  final SshConnectionState state;
  final String endpoint;
  final String? preview;
  final String? windowTitle;
  final String? iconName;
  final Uri? workingDirectory;
  final TerminalShellStatus? shellStatus;
  final int? lastExitCode;
  final TerminalThemeData? terminalTheme;
  final DateTime? createdAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = createdAt == null
        ? endpoint
        : '$endpoint\nOpened ${_formatTime(createdAt!)}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      minTileHeight: 64,
      minVerticalPadding: 10,
      leading: const Icon(Icons.terminal),
      title: Text('Connection #$connectionId'),
      subtitle: _ConnectionPreviewText(
        endpoint: subtitle,
        preview: preview,
        windowTitle: windowTitle,
        iconName: iconName,
        workingDirectory: workingDirectory,
        shellStatus: shellStatus,
        lastExitCode: lastExitCode,
        terminalTheme: terminalTheme,
      ),
      isThreeLine: preview?.trim().isNotEmpty ?? false,
      trailing: Text(
        _stateLabel(state),
        style: Theme.of(context).textTheme.labelMedium,
      ),
      onTap: onTap,
    );
  }

  String _stateLabel(SshConnectionState state) => switch (state) {
    SshConnectionState.connected => 'Connected',
    SshConnectionState.connecting => 'Connecting',
    SshConnectionState.authenticating => 'Auth',
    SshConnectionState.reconnecting => 'Reconnecting',
    SshConnectionState.error => 'Error',
    SshConnectionState.disconnected => 'Disconnected',
  };

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _ConnectionsPanel extends ConsumerWidget {
  const _ConnectionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostsAsync = ref.watch(allHostsProvider);
    final connectionStates = ref.watch(activeSessionsProvider);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final terminalThemeSettings = ref.watch(terminalThemeSettingsProvider);
    final terminalThemes =
        ref.watch(allTerminalThemesProvider).asData?.value ??
        TerminalThemes.all;
    final monetizationState =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final hasHostThemeAccess = monetizationState.allowsFeature(
      MonetizationFeature.hostSpecificThemes,
    );
    final connections = sessionsNotifier.getActiveConnections();
    final hosts = hostsAsync.asData?.value ?? <Host>[];
    final hostLookup = {for (final host in hosts) host.id: host};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Text(
            'Connections',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: connections.isEmpty
              ? _buildEmptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: connections.length,
                  itemBuilder: (context, index) {
                    final connection = connections[index];
                    final host = hostLookup[connection.hostId];
                    final state =
                        connectionStates[connection.connectionId] ??
                        connection.state;
                    final endpoint =
                        '${connection.config.username}@'
                        '${connection.config.hostname}:${connection.config.port}';
                    final preview = connection.preview;
                    final previewTheme = resolveConnectionPreviewTheme(
                      brightness: theme.brightness,
                      themeSettings: terminalThemeSettings,
                      availableThemes: terminalThemes,
                      lightThemeId:
                          connection.terminalThemeLightId ??
                          (hasHostThemeAccess
                              ? host?.terminalThemeLightId
                              : null),
                      darkThemeId:
                          connection.terminalThemeDarkId ??
                          (hasHostThemeAccess
                              ? host?.terminalThemeDarkId
                              : null),
                    );

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: Icon(
                            Icons.terminal,
                            color: state == SshConnectionState.connected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                          title: Text(
                            host?.label ?? 'Host ${connection.hostId}',
                          ),
                          subtitle: _ConnectionPreviewText(
                            endpoint:
                                '$endpoint  •  Connection #${connection.connectionId}',
                            preview: preview,
                            windowTitle: connection.windowTitle,
                            iconName: connection.iconName,
                            workingDirectory: connection.workingDirectory,
                            shellStatus: connection.shellStatus,
                            lastExitCode: connection.lastExitCode,
                            terminalTheme: previewTheme,
                          ),
                          isThreeLine: preview?.trim().isNotEmpty ?? false,
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Disconnect',
                            onPressed: () async {
                              ref
                                  .read(tmuxServiceProvider)
                                  .clearCache(connection.connectionId);
                              await ref
                                  .read(activeSessionsProvider.notifier)
                                  .disconnect(connection.connectionId);
                            },
                          ),
                          onTap: () => unawaited(
                            context.push(
                              '/terminal/${connection.hostId}'
                              '?connectionId=${connection.connectionId}',
                            ),
                          ),
                        ),
                        if (state == SshConnectionState.connected)
                          _TmuxConnectionBadge(
                            key: ValueKey(
                              'tmux-badge-${connection.connectionId}',
                            ),
                            connectionId: connection.connectionId,
                            onTap: () => unawaited(
                              context.push(
                                '/terminal/${connection.hostId}'
                                '?connectionId=${connection.connectionId}',
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) => FluttyTheme.buildEmptyState(
    context: context,
    icon: Icons.link_off,
    title: 'No active connections',
    subtitle: 'Open a host to create one',
  );
}

class _ConnectionPreviewText extends StatelessWidget {
  const _ConnectionPreviewText({
    required this.endpoint,
    this.preview,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.terminalTheme,
  });

  final String endpoint;
  final String? preview;
  final String? windowTitle;
  final String? iconName;
  final Uri? workingDirectory;
  final TerminalShellStatus? shellStatus;
  final int? lastExitCode;
  final TerminalThemeData? terminalTheme;

  @override
  Widget build(BuildContext context) => ConnectionPreviewSnippet(
    endpoint: endpoint,
    preview: preview,
    windowTitle: windowTitle,
    iconName: iconName,
    workingDirectory: workingDirectory,
    shellStatus: shellStatus,
    lastExitCode: lastExitCode,
    terminalTheme: terminalTheme,
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
    }

    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: colorScheme.onSurface.withAlpha(150)),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: colorScheme.onSurface.withAlpha(150),
        ),
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final button = ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: colorScheme.onSurface.withAlpha(20),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 16,
            color: colorScheme.onSurface.withAlpha(120),
          ),
        ),
      ),
    );
    final semanticButton = Semantics(
      button: true,
      onTap: onTap,
      label: tooltip,
      child: button,
    );

    if (tooltip case final tooltipText?) {
      return Tooltip(
        message: tooltipText,
        excludeFromSemantics: true,
        child: semanticButton,
      );
    }
    return semanticButton;
  }
}

class _KeysPanel extends ConsumerWidget {
  const _KeysPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keysAsync = ref.watch(allKeysProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'SSH Keys',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'Add Key',
                onTap: () => context.push('/keys/add'),
                primary: true,
              ),
            ],
          ),
        ),

        // Keys list
        Expanded(
          child: keysAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (keys) => keys.isEmpty
                ? _buildEmptyState(context)
                : _buildKeysList(context, ref, keys),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) => FluttyTheme.buildEmptyState(
    context: context,
    icon: Icons.key_outlined,
    title: 'No SSH keys yet',
    subtitle: 'Generate or import a key',
    onAction: () => context.push('/keys/add'),
    actionLabel: 'Add Key',
    actionIcon: Icons.add,
  );

  Widget _buildKeysList(
    BuildContext context,
    WidgetRef ref,
    List<SshKey> keys,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: keys.length,
    itemBuilder: (context, index) {
      final key = keys[index];
      return _KeyRow(sshKey: key);
    },
  );
}

class _KeyRow extends ConsumerWidget {
  const _KeyRow({required this.sshKey});

  final SshKey sshKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showKeyDetails(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Key icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C9FF).withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _getKeyIcon(),
                  size: 16,
                  color: const Color(0xFF00C9FF),
                ),
              ),
              const SizedBox(width: 12),

              // Key info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sshKey.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sshKey.keyType.toUpperCase(),
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ),

              // Transfer and key actions
              _SmallIconButton(
                icon: useShareSheet ? Icons.share : Icons.save_alt,
                tooltip: useShareSheet ? 'Share encrypted' : 'Export encrypted',
                onTap: () => unawaited(_exportEncryptedFile(context, ref)),
              ),
              _SmallIconButton(
                icon: Icons.copy,
                tooltip: 'Copy public key',
                onTap: () => _copyPublicKey(context),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete',
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getKeyIcon() {
    if (sshKey.keyType.toLowerCase().contains('ed25519')) {
      return Icons.enhanced_encryption;
    } else if (sshKey.keyType.toLowerCase().contains('rsa')) {
      return Icons.key;
    }
    return Icons.vpn_key;
  }

  void _copyPublicKey(BuildContext context) {
    Clipboard.setData(ClipboardData(text: sshKey.publicKey));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Public key copied')));
  }

  Future<void> _exportEncryptedFile(BuildContext context, WidgetRef ref) async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
    );
    if (!hasAccess || !context.mounted) {
      return;
    }
    final isAuthorized = await authorizeSensitiveTransferExport(
      context: context,
      authService: ref.read(authServiceProvider),
      readAuthState: () => ref.read(authStateProvider),
      reason: 'Authenticate to export private key',
    );
    if (!context.mounted) {
      return;
    }
    if (!isAuthorized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication required for key export')),
      );
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Key transfer passphrase',
    );
    if (!context.mounted || transferPassphrase == null) {
      return;
    }

    final payload = await ref
        .read(secureTransferServiceProvider)
        .createKeyPayload(key: sshKey, transferPassphrase: transferPassphrase);

    if (!context.mounted) {
      return;
    }

    final defaultFileName = sanitizeTransferFileBaseName(
      'key-${sshKey.name.toLowerCase().replaceAll(' ', '-')}',
    );

    await saveTransferPayloadToFile(
      context: context,
      payload: payload,
      defaultFileName: defaultFileName,
      sharePositionOrigin: shareOriginFromContext(context),
    );
  }

  void _showKeyDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: scrollController,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(sshKey.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                sshKey.keyType.toUpperCase(),
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              Text('Public Key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outline.withAlpha(60)),
                ),
                child: SelectableText(
                  sshKey.publicKey,
                  style: FluttyTheme.monoStyle.copyWith(fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _copyPublicKey(context),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Public Key'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Delete "${sshKey.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(keyRepositoryProvider).delete(sshKey.id);
    }
  }
}

/// Provider for all snippets as stream.
final _allSnippetsStreamProvider = StreamProvider<List<Snippet>>((ref) {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.watchAll();
});

/// Panel for displaying and managing snippets inline.
class SnippetsPanel extends ConsumerWidget {
  /// Creates a [SnippetsPanel].
  const SnippetsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final snippetsAsync = ref.watch(_allSnippetsStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'Snippets',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'Add Snippet',
                onTap: () => _showAddEditSnippetDialog(context, ref, null),
                primary: true,
              ),
            ],
          ),
        ),

        // Snippets list
        Expanded(
          child: snippetsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (snippets) => snippets.isEmpty
                ? _buildEmptyState(context, ref)
                : _buildSnippetsList(context, ref, snippets),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) =>
      FluttyTheme.buildEmptyState(
        context: context,
        icon: Icons.code_outlined,
        title: 'No snippets yet',
        subtitle: 'Save commands you use often',
        onAction: () => _showAddEditSnippetDialog(context, ref, null),
        actionLabel: 'Add Snippet',
      );

  Widget _buildSnippetsList(
    BuildContext context,
    WidgetRef ref,
    List<Snippet> snippets,
  ) => ReorderableListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    buildDefaultDragHandles: false,
    itemCount: snippets.length,
    onReorder: (oldIndex, newIndex) => unawaited(
      _reorderSnippets(
        ref: ref,
        snippets: snippets,
        oldIndex: oldIndex,
        newIndex: newIndex,
      ),
    ),
    itemBuilder: (context, index) {
      final snippet = snippets[index];
      return _SnippetRow(
        key: ValueKey('home-snippet-${snippet.id}'),
        snippet: snippet,
        reorderHandle: ReorderGrip(index: index),
      );
    },
  );

  Future<void> _reorderSnippets({
    required WidgetRef ref,
    required List<Snippet> snippets,
    required int oldIndex,
    required int newIndex,
  }) async {
    final reorderedIds = reorderVisibleIdsInFullOrder(
      allIds: snippets.map((snippet) => snippet.id).toList(growable: false),
      visibleIds: snippets.map((snippet) => snippet.id).toList(growable: false),
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    await ref.read(snippetRepositoryProvider).reorderByIds(reorderedIds);
  }

  static Future<void> _showAddEditSnippetDialog(
    BuildContext context,
    WidgetRef ref,
    Snippet? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final commandController = TextEditingController(
      text: existing?.command ?? '',
    );
    final descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    final formKey = GlobalKey<FormState>();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          maxChildSize: 0.9,
          minChildSize: 0.5,
          initialChildSize: 0.7,
          expand: false,
          builder: (context, scrollController) => Form(
            key: formKey,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  existing == null ? 'Add Snippet' : 'Edit Snippet',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Restart Docker',
                    prefixIcon: Icon(Icons.label),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    hintText: 'What this snippet does',
                    prefixIcon: Icon(Icons.description),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: commandController,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: 'docker restart {{container}}',
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  style: FluttyTheme.monoStyle.copyWith(fontSize: 14),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a command';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Use {{variable}} for substitution',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            Navigator.pop(context, true);
                          }
                        },
                        child: Text(existing == null ? 'Add' : 'Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (result ?? false) {
      final repo = ref.read(snippetRepositoryProvider);
      final description = descriptionController.text.isEmpty
          ? null
          : descriptionController.text;

      if (existing != null) {
        await repo.update(
          existing.copyWith(
            name: nameController.text,
            command: commandController.text,
            description: drift.Value(description),
          ),
        );
      } else {
        await repo.insert(
          SnippetsCompanion.insert(
            name: nameController.text,
            command: commandController.text,
            description: drift.Value(description),
          ),
        );
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null ? 'Snippet added' : 'Snippet updated',
            ),
          ),
        );
      }
    }

    nameController.dispose();
    commandController.dispose();
    descriptionController.dispose();
  }
}

class _SnippetRow extends ConsumerWidget {
  const _SnippetRow({
    required this.snippet,
    required this.reorderHandle,
    super.key,
  });

  final Snippet snippet;
  final Widget reorderHandle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copySnippet(context, ref),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Snippet icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.code, size: 16, color: colorScheme.primary),
              ),
              const SizedBox(width: 12),

              // Snippet info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snippet.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      snippet.command.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ),

              // Actions
              reorderHandle,
              _SmallIconButton(
                icon: Icons.copy,
                tooltip: 'Copy command',
                onTap: () => _copySnippet(context, ref),
              ),
              _SmallIconButton(
                icon: Icons.edit_outlined,
                tooltip: 'Edit',
                onTap: () => SnippetsPanel._showAddEditSnippetDialog(
                  context,
                  ref,
                  snippet,
                ),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete',
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copySnippet(BuildContext context, WidgetRef ref) {
    Clipboard.setData(ClipboardData(text: snippet.command));
    unawaited(ref.read(snippetRepositoryProvider).incrementUsage(snippet.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "${snippet.name}" to clipboard')),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Snippet'),
        content: Text('Delete "${snippet.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(snippetRepositoryProvider).delete(snippet.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${snippet.name}"')));
      }
    }
  }
}

/// Shows a compact tmux window badge below a connection tile.
///
/// Asynchronously queries tmux state for the given connection and displays
/// a horizontal list of window name chips if tmux is active.
class _TmuxConnectionBadge extends ConsumerStatefulWidget {
  const _TmuxConnectionBadge({
    required this.connectionId,
    required this.onTap,
    super.key,
  });

  final int connectionId;

  /// Called when the user taps a window chip — opens the terminal.
  final VoidCallback onTap;

  @override
  ConsumerState<_TmuxConnectionBadge> createState() =>
      _TmuxConnectionBadgeState();
}

class _TmuxConnectionBadgeState extends ConsumerState<_TmuxConnectionBadge> {
  static const _initialSessionFetchLimit = 24;
  static const _sessionFetchStep = 12;
  static const _tmuxQueryRetryDelay = Duration(seconds: 2);

  List<TmuxWindow>? _windows;
  List<ToolSessionInfo>? _recentSessions;
  final Set<String> _expandedSessionTools = <String>{};
  StreamSubscription<DiscoveredSessionsResult>? _sessionDiscoverySubscription;
  String? _sessionLoadError;
  String? _sessionName;
  bool _queried = false;
  bool _expanded = false;
  bool _showSessions = false;
  bool _isLoadingSessions = false;
  bool _canLoadMoreSessions = false;
  int _sessionFetchLimit = _initialSessionFetchLimit;
  int _sessionLoadGeneration = 0;
  bool _restoredUiState = false;
  StreamSubscription<void>? _windowChangeSubscription;
  bool _loadingWindows = false;
  bool _pendingWindowReload = false;

  @override
  void initState() {
    super.initState();
    _queryTmux();
  }

  @override
  void dispose() {
    unawaited(_sessionDiscoverySubscription?.cancel());
    unawaited(_windowChangeSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredUiState) return;
    _restoredUiState = true;

    final storedState = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _pageStorageIdentifier);
    if (storedState is! Map<Object?, Object?>) return;

    _expanded = storedState['expanded'] as bool? ?? _expanded;
    _showSessions = storedState['showSessions'] as bool? ?? _showSessions;
    _sessionFetchLimit =
        storedState['sessionFetchLimit'] as int? ?? _sessionFetchLimit;

    final expandedSessionTools = storedState['expandedSessionTools'];
    if (expandedSessionTools is List<Object?>) {
      _expandedSessionTools
        ..clear()
        ..addAll(
          expandedSessionTools.whereType<String>().where(
            (toolName) => toolName.isNotEmpty,
          ),
        );
    }

    if (!_hasAgentSessionAccess) {
      _showSessions = false;
    }

    if (_showSessions && _hasAgentSessionAccess) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadRecentSessions();
      });
    }
  }

  String get _pageStorageIdentifier =>
      'tmux-badge-state-${widget.connectionId}';

  void _persistUiState() {
    PageStorage.maybeOf(context)?.writeState(context, <String, Object>{
      'expanded': _expanded,
      'showSessions': _showSessions,
      'sessionFetchLimit': _sessionFetchLimit,
      'expandedSessionTools': _expandedSessionTools.toList(growable: false),
    }, identifier: _pageStorageIdentifier);
  }

  bool get _hasAgentSessionAccess {
    final monetizationState =
        ref.read(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    return monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );
  }

  Future<void> _retryTmuxQuery(int retries) async {
    if (retries <= 0 || !mounted) {
      if (mounted) {
        setState(() => _queried = true);
      }
      return;
    }
    await Future<void>.delayed(_tmuxQueryRetryDelay);
    if (mounted) {
      await _queryTmux(retries: retries - 1);
    }
  }

  Future<void> _handleLockedAiSessionsTap() => requireMonetizationFeatureAccess(
    context: context,
    ref: ref,
    feature: MonetizationFeature.agentLaunchPresets,
  );

  Future<void> _queryTmux({int retries = 3}) async {
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final session = sessionsNotifier.getSession(widget.connectionId);
    if (session == null) {
      // Session not available yet — retry after a delay so the badge
      // still appears for connections that finish establishing shortly.
      await _retryTmuxQuery(retries);
      return;
    }

    final tmux = ref.read(tmuxServiceProvider);
    final active = await tmux.isTmuxActive(session);
    if (!mounted || !active) {
      await _retryTmuxQuery(retries);
      return;
    }

    final sessionName = await tmux.currentSessionName(session);
    if (!mounted || sessionName == null) {
      await _retryTmuxQuery(retries);
      return;
    }

    await _windowChangeSubscription?.cancel();
    _windowChangeSubscription = tmux
        .watchWindowChanges(session, sessionName)
        .listen((_) {
          if (!mounted) return;
          _refreshTmuxWindows(session, sessionName);
        });
    await _refreshTmuxWindows(session, sessionName);
  }

  Future<void> _refreshTmuxWindows(
    SshSession session,
    String sessionName,
  ) async {
    if (_loadingWindows) {
      _pendingWindowReload = true;
      return;
    }
    _loadingWindows = true;
    try {
      final windows = await ref
          .read(tmuxServiceProvider)
          .listWindows(session, sessionName);
      if (!mounted) return;
      setState(() {
        _windows = windows;
        _sessionName = sessionName;
        _queried = true;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _queried = true;
      });
    } finally {
      _loadingWindows = false;
      if (_pendingWindowReload) {
        _pendingWindowReload = false;
        unawaited(_refreshTmuxWindows(session, sessionName));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_queried || _windows == null || _windows!.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final hasAgentSessionAccess = _hasAgentSessionAccess;
    final windows = _windows!;
    final alertCount = windows.where((w) => w.hasAlert).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsed summary row — tap to expand/collapse.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() => _expanded = !_expanded);
              _persistUiState();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.window_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _sessionName != null
                        ? '$_sessionName · ${windows.length} windows'
                        : 'tmux · ${windows.length} windows',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (alertCount > 0) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.notifications_active,
                      size: 12,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '$alertCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // Expanded window list.
          if (_expanded) ...[
            const SizedBox(height: 4),
            for (final window in windows) _buildWindowRow(theme, window),

            const SizedBox(height: 4),
            if (hasAgentSessionAccess) ...[
              // Recent AI Sessions subsection.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _showSessions = !_showSessions);
                  _persistUiState();
                  if (_showSessions) _loadRecentSessions();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI Sessions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _showSessions ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showSessions) ...[
                if (_isLoadingSessions &&
                    (_recentSessions == null || _recentSessions!.isEmpty))
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator.adaptive(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  )
                else if (_sessionLoadError != null &&
                    _recentSessions != null &&
                    _recentSessions!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _sessionLoadError!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  )
                else if (_recentSessions != null && _recentSessions!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'No recent sessions found',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else if (_recentSessions != null) ...[
                  if (_sessionLoadError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _sessionLoadError!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ..._groupSessions(_recentSessions!).entries.map(
                    (entry) =>
                        _buildSessionGroup(theme, entry.key, entry.value),
                  ),
                  if (_isLoadingSessions)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    ),
                  if (_canLoadMoreSessions)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: TextButton(
                        onPressed: _loadMoreSessions,
                        child: const Text('Load more'),
                      ),
                    ),
                ],
              ],
            ] else
              InkWell(
                onTap: () => unawaited(_handleLockedAiSessionsTap()),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.smart_toy_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'AI Sessions',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.workspace_premium,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                      const Spacer(),
                      Text(
                        'Pro',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  void _closeWindow(int windowIndex) {
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null || _sessionName == null) return;

    ref
        .read(tmuxServiceProvider)
        .killWindow(session, _sessionName!, windowIndex);

    // Optimistically remove from the list.
    setState(() {
      _windows = _windows?.where((w) => w.index != windowIndex).toList();
    });
  }

  void _switchAndOpenWindow(int windowIndex) {
    // Switch tmux to the target window before opening the terminal.
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session != null && _sessionName != null) {
      ref
          .read(tmuxServiceProvider)
          .selectWindow(session, _sessionName!, windowIndex);
    }
    widget.onTap();
  }

  Future<void> _loadRecentSessions({bool forceReload = false}) async {
    if (!_hasAgentSessionAccess) {
      return;
    }
    if (_isLoadingSessions || (_recentSessions != null && !forceReload)) return;
    final previousCount = _recentSessions?.length ?? 0;
    final loadGeneration = ++_sessionLoadGeneration;
    await _sessionDiscoverySubscription?.cancel();
    _sessionDiscoverySubscription = null;
    setState(() {
      _isLoadingSessions = true;
      _sessionLoadError = null;
      _canLoadMoreSessions = false;
    });

    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null) {
      if (mounted && loadGeneration == _sessionLoadGeneration) {
        setState(() {
          _recentSessions = const [];
          _canLoadMoreSessions = false;
          _isLoadingSessions = false;
        });
      }
      return;
    }

    try {
      final discovery = ref.read(agentSessionDiscoveryServiceProvider);
      // Scope sessions to the active tmux window's working directory
      // so results match the current project context.
      final activeWindow = _windows?.where((w) => w.isActive).firstOrNull;
      final scopeWorkingDirectory = resolveAgentSessionScopeWorkingDirectory(
        activeWorkingDirectory: activeWindow?.currentPath,
        sessionWorkingDirectory: session.workingDirectory,
      );
      _sessionDiscoverySubscription = discovery
          .discoverSessionsStream(
            session,
            workingDirectory: scopeWorkingDirectory,
            maxPerTool: _sessionFetchLimit,
          )
          .listen(
            (result) {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              setState(() {
                _recentSessions = result.sessions;
                _sessionLoadError = result.failureMessage;
              });
            },
            onError: (Object _) {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              setState(() {
                _recentSessions ??= const [];
                _sessionLoadError = 'Could not load recent AI sessions.';
                _canLoadMoreSessions = false;
                _isLoadingSessions = false;
              });
              _sessionDiscoverySubscription = null;
              _persistUiState();
            },
            onDone: () {
              if (!mounted || loadGeneration != _sessionLoadGeneration) return;
              final sessions = _recentSessions ?? const <ToolSessionInfo>[];
              setState(() {
                _canLoadMoreSessions =
                    sessions.length > previousCount &&
                    _hasSessionGroupAtLimit(sessions);
                _isLoadingSessions = false;
              });
              _sessionDiscoverySubscription = null;
              _persistUiState();
            },
            cancelOnError: true,
          );
    } on Exception {
      if (!mounted || loadGeneration != _sessionLoadGeneration) return;
      setState(() {
        _recentSessions ??= const [];
        _sessionLoadError = 'Could not load recent AI sessions.';
        _canLoadMoreSessions = false;
        _isLoadingSessions = false;
      });
      _sessionDiscoverySubscription = null;
      _persistUiState();
    }
  }

  void _loadMoreSessions() {
    if (_isLoadingSessions) return;
    setState(() => _sessionFetchLimit += _sessionFetchStep);
    _persistUiState();
    _loadRecentSessions(forceReload: true);
  }

  bool _hasSessionGroupAtLimit(List<ToolSessionInfo> sessions) {
    final countsByTool = <String, int>{};
    for (final session in sessions) {
      countsByTool.update(
        session.toolName,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return countsByTool.values.any((count) => count >= _sessionFetchLimit);
  }

  void _resumeSession(ToolSessionInfo info) {
    if (!_hasAgentSessionAccess) {
      unawaited(_handleLockedAiSessionsTap());
      return;
    }
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(widget.connectionId);
    if (session == null || _sessionName == null) return;

    final discovery = ref.read(agentSessionDiscoveryServiceProvider);
    final command = discovery.buildResumeCommand(info);
    final tmux = ref.read(tmuxServiceProvider);
    tmux
        .createWindow(
          session,
          _sessionName!,
          command: command,
          name: info.toolName,
          workingDirectory: info.workingDirectory,
        )
        .then((_) => widget.onTap())
        .ignore();
  }

  Map<String, List<ToolSessionInfo>> _groupSessions(
    List<ToolSessionInfo> sessions,
  ) {
    final grouped = <String, List<ToolSessionInfo>>{};
    for (final session in sessions) {
      grouped
          .putIfAbsent(session.toolName, () => <ToolSessionInfo>[])
          .add(session);
    }
    return grouped;
  }

  Widget _buildSessionGroup(
    ThemeData theme,
    String toolName,
    List<ToolSessionInfo> sessions,
  ) {
    final isExpanded = _expandedSessionTools.contains(toolName);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedSessionTools.remove(toolName);
              } else {
                _expandedSessionTools.add(toolName);
              }
            });
            _persistUiState();
          },
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            child: Row(
              children: [
                Icon(
                  _toolIconData(toolName),
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    toolName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${sessions.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          for (final session in sessions)
            _buildSessionRow(theme, session, indent: 20),
      ],
    );
  }

  Widget _buildSessionRow(
    ThemeData theme,
    ToolSessionInfo info, {
    double indent = 0,
  }) {
    final iconData = _toolIconData(info.toolName);

    return InkWell(
      onTap: () => _resumeSession(info),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.fromLTRB(6 + indent, 6, 6, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(iconData, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    info.summary ?? info.sessionId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (info.lastUpdatedLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        info.lastUpdatedLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _toolIconData(String toolName) => switch (toolName) {
    'Claude Code' => Icons.auto_awesome,
    'Codex' => Icons.code,
    'Copilot CLI' => Icons.flight,
    'Gemini CLI' => Icons.diamond_outlined,
    'OpenCode' => Icons.terminal,
    _ => Icons.smart_toy_outlined,
  };

  Widget _buildWindowRow(ThemeData theme, TmuxWindow window) {
    final title = window.displayTitle;

    return InkWell(
      onTap: () => _switchAndOpenWindow(window.index),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Row(
          children: [
            // Window index badge.
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: window.isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.center,
              child: Text(
                '${window.index}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: window.isActive
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Alert icon.
            if (window.hasAlert)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.notifications_active,
                  size: 12,
                  color: theme.colorScheme.error,
                ),
              ),
            // Title — truncated.
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: window.isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                  fontWeight: window.isActive
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6),
              child: TmuxWindowStatusBadge(window: window),
            ),
            // Close button.
            GestureDetector(
              onTap: () => _closeWindow(window.index),
              child: Icon(
                Icons.close,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
