// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/dev_tunnel_auth_service.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  setUpAll(() {
    registerFallbackValue(IOSOptions.defaultOptions);
  });

  group('DevTunnelAuthService', () {
    late _MockFlutterSecureStorage storage;

    setUp(() {
      storage = _MockFlutterSecureStorage();
      when(
        () => storage.read(
          key: any(named: 'key'),
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => storage.delete(
          key: any(named: 'key'),
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async {});
    });

    test('starts GitHub device login', () async {
      final requests = <http.Request>[];
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'device_code': 'device-code',
              'user_code': 'ABCD-1234',
              'verification_uri': 'https://github.com/login/device',
              'expires_in': 900,
              'interval': 5,
            }),
            200,
          );
        }),
      );

      final login = await service.startGitHubDeviceLogin();

      expect(login.deviceCode, 'device-code');
      expect(login.userCode, 'ABCD-1234');
      expect(
        login.verificationUri.toString(),
        'https://github.com/login/device',
      );
      expect(login.expiresIn, const Duration(seconds: 900));
      expect(login.interval, const Duration(seconds: 5));
      expect(
        requests.single.url.toString(),
        'https://github.com/login/device/code',
      );
      expect(requests.single.body, contains('client_id=Iv1.e7b89e013f801f03'));
      expect(requests.single.body, isNot(contains('scope=')));
    });

    test('stores GitHub token when device login is approved', () async {
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'access_token': 'gh-token',
              'expires_in': 3600,
              'refresh_token': 'refresh-token',
              'refresh_token_expires_in': 7200,
            }),
            200,
          ),
        ),
      );

      final result = await service.pollGitHubDeviceLogin('device-code');

      expect(result.status, DevTunnelDeviceLoginPollStatus.authorized);
      verify(
        () => storage.write(
          key: 'monkeyssh_dev_tunnels_github_token',
          value: 'gh-token',
          iOptions: any(named: 'iOptions'),
        ),
      ).called(1);
      verify(
        () => storage.write(
          key: 'monkeyssh_dev_tunnels_github_refresh_token',
          value: 'refresh-token',
          iOptions: any(named: 'iOptions'),
        ),
      ).called(1);
    });

    test(
      'returns pending while GitHub login is waiting for approval',
      () async {
        final service = DevTunnelAuthService(
          storage: storage,
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'authorization_pending'}),
              200,
            ),
          ),
        );

        final result = await service.pollGitHubDeviceLogin('device-code');

        expect(result.status, DevTunnelDeviceLoginPollStatus.pending);
      },
    );

    test('returns slowDown when GitHub asks polling to slow down', () async {
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode({'error': 'slow_down'}), 200),
        ),
      );

      final result = await service.pollGitHubDeviceLogin('device-code');

      expect(result.status, DevTunnelDeviceLoginPollStatus.slowDown);
    });

    test('resolves a Dev Tunnel connect authorization header', () async {
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'gh-token');
      final requests = <http.Request>[];
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'accessTokens': {'connect': 'tunnel-connect-token'},
              'ports': [
                {
                  'portNumber': 22,
                  'accessTokens': {'connect': 'port-connect-token'},
                },
              ],
            }),
            200,
          );
        }),
      );

      final header = await service.resolveAuthorizationHeader(
        'https://abc-22.usw2.devtunnels.ms',
        port: 22,
      );

      expect(header, 'tunnel port-connect-token');
      expect(
        requests.single.url.toString(),
        'https://usw2.rel.tunnels.api.visualstudio.com/tunnels/abc'
        '?includePorts=true&tokenScopes=connect'
        '&api-version=2023-09-27-preview',
      );
      expect(requests.single.headers['authorization'], 'github gh-token');
    });

    test('returns null authorization when not signed in', () async {
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((_) async => http.Response('', 500)),
      );

      final header = await service.resolveAuthorizationHeader(
        'https://abc-22.usw2.devtunnels.ms',
        port: 22,
      );

      expect(header, isNull);
    });

    test('lists Dev Tunnels visible to signed-in account', () async {
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'gh-token');
      final requests = <http.Request>[];
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'value': [
                {
                  'tunnelId': 'abc',
                  'clusterId': 'usw2',
                  'name': 'Mac mini',
                  'ports': [
                    {
                      'portNumber': 22,
                      'protocol': 'ssh',
                      'webForwardingUris': [
                        'https://abc-22.usw2.devtunnels.ms',
                      ],
                    },
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );

      final tunnels = await service.listTunnels();

      expect(tunnels, hasLength(1));
      expect(tunnels.single.displayName, 'Mac mini');
      expect(tunnels.single.ports.single.portNumber, 22);
      expect(
        tunnels.single.ports.single.forwardingUrl,
        'https://abc-22.usw2.devtunnels.ms',
      );
      expect(
        requests.single.url.toString(),
        'https://global.rel.tunnels.api.visualstudio.com/api/v1/tunnels'
        '?includePorts=true&api-version=2023-09-27-preview',
      );
      expect(requests.single.headers['authorization'], 'github gh-token');
    });

    test(
      'rejects non-Dev-Tunnel forwarding URLs before checking login',
      () async {
        final service = DevTunnelAuthService(
          storage: storage,
          httpClient: MockClient((_) async => http.Response('', 500)),
        );

        await expectLater(
          service.resolveAuthorizationHeader('https://example.com'),
          throwsA(isA<DevTunnelAuthException>()),
        );
      },
    );

    test('refreshes expired GitHub tokens before resolving access', () async {
      final expiresAt = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 1))
          .toIso8601String();
      final refreshExpiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String();
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'expired-gh-token');
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_token_expires_at',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => expiresAt);
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_refresh_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'refresh-token');
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_refresh_token_expires_at',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => refreshExpiresAt);
      final requests = <http.Request>[];
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'github.com') {
            return http.Response(
              jsonEncode({
                'access_token': 'fresh-gh-token',
                'expires_in': 3600,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'accessTokens': {'connect': 'tunnel-connect-token'},
            }),
            200,
          );
        }),
      );

      final header = await service.resolveAuthorizationHeader(
        'https://abc-22.usw2.devtunnels.ms',
        port: 22,
      );

      expect(header, 'tunnel tunnel-connect-token');
      expect(requests, hasLength(2));
      expect(
        requests.first.url.toString(),
        contains('/login/oauth/access_token'),
      );
      expect(requests.last.headers['authorization'], 'github fresh-gh-token');
    });

    test('clears expired sign-in when Dev Tunnels rejects the token', () async {
      when(
        () => storage.read(
          key: 'monkeyssh_dev_tunnels_github_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'expired-gh-token');
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient((_) async => http.Response('', 401)),
      );

      await expectLater(
        service.resolveAuthorizationHeader(
          'https://abc-22.usw2.devtunnels.ms',
          port: 22,
        ),
        throwsA(isA<DevTunnelAuthException>()),
      );

      verify(
        () => storage.delete(
          key: 'monkeyssh_dev_tunnels_github_token',
          iOptions: any(named: 'iOptions'),
        ),
      ).called(1);
    });
  });
}
