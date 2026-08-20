import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_launch_preset.dart';
import 'agent_tool_icon.dart';
import 'cursor_block.dart';

/// Immediate, terminal-native feedback while a native ACP session starts.
class AcpNativeStartingView extends StatelessWidget {
  /// Creates a startup viewport for [providerLabel].
  const AcpNativeStartingView({
    required this.providerLabel,
    required this.detail,
    required this.resuming,
    this.tool,
    super.key,
  });

  /// Human-readable provider identity.
  final String providerLabel;

  /// Current startup phase description.
  final String detail;

  /// Whether an existing provider session is being resumed.
  final bool resuming;

  /// Branded terminal tool, when known.
  final AgentLaunchTool? tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final action = resuming ? 'resuming' : 'starting';
    return Semantics(
      key: const ValueKey<String>('native-agent-starting'),
      container: true,
      liveRegion: true,
      label: '$action $providerLabel. $detail',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AgentToolIcon(
                  tool: tool,
                  toolName: providerLabel,
                  size: 34,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CursorBlock(size: 22),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Flexible(
                      child: Text(
                        '$action $providerLabel',
                        textAlign: TextAlign.center,
                        style: FluttyTheme.monoStyle.copyWith(
                          color: colorScheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: FluttyTheme.spacingSm),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
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
