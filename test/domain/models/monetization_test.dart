import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/monetization.dart';

void main() {
  group('concurrent ACP session monetization', () {
    test('describes only the concurrent-session upgrade boundary', () {
      const feature = MonetizationFeature.concurrentAcpSessions;

      expect(feature.label, 'Concurrent agent sessions');
      expect(feature.description, contains('multiple coding-agent sessions'));
      expect(feature.blockedAction, contains('another coding-agent session'));
      expect(
        feature.blockedOutcome,
        contains('multiple coding-agent sessions'),
      );
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
