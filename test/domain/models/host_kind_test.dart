import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/host_kind.dart';

void main() {
  group('hostKindFromStorage', () {
    test('defaults unknown and null values to ssh', () {
      expect(hostKindFromStorage(null), HostKind.ssh);
      expect(hostKindFromStorage(''), HostKind.ssh);
      expect(hostKindFromStorage('mystery'), HostKind.ssh);
      expect(hostKindFromStorage('ssh'), HostKind.ssh);
      expect(hostKindFromStorage('LOCAL'), HostKind.local);
    });
  });

  group('isLocalTerminalSupported', () {
    test('supports desktop and Android platforms', () {
      expect(isLocalTerminalSupported(platform: TargetPlatform.macOS), isTrue);
      expect(
        isLocalTerminalSupported(platform: TargetPlatform.windows),
        isTrue,
      );
      expect(isLocalTerminalSupported(platform: TargetPlatform.linux), isTrue);
      expect(
        isLocalTerminalSupported(platform: TargetPlatform.android),
        isTrue,
      );
      expect(isLocalTerminalSupported(platform: TargetPlatform.iOS), isFalse);
    });
  });

  group('defaultLocalTerminalHostLabel', () {
    test('uses platform-specific wording', () {
      expect(
        defaultLocalTerminalHostLabel(platform: TargetPlatform.macOS),
        'This Mac',
      );
      expect(
        defaultLocalTerminalHostLabel(platform: TargetPlatform.windows),
        'This PC',
      );
      expect(
        defaultLocalTerminalHostLabel(platform: TargetPlatform.android),
        'This Android device',
      );
    });
  });
}
