// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';

void main() {
  AcpSessionState base({
    AcpConnectionStatus status = AcpConnectionStatus.ready,
    bool attached = true,
  }) => AcpSessionState(
    key: AcpSessionKey.of(
      hostId: 1,
      providerId: 'copilot',
      bridgeId: 'b',
      acpSessionId: 's',
    ),
    providerLabel: 'Copilot CLI',
    cwd: '/repo',
    status: status,
    attached: attached,
    createdAt: DateTime.utc(2024),
    lastActivityAt: DateTime.utc(2024),
  );

  group('isLive', () {
    test('ready and attached is live', () {
      expect(base().isLive, isTrue);
    });

    test('detached is not live even when the status is otherwise active', () {
      expect(
        base(status: AcpConnectionStatus.reconnecting, attached: false).isLive,
        isFalse,
      );
    });

    test('terminal statuses are never live', () {
      for (final status in [
        AcpConnectionStatus.detached,
        AcpConnectionStatus.bridgeExpired,
        AcpConnectionStatus.providerExited,
        AcpConnectionStatus.failed,
        AcpConnectionStatus.closed,
      ]) {
        expect(base(status: status).isLive, isFalse, reason: status.name);
      }
    });

    test('connecting/initializing/reconnecting are live while attached', () {
      for (final status in [
        AcpConnectionStatus.connecting,
        AcpConnectionStatus.initializing,
        AcpConnectionStatus.authenticationRequired,
        AcpConnectionStatus.reconnecting,
      ]) {
        expect(base(status: status).isLive, isTrue, reason: status.name);
      }
    });
  });

  group('copyWith', () {
    test('clears nullable fields explicitly', () {
      final withTitle = base().copyWith(title: 'Hello');
      expect(withTitle.title, 'Hello');
      expect(withTitle.copyWith(clearTitle: true).title, isNull);
    });

    test('preserves identity fields', () {
      final next = base().copyWith(status: AcpConnectionStatus.failed);
      expect(next.key, base().key);
      expect(next.createdAt, base().createdAt);
      expect(next.status, AcpConnectionStatus.failed);
    });
  });

  group('defensive lists', () {
    test('copies the caller list and exposes an unmodifiable view', () {
      final commands = <AcpAvailableCommand>[
        const AcpAvailableCommand(name: 'review', description: 'Review'),
      ];
      final state = base().copyWith(availableCommands: commands);
      // Mutating the caller list must not affect the constructed state.
      commands.clear();
      expect(state.availableCommands, hasLength(1));
      // The exposed list itself is unmodifiable.
      expect(
        () => state.availableCommands.add(
          const AcpAvailableCommand(name: 'x', description: 'y'),
        ),
        throwsUnsupportedError,
      );
    });

    test('defends the pending permissions list', () {
      final pending = <AcpPendingPermission>[
        AcpPendingPermission(
          requestKey: 'r1',
          sessionId: 's',
          toolCallId: 't',
          options: const [],
          requestedAt: DateTime.utc(2024),
        ),
      ];
      final state = base().copyWith(pendingPermissions: pending);
      pending.clear();
      expect(state.pendingPermissions, hasLength(1));
      expect(state.pendingPermissions.clear, throwsUnsupportedError);
    });
  });
}
