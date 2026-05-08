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
    });

    test('stores GitHub token when device login is approved', () async {
      final service = DevTunnelAuthService(
        storage: storage,
        httpClient: MockClient(
          (_) async =>
              http.Response(jsonEncode({'access_token': 'gh-token'}), 200),
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
      );

      expect(header, isNull);
    });
  });
}
