import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/services/host_key_verification.dart';

/// Shows a blocking trust prompt for SSH host-key verification.
Future<HostKeyTrustDecision> showHostKeyTrustDialog({
  required BuildContext context,
  required HostKeyVerificationRequest request,
}) async {
  final decision = await showDialog<HostKeyTrustDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _HostKeyTrustDialog(request: request),
  );
  return decision ?? HostKeyTrustDecision.reject;
}

class _HostKeyTrustDialog extends StatelessWidget {
  const _HostKeyTrustDialog({required this.request});

  final HostKeyVerificationRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isReplacement = request.isReplacement;
    final title = isReplacement ? 'Host key changed' : 'Verify host identity';
    final actionLabel = isReplacement ? 'Replace trusted key' : 'Trust host';
    final action = isReplacement
        ? HostKeyTrustDecision.replace
        : HostKeyTrustDecision.trust;

    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isReplacement
                    ? 'The server presented a different SSH host key than the '
                          'one previously trusted for this destination.'
                    : 'This host has not been seen before. Verify the server\'s '
                          'SSH host key before continuing.',
              ),
              const SizedBox(height: 16),
              _HostKeyDetailsCard(
                title: 'Presented by ${request.hostLabel}',
                keyType: request.presentedHostKey.keyType,
                fingerprint: request.presentedHostKey.fingerprint,
              ),
              if (request.existingKnownHost case final knownHost?) ...[
                const SizedBox(height: 12),
                _HostKeyDetailsCard(
                  title: 'Previously trusted',
                  keyType: knownHost.keyType,
                  fingerprint: knownHost.fingerprint,
                  emphasized: false,
                ),
              ],
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isReplacement
                      ? colorScheme.errorContainer
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isReplacement
                        ? colorScheme.error
                        : colorScheme.outlineVariant,
                  ),
                ),
                child: Text(
                  isReplacement
                      ? 'If you were not expecting this change, reject the '
                            'connection and investigate a possible MITM or '
                            'server reinstallation.'
                      : 'Only trust this host if the fingerprint matches a '
                            'value you verified out-of-band.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isReplacement
                        ? colorScheme.onErrorContainer
                        : colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(HostKeyTrustDecision.reject),
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(action),
          child: Text(actionLabel),
        ),
      ],
    );
  }
}

class _HostKeyDetailsCard extends StatelessWidget {
  const _HostKeyDetailsCard({
    required this.title,
    required this.keyType,
    required this.fingerprint,
    this.emphasized = true,
  });

  final String title;
  final String keyType;
  final String fingerprint;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: emphasized
            ? colorScheme.surfaceContainerHighest
            : colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Type',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(keyType, style: FluttyTheme.monoStyle.copyWith(fontSize: 12)),
          const SizedBox(height: 12),
          Text(
            'Fingerprint',
            style: theme.textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            fingerprint,
            style: FluttyTheme.monoStyle.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
