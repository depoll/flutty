import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/services/acp_launch_profile_service.dart';
import '../../domain/services/monkeymux_acp_bridge_service.dart';
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/windows_remote_powershell.dart';
import 'connection_attempt_dialog.dart';

/// Reuses an active SSH session for [hostId], or connects through the standard
/// progress and error surface when the host is currently disconnected.
Future<SshConnectionResult> ensureAcpHostConnection(
  BuildContext context,
  WidgetRef ref,
  int hostId, {
  Host? knownHost,
}) async {
  final active = ref.read(sshServiceProvider).getSessionsForHost(hostId);
  if (active.isNotEmpty) {
    return SshConnectionResult(
      success: true,
      connectionId: active.first.connectionId,
      reusedConnection: true,
    );
  }

  final host =
      knownHost ?? await ref.read(hostRepositoryProvider).getById(hostId);
  if (host == null) {
    return const SshConnectionResult(
      success: false,
      error: 'This saved host is no longer available.',
    );
  }
  if (!context.mounted) {
    return const SshConnectionResult(
      success: false,
      error: 'The connection was canceled.',
    );
  }
  return connectToHostWithProgressDialog(context, ref, host, forceNew: false);
}

/// Resolves and confirms the exact remote command used for a built-in ACP
/// provider, regardless of which launch surface initiated the session.
///
/// Only absolute external executable paths survive the probe. Shell aliases and
/// functions are ignored, and adapter fallbacks remain pinned to their bundled
/// arguments.
Future<({AcpLaunchCommand? override, bool terminal})?>
resolveAcpRemoteProviderLaunch({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
  required bool canUseTerminalCli,
  bool startInYoloMode = false,
}) async {
  final requested = <String>{
    ...provider.executableProbe.candidateExecutableNames,
    if (provider.adapterFallbackCommand case final fallback?)
      fallback.executable,
  };
  final command = session.remoteIsWindows
      ? buildWindowsPowerShellCommand(
          buildMonkeyMuxAcpWindowsExecutableProbeScript(requested),
        )
      : buildMonkeyMuxAcpExecutableProbeCommand(requested);
  final found = await session.runQueuedExec(() async {
    SSHSession? shell;
    try {
      shell = await session.execute(command);
      shell.stderr.drain<void>().ignore();
      final output = await utf8.decodeStream(shell.stdout);
      await shell.done;
      return parseMonkeyMuxAcpExecutableProbeOutput(output, requested);
    } finally {
      shell?.close();
    }
  });

  if (!context.mounted) return null;
  for (final candidate in provider.executableProbe.candidateExecutableNames) {
    final executable = found[candidate];
    if (executable != null) {
      final resolved = AcpLaunchCommand(
        executable: executable,
        arguments: provider.launchCommand.arguments,
      );
      final profiled = await resolveAcpLaunchProfile(
        context: context,
        session: session,
        provider: provider,
        resolvedCommand: resolved,
      );
      if (profiled == null) return null;
      return (
        override: applyAcpAgentLaunchSettings(
          provider: provider,
          command: profiled,
          startInYoloMode: startInYoloMode,
        ),
        terminal: false,
      );
    }
  }

  final fallback = provider.adapterFallbackCommand;
  final fallbackExecutable = fallback == null
      ? null
      : found[fallback.executable];
  final fallbackOverride = fallback == null || fallbackExecutable == null
      ? null
      : AcpLaunchCommand(
          executable: fallbackExecutable,
          arguments: fallback.arguments,
        );
  if (!context.mounted) return null;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        fallback == null
            ? '${provider.label} unavailable'
            : '${provider.label} adapter required',
      ),
      content: Text(
        fallbackOverride != null
            ? 'The ACP adapter is not installed. MonkeySSH can run the pinned adapter with npx:\n\n${fallback!.argv.join(' ')}'
            : fallback == null
            ? 'The native provider executable is not available in this host’s interactive shell.'
            : 'The ACP adapter is not installed and npx is unavailable on this host.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: const Text('Cancel'),
        ),
        if (canUseTerminalCli)
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'terminal'),
            child: const Text('Use terminal CLI'),
          ),
        if (fallbackOverride != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, 'adapter'),
            child: const Text('Run adapter'),
          ),
      ],
    ),
  );
  return switch (choice) {
    'adapter' => (override: fallbackOverride, terminal: false),
    'terminal' => (override: null, terminal: true),
    _ => null,
  };
}

