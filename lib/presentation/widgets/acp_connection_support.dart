import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/models/acp_provider.dart';
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

  for (final candidate in provider.executableProbe.candidateExecutableNames) {
    final executable = found[candidate];
    if (executable != null) {
      return (
        override: AcpLaunchCommand(
          executable: executable,
          arguments: provider.launchCommand.arguments,
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
