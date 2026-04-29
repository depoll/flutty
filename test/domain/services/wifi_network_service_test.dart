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

    test('strips embedded line breaks so storage stays single-line', () {
      expect(
        encodeSkipJumpHostSsids(const ['ho\nme', 'shop\rfloor']),
        'home\nshopfloor',
      );
    });

    test('drops entries that become empty after stripping line breaks', () {
      expect(encodeSkipJumpHostSsids(const ['\n\r\n', 'home']), 'home');
    });

    test('strips zero-width and bidi format characters from SSIDs', () {
      // U+200B zero-width space, U+200E left-to-right mark, U+FEFF BOM.
      expect(encodeSkipJumpHostSsids(const ['​ho‎me﻿']), 'home');
    });

    test('drops entries that contain only invisible characters', () {
      expect(encodeSkipJumpHostSsids(const ['​‎﻿', 'home']), 'home');
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

    test('cleans invisible characters from previously-stored values', () {
      // Simulates a row written before encoder hardening that still has a
      // BOM/ZWSP/LRM lurking in it.
      expect(decodeSkipJumpHostSsids('﻿ho​m‎e\nshop'), const ['home', 'shop']);
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
