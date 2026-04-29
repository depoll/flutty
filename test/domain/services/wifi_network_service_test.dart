// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/wifi_network_service.dart';

void main() {
  group('encodeSkipJumpHostSsids', () {
    test('returns null for empty input', () {
      expect(encodeSkipJumpHostSsids(const []), isNull);
      expect(encodeSkipJumpHostSsids(const ['', '   ']), isNull);
    });

    test('joins entries with newline and trims', () {
      expect(
        encodeSkipJumpHostSsids(const ['home', '  office  ']),
        'home\noffice',
      );
    });

    test('deduplicates entries while preserving order', () {
      expect(encodeSkipJumpHostSsids(const ['a', 'b', 'a', 'c']), 'a\nb\nc');
    });
  });

  group('decodeSkipJumpHostSsids', () {
    test('returns empty for null/empty', () {
      expect(decodeSkipJumpHostSsids(null), isEmpty);
      expect(decodeSkipJumpHostSsids(''), isEmpty);
    });

    test('splits and trims', () {
      expect(decodeSkipJumpHostSsids('home\n office \n\nshop'), const [
        'home',
        'office',
        'shop',
      ]);
    });

    test('round-trips with encode', () {
      const input = ['network one', 'two', 'café'];
      final encoded = encodeSkipJumpHostSsids(input);
      expect(decodeSkipJumpHostSsids(encoded), input);
    });
  });

  group('shouldSkipJumpHostForSsid', () {
    test('returns false when current SSID is null', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: null,
          skipJumpHostOnSsids: 'home',
        ),
        isFalse,
      );
    });

    test('returns false when stored list is empty', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'home',
          skipJumpHostOnSsids: null,
        ),
        isFalse,
      );
    });

    test('returns true on exact match', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'office',
          skipJumpHostOnSsids: 'home\noffice',
        ),
        isTrue,
      );
    });

    test('match is case-sensitive', () {
      expect(
        shouldSkipJumpHostForSsid(
          currentSsid: 'Home',
          skipJumpHostOnSsids: 'home',
        ),
        isFalse,
      );
    });
  });
}
