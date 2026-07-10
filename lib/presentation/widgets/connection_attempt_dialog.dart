import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/ssh_service.dart';

enum _ConnectionAttemptDialogOutcome { editHost }

/// Runs a host connection while showing a live progress dialog.
Future<SshConnectionResult> connectToHostWithProgressDialog(
  BuildContext context,
  WidgetRef ref,
  Host host, {
  bool forceNew = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
  final monetizationState =
      ref.read(monetizationStateProvider).asData?.value ??
      ref.read(monetizationServiceProvider).currentState;
  final useHostThemeOverrides = monetizationState.allowsFeature(
    MonetizationFeature.hostSpecificThemes,
  );
  var result = const SshConnectionResult(
    success: false,
    error: 'Connection cancelled.',
  );
  var connectionInProgress = false;
  var dialogIsActive = true;

  Future<void> runConnection({required bool isRetry}) async {
    if (connectionInProgress) {
      return;
    }
    connectionInProgress = true;
    try {
      result = await sessionsNotifier.connect(
        host.id,
        forceNew: isRetry || forceNew,
        useHostThemeOverrides: useHostThemeOverrides,
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'connection_attempt_dialog',
          context: ErrorDescription('while connecting to host ${host.id}'),
        ),
      );
      const message =
          'Connection failed. Check the host settings and try again.';
      sessionsNotifier.reportConnectionAttemptError(host.id, message);
      result = const SshConnectionResult(success: false, error: message);
    } finally {
      connectionInProgress = false;
    }

    if (result.success &&
        result.connectionId != null &&
        dialogIsActive &&
        navigator.mounted) {
      navigator.pop();
    }
  }

  final dialogFuture = showDialog<_ConnectionAttemptDialogOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ConnectionAttemptDialog(
      host: host,
      onRetry: () => runConnection(isRetry: true),
    ),
  );
  final trackedDialogFuture = dialogFuture.whenComplete(() {
    dialogIsActive = false;
  });

  await runConnection(isRetry: false);
  final outcome = await trackedDialogFuture;
  sessionsNotifier.clearConnectionAttempt(host.id);
  if (outcome == _ConnectionAttemptDialogOutcome.editHost && context.mounted) {
    await context.push('/hosts/edit/${host.id}');
  }
  return result;
}

class _ConnectionAttemptDialog extends ConsumerStatefulWidget {
  const _ConnectionAttemptDialog({required this.host, required this.onRetry});

  final Host host;
  final Future<void> Function() onRetry;

  @override
  ConsumerState<_ConnectionAttemptDialog> createState() =>
      _ConnectionAttemptDialogState();
}

class _ConnectionAttemptDialogState
    extends ConsumerState<_ConnectionAttemptDialog> {
  bool _isRetrying = false;

  Future<void> _retry() async {
    if (_isRetrying) {
      return;
    }
    setState(() => _isRetrying = true);
    await widget.onRetry();
    if (mounted) {
      setState(() => _isRetrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeSessionsProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final attempt = sessionsNotifier.getConnectionAttempt(widget.host.id);
    final connectionState = attempt?.state ?? SshConnectionState.connecting;
    final logLines = attempt?.logLines ?? const ['Preparing connection…'];
    final statusMessage = attempt?.latestMessage ?? 'Preparing connection…';
    final hasError = connectionState == SshConnectionState.error;

    return PopScope(
      canPop: hasError && !_isRetrying,
      child: AlertDialog(
        title: Text(
          hasError && !_isRetrying
              ? 'Connection failed'
              : 'Connecting to ${widget.host.label}',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.host.username}@${widget.host.hostname}:'
                '${widget.host.port}',
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ConnectionAttemptIcon(state: connectionState),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      statusMessage,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (hasError) ...[
                const SizedBox(height: 8),
                Text(
                  connectionFailureRecoveryHint(statusMessage),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Connection log',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final line in logLines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          line,
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurface,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (hasError) ...[
            TextButton(
              onPressed: _isRetrying ? null : () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            OutlinedButton(
              onPressed: _isRetrying
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop(_ConnectionAttemptDialogOutcome.editHost),
              child: const Text('Edit Host'),
            ),
            FilledButton(
              onPressed: _isRetrying ? null : () => unawaited(_retry()),
              child: Text(_isRetrying ? 'Retrying…' : 'Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Returns concise recovery guidance for a failed connection message.
@visibleForTesting
String connectionFailureRecoveryHint(String message) {
  final normalized = message.toLowerCase();
  if (normalized.contains('host key')) {
    return 'Review the host key details before retrying.';
  }
  if (normalized.contains('auth') ||
      normalized.contains('password') ||
      normalized.contains('credential') ||
      normalized.contains('private key')) {
    return 'Check the username, password, and SSH key, then retry.';
  }
  if (normalized.contains('timeout') ||
      normalized.contains('timed out') ||
      normalized.contains('network') ||
      normalized.contains('socket') ||
      normalized.contains('refused') ||
      normalized.contains('unreachable')) {
    return 'Check the hostname, port, and network, then retry.';
  }
  if (normalized.contains('setup') ||
      normalized.contains('startup') ||
      normalized.contains('command')) {
    return 'Check this host\'s startup settings, then retry.';
  }
  return 'Retry now or edit the host settings before trying again.';
}

class _ConnectionAttemptIcon extends StatelessWidget {
  const _ConnectionAttemptIcon({required this.state});

  final SshConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (state) {
      SshConnectionState.connected => Icon(
        Icons.check_circle,
        color: colorScheme.primary,
      ),
      SshConnectionState.error => Icon(
        Icons.error_outline,
        color: colorScheme.error,
      ),
      SshConnectionState.authenticating => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: colorScheme.primary,
        ),
      ),
      _ => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: colorScheme.primary,
        ),
      ),
    };
  }
}