/// Applies global terminal-agent settings before a provider's ACP entrypoint.
///
/// Direct ACP implementations use the same profile/YOLO argument plan as their
/// terminal CLI. Adapter executables keep their pinned argv; native YOLO still
/// applies generically when MonkeySSH answers ACP permission requests.
AcpLaunchCommand applyAcpAgentLaunchSettings({
  required AcpBuiltinProvider provider,
  required AcpLaunchCommand command,
  required bool startInYoloMode,
}) {
  if (!startInYoloMode) return command;
  final tool = agentLaunchToolForBuiltinAcpProviderId(provider.id);
  if (tool == null ||
      !_isResolvedTerminalExecutable(tool, command.executable)) {
    return command;
  }
  final profileSupport = provider.launchProfileSupport;
  String? profile;
  if (profileSupport != null &&
      command.arguments.length >= 2 &&
      command.arguments.first == profileSupport.profileOption) {
    profile = command.arguments[1];
  }
  return AcpLaunchCommand(
    executable: command.executable,
    arguments: <String>[
      ...buildAgentGlobalLaunchArguments(
        tool,
        startInYoloMode: true,
        launchProfile: profile,
        quoteProfileForShell: false,
      ),
      ...provider.launchCommand.arguments,
    ],
  );
}

bool _isResolvedTerminalExecutable(AgentLaunchTool tool, String executable) {
  var name = executable.replaceAll(r'\\', '/').split('/').last.toLowerCase();
  name = name.replaceFirst(RegExp(r'\.(?:exe|cmd|bat|ps1|com)$'), '');
  return tool.candidateCommandNames.any(
    (candidate) => candidate.toLowerCase() == name,
  );
}

/// Discovers and, when necessary, asks which isolated provider profile to use.
///
/// The returned profile is shared by terminal and native launches. Discovery
/// failures and a single profile preserve one-tap launch; `null` means the user
/// explicitly cancelled a picker containing multiple profiles.
Future<AcpLaunchProfile?> selectAcpLaunchProfile({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
}) async {
  final support = provider.launchProfileSupport;
  if (support == null) {
    return const AcpLaunchProfile(argument: null, label: 'Default');
  }

  List<AcpLaunchProfile> profiles;
  try {
    final discoveryCommand = buildAcpLaunchProfileDiscoveryCommand(
      support: support,
      isWindows: session.remoteIsWindows,
    );
    final output = await session.runQueuedExec(() async {
      SSHSession? shell;
      try {
        shell = await session.execute(discoveryCommand);
        shell.stderr.drain<void>().ignore();
        final stdout = await utf8.decodeStream(shell.stdout);
        await shell.done;
        return stdout;
      } finally {
        shell?.close();
      }
    });
    profiles = parseAcpLaunchProfiles(output, support);
  } on Object {
    profiles = parseAcpLaunchProfiles('', support);
  }

  if (profiles.length <= 1) return profiles.single;
  if (!context.mounted) return null;
  return showAcpLaunchProfilePicker(
    context: context,
    providerLabel: provider.label,
    profiles: profiles,
  );
}

/// Applies the shared launch-profile choice to a resolved ACP executable.
Future<AcpLaunchCommand?> resolveAcpLaunchProfile({
  required BuildContext context,
  required SshSession session,
  required AcpBuiltinProvider provider,
  required AcpLaunchCommand resolvedCommand,
}) async {
  final support = provider.launchProfileSupport;
  if (support == null) return resolvedCommand;
  final selected = await selectAcpLaunchProfile(
    context: context,
    session: session,
    provider: provider,
  );
  if (selected == null) return null;
  return support.apply(resolvedCommand, selected.argument);
}

/// Shows the one-handed launch-profile chooser used by profile-aware agents.
Future<AcpLaunchProfile?> showAcpLaunchProfilePicker({
  required BuildContext context,
  required String providerLabel,
  required List<AcpLaunchProfile> profiles,
}) => showModalBottomSheet<AcpLaunchProfile>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) {
    final theme = Theme.of(sheetContext);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose $providerLabel profile',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Select the isolated profile for this native session.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: profiles.length,
              itemBuilder: (context, index) {
                final profile = profiles[index];
                return ListTile(
                  leading: Icon(
                    profile.argument == null || profile.label == 'Default'
                        ? Icons.settings_outlined
                        : Icons.account_tree_outlined,
                  ),
                  title: Text(
                    profile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: profile.isActive
                      ? Text(
                          'Current',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : null,
                  onTap: () => Navigator.pop(sheetContext, profile),
                );
              },
            ),
          ),
        ],
      ),
    );
  },
);

/// Requests permission to install or update the bundled MonkeyMux helper used
/// by persistent ACP sessions.
Future<bool> confirmAcpMonkeyMuxInstall(
  BuildContext context,
  MonkeyMuxInstallRequest request,
) async {
  if (!context.mounted) {
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Install or update MonkeyMux?'),
      content: Text(
        'Agent sessions use MonkeyMux ${request.version} on this host so work '
        'can survive reconnects. The bundled ${request.platform} helper will '
        'be installed in your user account.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
