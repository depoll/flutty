import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_clipboard_sync_service.dart';

void main() {
  group('RemoteClipboardSyncService', () {
    test('canSyncText rejects oversized content', () {
      final text = 'a' * (1024 * 1024 + 1);
      expect(RemoteClipboardSyncService.canSyncText(text), isFalse);
    });

    test('buildReadCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildReadCommand();
      expect(command, contains('pbpaste'));
      expect(command, contains('wl-paste'));
      expect(command, contains('xclip'));
      expect(command, contains('xsel'));
    });

    test('buildWriteCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildWriteCommand('hello');
      expect(command, contains('pbcopy'));
      expect(command, contains('wl-copy'));
      expect(command, contains('xclip -selection clipboard'));
      expect(command, contains('xsel --clipboard --input'));
    });

    test('parseReadOutput decodes clipboard payload', () {
      final result = RemoteClipboardSyncService.parseReadOutput('aGVsbG8=');
      expect(result.supported, isTrue);
      expect(result.text, 'hello');
    });

    test('parseReadOutput detects unsupported clipboard', () {
      final result = RemoteClipboardSyncService.parseReadOutput(
        RemoteClipboardSyncService.unsupportedMarker,
      );
      expect(result.supported, isFalse);
      expect(result.text, isEmpty);
    });
  });
}
