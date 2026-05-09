// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/dev_tunnel_socket_connector.dart';

void main() {
  group('normalizeDevTunnelWebSocketUri', () {
    test('converts web forwarding URLs to websocket URLs', () {
      expect(
        normalizeDevTunnelWebSocketUri(
          'https://abc-22.usw2.devtunnels.ms/path?x=1',
        ).toString(),
        'wss://abc-22.usw2.devtunnels.ms/path?x=1',
      );
      expect(
        normalizeDevTunnelWebSocketUri(
          'http://abc-22.usw2.devtunnels.ms',
        ).toString(),
        'ws://abc-22.usw2.devtunnels.ms',
      );
      expect(
        normalizeDevTunnelWebSocketUri('abc-22.usw2.devtunnels.ms').toString(),
        'wss://abc-22.usw2.devtunnels.ms',
      );
    });

    test('rejects missing and unsupported URLs', () {
      expect(
        () => normalizeDevTunnelWebSocketUri(''),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => normalizeDevTunnelWebSocketUri('ftp://abc-22.usw2.devtunnels.ms'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parseDevTunnelForwardingUrl', () {
    test('parses subdomain port forwarding URLs', () {
      final parsed = parseDevTunnelForwardingUrl(
        'https://abc-22.usw2.devtunnels.ms',
        fallbackPort: 22,
      );

      expect(parsed.uri.toString(), 'wss://abc-22.usw2.devtunnels.ms');
      expect(parsed.tunnelId, 'abc');
      expect(parsed.clusterId, 'usw2');
      expect(parsed.port, 22);
    });

    test(
      'keeps numeric tunnel suffixes when they do not match the SSH port',
      () {
        final parsed = parseDevTunnelForwardingUrl(
          'https://custom-1234.usw2.devtunnels.ms',
          fallbackPort: 22,
        );

        expect(parsed.tunnelId, 'custom-1234');
        expect(parsed.clusterId, 'usw2');
        expect(parsed.port, 22);
      },
    );

    test('parses explicit port forwarding URLs', () {
      final parsed = parseDevTunnelForwardingUrl(
        'https://fun-lake-1234567.usw2.devtunnels.ms:2222',
      );

      expect(parsed.tunnelId, 'fun-lake-1234567');
      expect(parsed.clusterId, 'usw2');
      expect(parsed.port, 2222);
    });

    test('rejects non-devtunnels URLs', () {
      expect(
        () => parseDevTunnelForwardingUrl('https://example.com'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DevTunnelSocketConnector', () {
    test('wraps invalid forwarding URLs in connection exception', () {
      expect(
        () =>
            DevTunnelSocketConnector.connect('ftp://abc-22.usw2.devtunnels.ms'),
        throwsA(isA<DevTunnelConnectionException>()),
      );
    });
  });
}
