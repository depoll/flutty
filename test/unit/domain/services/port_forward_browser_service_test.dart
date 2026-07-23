// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
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
      expect(
        canOpenPortForwardInBrowser(_buildPortForward(localPort: 0)),
        isFalse,
      );
    });
  });

  group('isPortForwardBrowserSupported', () {
    test('allows mobile and macOS WebView platforms only', () {
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.android),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.macOS),
        isTrue,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.linux),
        isFalse,
      );
      expect(
        isPortForwardBrowserSupported(platform: TargetPlatform.windows),
        isFalse,
      );
    });
  });

  group('isPortForwardLoopbackHost', () {
    test('accepts explicit loopback addresses only', () {
      expect(isPortForwardLoopbackHost('localhost'), isTrue);
      expect(isPortForwardLoopbackHost('127.0.0.5'), isTrue);
      expect(isPortForwardLoopbackHost('127.0.0.53%lo'), isTrue);
      expect(isPortForwardLoopbackHost('::1'), isTrue);
      expect(isPortForwardLoopbackHost('::1%lo0'), isTrue);
      expect(isPortForwardLoopbackHost('monkeyssh.localhost'), isTrue);
      expect(isPortForwardLoopbackHost('127.example.com'), isFalse);
      expect(isPortForwardLoopbackHost('0.0.0.0'), isFalse);
    });
  });

  group('isPortForwardBrowserEntryUri', () {
    test('allows only loopback web URLs on valid ports', () {
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.1:8080')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('https://localhost')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.53%25lo:53')),
        isTrue,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://example.com:8080')),
        isFalse,
      );
      expect(
        isPortForwardBrowserEntryUri(Uri.parse('http://127.0.0.1:0')),
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

    test('preserves distinct IPv4 loopback bind addresses', () {
      expect(
        buildPortForwardBrowserUri(
          _buildPortForward(localHost: '127.0.0.5'),
        ).toString(),
        'http://127.0.0.5:8080',
      );
      expect(
        buildPortForwardBrowserUri(
          _buildPortForward(localHost: '127.0.0.53%lo'),
        ).toString(),
        'http://127.0.0.53:8080',
      );
    });
  });

  group('portForwardBrowserHostForPortForwardId', () {
    test('assigns stable distinct localhost hosts', () {
      expect(
        portForwardBrowserHostForPortForwardId(1),
        'monkeyssh-1.localhost',
      );
      expect(
        portForwardBrowserHostForPortForwardId(2),
        'monkeyssh-2.localhost',
      );
      expect(
        portForwardBrowserHostForPortForwardId(42),
        portForwardBrowserHostForPortForwardId(42),
      );
    });

    group('hostPortProxyDomain', () {
      test('generates a stable DNS-safe host-scoped name', () {
        expect(
          hostPortProxyDomain(hostLabel: 'Dev Box!', hostId: 42),
          'dev-box.localhost',
        );
        expect(
          hostPortProxyDomain(hostLabel: 'Dev Box!', hostId: 42),
          hostPortProxyDomain(hostLabel: 'Dev Box!', hostId: 42),
        );
        expect(
          hostPortProxyDomain(
            hostLabel: 'OVH davidpollforlasd com production workspace',
            hostId: 57,
          ),
          'ovh-davidpol.localhost',
        );
      });

      test('adds the saved host ID only for duplicate generated labels', () {
        expect(
          hostPortProxyDomain(
            hostLabel: 'Dev Box',
            hostId: 42,
            disambiguateGeneratedName: true,
          ),
          'dev-box-42.localhost',
        );
      });

      test('uses and normalizes a custom localhost prefix', () {
        expect(
          hostPortProxyDomain(
            hostLabel: 'Ignored',
            hostId: 1,
            customName: 'API.Dev.LocalHost',
          ),
          'api.dev.localhost',
        );
      });

      test('isolates automatic services by host and remote port', () {
        expect(
          automaticPortForwardBrowserHost(
            hostDomain: 'api.dev.localhost',
            hostId: 1,
            remoteHost: '127.0.0.1',
            remotePort: 3000,
          ),
          'api.dev.localhost',
        );
        expect(
          automaticPortForwardBrowserHost(
            hostDomain: 'other.localhost',
            hostId: 2,
            remoteHost: '127.0.0.1',
            remotePort: 3000,
          ),
          'other.localhost',
        );
        expect(
          automaticPortForwardBrowserHost(
            hostDomain: 'api.dev.localhost',
            hostId: 1,
            remoteHost: '::1',
            remotePort: 8080,
          ),
          'api.dev.localhost',
        );
      });

      test('validates DNS labels and allows an empty generated-name field', () {
        final sixtyCharacterLabel = List.filled(60, 'a').join();
        final maximumLengthPrefix = [
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          List.filled(38, 'a').join(),
        ].join('.');
        final overlongPrefix = [
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          sixtyCharacterLabel,
          List.filled(39, 'a').join(),
        ].join('.');

        expect(validatePortProxyName(''), isNull);
        expect(validatePortProxyName('api.dev'), isNull);
        expect(validatePortProxyName('api.dev.localhost'), isNull);
        expect(validatePortProxyName('-api'), isNotNull);
        expect(validatePortProxyName('api_1'), isNotNull);
        expect(validatePortProxyName(maximumLengthPrefix), isNull);
        expect(validatePortProxyName(overlongPrefix), isNotNull);
      });
    });
  });

  group('rewriteUriForPortForwardBrowser', () {
    test('preserves the request while replacing the forwarded endpoint', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('https://localhost:8080/login?next=%2F'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-42.localhost:8080'),
        ),
        Uri.parse('https://monkeyssh-42.localhost:8080/login?next=%2F'),
      );
    });

    group('shouldUsePortForwardBrowserFallback', () {
      final browserUri = Uri.parse('http://dev-box.localhost:49152');

      test('retries a failed friendly main-frame endpoint once', () {
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: null,
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isTrue,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isTrue,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: true,
            alreadyTried: true,
          ),
          isFalse,
        );
      });

      test('ignores subresources and unrelated endpoints', () {
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: browserUri,
            isForMainFrame: false,
            alreadyTried: false,
          ),
          isFalse,
        );
        expect(
          shouldUsePortForwardBrowserFallback(
            browserUri: browserUri,
            failedUri: Uri.parse('http://example.com:49152'),
            isForMainFrame: true,
            alreadyTried: false,
          ),
          isFalse,
        );
      });
    });

    test('rewrites a detected remote port to its ephemeral proxy port', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:3000/dashboard'),
          sourceUri: Uri.parse('http://localhost:3000'),
          browserUri: Uri.parse('http://dev-box.localhost:49152'),
        ),
        Uri.parse('http://dev-box.localhost:49152/dashboard'),
      );
    });

    test('does not rewrite a different local port', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:3000'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-42.localhost:8080'),
        ),
        isNull,
      );
    });

    test('does not rewrite the same port on a different loopback host', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://127.0.0.2:8080'),
          sourceUri: Uri.parse('http://127.0.0.1:8080'),
          browserUri: Uri.parse('http://monkeyssh-1.localhost:8080'),
        ),
        isNull,
      );
    });

    test('treats default loopback host spellings as equivalent', () {
      expect(
        rewriteUriForPortForwardBrowser(
          Uri.parse('http://localhost:8080'),
          sourceUri: Uri.parse('http://0.0.0.0:8080'),
          browserUri: Uri.parse('http://monkeyssh-1.localhost:8080'),
        ),
        Uri.parse('http://monkeyssh-1.localhost:8080'),
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
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('http://localhost/'),
          activeLocalPorts: const [80],
        ),
        isTrue,
      );
      expect(
        shouldOpenUriInPortForwardBrowser(
          Uri.parse('https://localhost/'),
          activeLocalPorts: const [443],
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

    test('preserves IPv4 loopback URL hosts', () {
      expect(
        normalizePortForwardBrowserUri(
          Uri.parse('http://127.0.0.5:3000/path'),
        ).toString(),
        'http://127.0.0.5:3000/path',
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
