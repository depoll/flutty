import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../domain/services/ssh_service.dart';

/// Tab bar for managing multiple terminal sessions.
class TerminalTabBar extends ConsumerWidget {
  /// Creates a new [TerminalTabBar].
  const TerminalTabBar({
    required this.activeHostId,
    required this.onTabSelected,
    required this.onTabClosed,
    required this.onNewTab,
    super.key,
  });

  /// Currently active host ID.
  final int? activeHostId;

  /// Callback when a tab is selected.
  final void Function(int hostId) onTabSelected;

  /// Callback when a tab is closed.
  final void Function(int hostId) onTabClosed;

  /// Callback to add a new tab.
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionStates = ref.watch(activeSessionsProvider);
    final sshService = ref.read(sshServiceProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (sessionStates.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: sessionStates.length,
              itemBuilder: (context, index) {
                final hostId = sessionStates.keys.elementAt(index);
                final connectionState = sessionStates[hostId]!;
                final session = sshService.getSession(hostId);
                final isActive = hostId == activeHostId;
                final isConnected =
                    connectionState == SshConnectionState.connected;

                return _TerminalTab(
                  label: session?.config.hostname ?? 'Host $hostId',
                  isActive: isActive,
                  isConnected: isConnected,
                  onTap: () => onTabSelected(hostId),
                  onClose: () => onTabClosed(hostId),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            onPressed: onNewTab,
            tooltip: 'New connection',
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _TerminalTab extends StatelessWidget {
  const _TerminalTab({
    required this.label,
    required this.isActive,
    required this.isConnected,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final bool isActive;
  final bool isConnected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 100, maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? colorScheme.surface : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isActive ? colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isConnected ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                  color: isActive
                      ? colorScheme.onSurface
                      : colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Provider for the active tab's host ID.
final activeTabProvider = StateProvider<int?>((ref) => null);
