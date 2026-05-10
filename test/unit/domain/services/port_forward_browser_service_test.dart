// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/port_forward_browser_service.dart';

PortForward _buildPortForward({
  String forwardType = 'local',
  String localHost = '127.0.0.1',
  int localPort = 8080,
}) => PortForward(
  id: 1,
  name: 'Web',
  hostId: 1,
  forwardType: forwardType,
  localHost: localHost,
  localPort: localPort,
  remoteHost: 'localhost',
  remotePort: 80,
  autoStart: false,
  createdAt: DateTime(2026),
);

void main() {
  group('canOpenPortForwardInBrowser', () {
    test('allows only local loopback forwards', () {
      expect(canOpenPortForwardInBrowser(_buildPortForward()), isTrue);
      expect(
        canOpenPortForwardInBrowser(_buildPortForward(forwardType: 'remote')),
        isFalse,
      );
      expect(
        canOpenPortForwardInBrowser(
          _buildPortForward(localHost: '192.168.1.20'),
        ),
        isFalse,
      );
    });
  });

  group('buildPortForwardBrowserUri', () {
    test('builds an http URL for loopback forwards', () {
      expect(
        buildPortForwardBrowserUri(_buildPortForward()).toString(),
        'http://127.0.0.1:8080',
      );
    });

    test('maps wildcard bind addresses to loopback', () {
      expect(
        buildPortForwardBrowserUri(
          _buildPortForward(localHost: '0.0.0.0'),
        ).toString(),
        'http://127.0.0.1:8080',
      );
    });

    test('maps IPv6 loopback bind addresses to localhost', () {
      expect(
        buildPortForwardBrowserUri(
          _buildPortForward(localHost: '::1'),
        ).toString(),
        'http://localhost:8080',
      );
    });

    test('maps all IPv4 loopback bind addresses to 127.0.0.1', () {
      expect(
        buildPortForwardBrowserUri(
          _buildPortForward(localHost: '127.0.0.5'),
        ).toString(),
        'http://127.0.0.1:8080',
      );
    });
  });

  group('shouldOpenUriInPortForwardBrowser', () {
    test('matches http and https loopback URLs', () {
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('http://127.0.0.1:8080'),
          activeLocalPorts: const [8080],
        ),
        isTrue,
      );
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('https://localhost:8443'),
          activeLocalPorts: const [8443],
        ),
        isTrue,
      );
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('http://127.0.0.5:8080'),
          activeLocalPorts: const [8080],
        ),
        isTrue,
      );
    });

    test('does not match inactive loopback ports', () {
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('http://127.0.0.1:8080'),
          activeLocalPorts: const [3000],
        ),
        isFalse,
      );
    });

    test('does not match non-web or non-loopback URLs', () {
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('ssh://localhost:22'),
          activeLocalPorts: const [22],
        ),
        isFalse,
      );
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('https://example.com'),
          activeLocalPorts: const [443],
        ),
        isFalse,
      );
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('https://127.example.com'),
          activeLocalPorts: const [443],
        ),
        isFalse,
      );
    });
  });

  group('normalizePortForwardBrowserUri', () {
    test('maps wildcard URL hosts to loopback', () {
      expect(
        normalizePortForwardBrowserUri(
          Uri.parse('http://0.0.0.0:3000/path'),
        ).toString(),
        'http://127.0.0.1:3000/path',
      );
    });

    test('maps IPv4 loopback URL hosts to 127.0.0.1', () {
      expect(
        normalizePortForwardBrowserUri(
          Uri.parse('http://127.0.0.5:3000/path'),
        ).toString(),
        'http://127.0.0.1:3000/path',
      );
    });
  });

  group('isPortForwardBrowserUri', () {
    test('allows only loopback web URLs on the forwarded port', () {
      expect(
        isPortForwardBrowserUri(
          Uri.parse('http://127.0.0.5:3000/path'),
          port: 3000,
        ),
        isTrue,
      );
      expect(
        isPortForwardBrowserUri(
          Uri.parse('http://127.0.0.1:4000/path'),
          port: 3000,
        ),
        isFalse,
      );
      expect(
        isPortForwardBrowserUri(
          Uri.parse('https://example.com:3000/path'),
          port: 3000,
        ),
        isFalse,
      );
      expect(
        isPortForwardBrowserUri(Uri.parse('http://127.0.0.1:0/path'), port: 0),
        isFalse,
      );
    });
  });
}
