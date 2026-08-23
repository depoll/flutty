import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/monetization.dart';

void main() {
  group('concurrent ACP session monetization', () {
    test('describes only the concurrent-session upgrade boundary', () {
      const feature = MonetizationFeature.concurrentAcpSessions;

      expect(feature.label, 'Parallel native chats');
      expect(feature.description, contains('multiple native agent chats'));
      expect(feature.blockedAction, contains('another native agent chat'));
      expect(feature.blockedOutcome, contains('multiple native chats'));
      expect(feature.blockedOutcome, contains('fork active sessions'));
    });

    test('free and Pro entitlements follow the shared feature policy', () {
      expect(
        const MonetizationEntitlements.free().allows(
          MonetizationFeature.concurrentAcpSessions,
        ),
        isFalse,
      );
      expect(
        const MonetizationEntitlements.pro().allows(
          MonetizationFeature.concurrentAcpSessions,
        ),
        isTrue,
      );
    });
  });
}
