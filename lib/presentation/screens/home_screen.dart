import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../domain/services/ssh_service.dart';

/// The main home screen - Termius-style sidebar layout.
class HomeScreen extends ConsumerStatefulWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedIndex = 0;

  // Breakpoint for switching between mobile and desktop layout
  static const double _mobileBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
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
          const Text('MonkeySSH'),
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
          icon: Icon(Icons.key_outlined),
          selectedIcon: Icon(Icons.key_rounded),
          label: 'Keys',
        ),
        NavigationDestination(
          icon: Icon(Icons.code_outlined),
          selectedIcon: Icon(Icons.code_rounded),
          label: 'Snippets',
        ),
        NavigationDestination(
          icon: Icon(Icons.swap_horiz_outlined),
          selectedIcon: Icon(Icons.swap_horiz_rounded),
          label: 'Ports',
        ),
      ],
    ),
  );

  Widget _buildDesktopLayout() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Row(
        children: [
          // Sidebar navigation
          Container(
            width: 220,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F0F14) : Colors.grey.shade50,
              border: Border(
                right: BorderSide(color: colorScheme.outline.withAlpha(60)),
              ),
            ),
            child: Column(
              children: [
                // App header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.asset(
                          'assets/icons/monkeyssh_icon.png',
                          width: 28,
                          height: 28,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'MonkeySSH',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Navigation items
                _NavItem(
                  icon: Icons.dns_rounded,
                  label: 'Hosts',
                  selected: _selectedIndex == 0,
                  onTap: () => setState(() => _selectedIndex = 0),
                ),
                _NavItem(
                  icon: Icons.key_rounded,
                  label: 'Keys',
                  selected: _selectedIndex == 1,
                  onTap: () => setState(() => _selectedIndex = 1),
                ),
                _NavItem(
                  icon: Icons.code_rounded,
                  label: 'Snippets',
                  selected: _selectedIndex == 2,
                  onTap: () => setState(() => _selectedIndex = 2),
                ),
                _NavItem(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Port Forwarding',
                  selected: _selectedIndex == 3,
                  onTap: () => setState(() => _selectedIndex = 3),
                ),

                const Spacer(),

                // Settings at bottom
                _NavItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  selected: false,
                  onTap: () => context.push('/settings'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),

          // Main content
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedIndex) {
      case 0:
        return const _HostsPanel();
      case 1:
        return const _KeysPanel();
      case 2:
        return _buildPlaceholder('Snippets', Icons.code_rounded, '/snippets');
      case 3:
        return _buildPlaceholder(
          'Port Forwarding',
          Icons.swap_horiz_rounded,
          '/port-forwards',
        );
      default:
        return const _HostsPanel();
    }
  }

  Widget _buildPlaceholder(String title, IconData icon, String route) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: theme.colorScheme.primary.withAlpha(100)),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => context.push(route),
            child: Text('Open $title'),
          ),
        ],
      ),
    );
  }
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? colorScheme.primary.withAlpha(isDark ? 25 : 20)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurface.withAlpha(200),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

class _HostsPanel extends ConsumerWidget {
  const _HostsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostsAsync = ref.watch(_allHostsStreamProvider);

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

        // Hosts list
        Expanded(
          child: hostsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (hosts) => hosts.isEmpty
                ? _buildEmptyState(context)
                : _buildHostsList(context, ref, hosts),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No hosts yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add a host to get started',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/hosts/add'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Host'),
          ),
        ],
      ),
    );
  }

  Widget _buildHostsList(
    BuildContext context,
    WidgetRef ref,
    List<Host> hosts,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: hosts.length,
    itemBuilder: (context, index) {
      final host = hosts[index];
      return _HostRow(host: host);
    },
  );
}

class _HostRow extends ConsumerWidget {
  const _HostRow({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final connectionStates = ref.watch(activeSessionsProvider);
    final isConnected =
        connectionStates[host.id] == SshConnectionState.connected;
    final isConnecting =
        connectionStates[host.id] == SshConnectionState.connecting;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/terminal/${host.id}'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Status indicator
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected
                      ? colorScheme.primary
                      : isConnecting
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
                  ],
                ),
              ),

              // Port badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

              // Actions
              _SmallIconButton(
                icon: Icons.edit_outlined,
                onTap: () => context.push('/hosts/edit/${host.id}'),
              ),
              _SmallIconButton(
                icon: Icons.more_vert,
                onTap: () => _showMenu(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Duplicate'),
              onTap: () {
                Navigator.pop(context);
                // TODO: duplicate
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colorScheme.error),
              title: Text('Delete', style: TextStyle(color: colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context, ref);
              },
            ),
          ],
        ),
      ),
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
  const _SmallIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 16,
          color: colorScheme.onSurface.withAlpha(100),
        ),
      ),
    );
  }
}

/// Provider for all hosts as stream.
final _allHostsStreamProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});

/// Provider for all keys as stream.
final _allKeysStreamProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});

class _KeysPanel extends ConsumerWidget {
  const _KeysPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keysAsync = ref.watch(_allKeysStreamProvider);

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

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.key_outlined,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No SSH keys yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Generate or import a key',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/keys/add'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Key'),
          ),
        ],
      ),
    );
  }

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

              // Copy public key button
              _SmallIconButton(
                icon: Icons.copy,
                onTap: () => _copyPublicKey(context),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
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
