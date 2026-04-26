import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';

void main() {
  group('DiagnosticsLogService', () {
    test('does not retain entries when disabled', () {
      final log = DiagnosticsLogService(enabled: false)
        ..info('ssh', 'connect_start', fields: {'hostId': 1});

      expect(log.entryCount, 0);
      expect(log.snapshot(), isEmpty);
    });

    test('redacts sensitive fields and unsafe string values', () {
      final log =
          DiagnosticsLogService(
            enabled: true,
            now: () => DateTime.utc(2026, 4, 26, 12),
          )..info(
            'ssh',
            'connect_start',
            fields: {
              'hostId': 7,
              'hostname': 'secret.example.com',
              'username': 'depoll',
              'command': 'tmux attach -t private',
              'path': '/Users/depoll/project',
              'state': DiagnosticsLogLevel.info,
              'errorType': 'TimeoutException',
            },
          );

      final formatted = log.snapshot().single.format();

      expect(formatted, contains('hostId=7'));
      expect(formatted, contains('hostname=[redacted]'));
      expect(formatted, contains('username=[redacted]'));
      expect(formatted, contains('command=[redacted]'));
      expect(formatted, contains('path=[redacted]'));
      expect(formatted, contains('state=info'));
      expect(formatted, contains('errorType=TimeoutException'));
      expect(formatted, isNot(contains('secret.example.com')));
      expect(formatted, isNot(contains('depoll')));
      expect(formatted, isNot(contains('/Users/depoll/project')));
    });

    test('keeps a bounded ring buffer', () {
      final log = DiagnosticsLogService(enabled: true, maxEntries: 2)
        ..info('test', 'first')
        ..info('test', 'second')
        ..info('test', 'third');

      final lines = log.snapshot().map((entry) => entry.message).toList();
      expect(lines, ['second', 'third']);
    });

    test('exports a privacy notice with entries', () {
      final log = DiagnosticsLogService(
        enabled: true,
        now: () => DateTime.utc(2026, 4, 26, 12),
      )..warning('tmux.watch', 'restart_scheduled', fields: {'attempt': 2});

      final exported = log.exportText();

      expect(exported, contains('MonkeySSH diagnostics'));
      expect(exported, contains('entryCount=1'));
      expect(exported, contains('Privacy:'));
      expect(exported, contains('tmux.watch restart_scheduled attempt=2'));
    });
  });
}
