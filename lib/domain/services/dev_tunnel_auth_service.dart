import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'dev_tunnel_socket_connector.dart';

/// Error raised when Dev Tunnels login or token exchange fails.
class DevTunnelAuthException implements Exception {
  /// Creates a [DevTunnelAuthException].
  const DevTunnelAuthException(this.message);

  /// User-facing error message.
  final String message;

  @override
  String toString() => message;
}

/// GitHub device-code login challenge for Dev Tunnels.
class DevTunnelDeviceLogin {
  /// Creates a [DevTunnelDeviceLogin].
  const DevTunnelDeviceLogin({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  /// Opaque device code used when polling GitHub.
  final String deviceCode;

  /// Short code the user enters on GitHub.
  final String userCode;

  /// GitHub verification URL the user opens to finish sign-in.
  final Uri verificationUri;

  /// Time until the device code expires.
  final Duration expiresIn;

  /// Minimum interval between polling attempts.
  final Duration interval;
}

/// Status returned by a GitHub device-code poll.
enum DevTunnelDeviceLoginPollStatus {
  /// The user approved the login and the token was stored.
  authorized,

  /// The user has not completed login yet.
  pending,

  /// GitHub asked the app to slow down polling.
  slowDown,

  /// The device code expired before approval.
  expired,

  /// The user denied login.
  denied,

  /// GitHub returned a non-recoverable error.
  error,
}

/// Result returned by a GitHub device-code poll.
class DevTunnelDeviceLoginPollResult {
  /// Creates a [DevTunnelDeviceLoginPollResult].
  const DevTunnelDeviceLoginPollResult({required this.status, this.message});

  /// Current poll status.
  final DevTunnelDeviceLoginPollStatus status;

  /// Optional user-facing error detail.
  final String? message;
}

/// A Dev Tunnel visible to the signed-in account.
class DevTunnel {
  /// Creates a [DevTunnel].
  const DevTunnel({
    required this.tunnelId,
    required this.clusterId,
    required this.name,
    required this.description,
    required this.labels,
    required this.ports,
  });

  /// Stable tunnel ID used by the Dev Tunnels service.
  final String tunnelId;

  /// Relay cluster ID used in standard forwarding URLs.
  final String clusterId;

  /// Optional user-facing tunnel name.
  final String? name;

  /// Optional tunnel description.
  final String? description;

  /// Optional tunnel labels.
  final List<String> labels;

  /// Exposed ports for this tunnel.
  final List<DevTunnelPort> ports;

  /// Label for picker UI.
  String get displayName {
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) {
      return trimmedName;
    }
    return tunnelId;
  }
}

/// A connectable port on a Dev Tunnel.
class DevTunnelPort {
  /// Creates a [DevTunnelPort].
  const DevTunnelPort({
    required this.tunnelId,
    required this.clusterId,
    required this.portNumber,
    required this.forwardingUrl,
    required this.protocol,
    required this.name,
    required this.description,
  });

  /// Stable tunnel ID that owns this port.
  final String tunnelId;

  /// Relay cluster ID that owns this port.
  final String clusterId;

  /// Port number exposed by the tunnel.
  final int portNumber;

  /// Standard `devtunnels.ms` forwarding URL, when available.
  final String? forwardingUrl;

  /// Optional protocol metadata from the Dev Tunnels service.
  final String? protocol;

  /// Optional user-facing port name.
  final String? name;

  /// Optional port description.
  final String? description;

  /// Label for picker UI.
  String get displayName {
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) {
      return trimmedName;
    }
    final trimmedProtocol = protocol?.trim();
    if (trimmedProtocol != null && trimmedProtocol.isNotEmpty) {
      return '${trimmedProtocol.toUpperCase()} :$portNumber';
    }
    return ':$portNumber';
  }
}

class _DevTunnelNotFoundException implements Exception {
  const _DevTunnelNotFoundException();
}

/// Handles Dev Tunnels account login and connect-token exchange.
class DevTunnelAuthService {
  /// Creates a [DevTunnelAuthService].
  DevTunnelAuthService({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _storage = storage ?? _secureStorage,
       _httpClient = httpClient ?? http.Client(),
       _requestTimeout = requestTimeout;

  static const _githubClientId = 'Iv1.e7b89e013f801f03';
  static const _githubTokenKey = 'monkeyssh_dev_tunnels_github_token';
  static const _githubRefreshTokenKey =
      'monkeyssh_dev_tunnels_github_refresh_token';
  static const _githubTokenExpiresAtKey =
      'monkeyssh_dev_tunnels_github_token_expires_at';
  static const _githubRefreshTokenExpiresAtKey =
      'monkeyssh_dev_tunnels_github_refresh_token_expires_at';
  static const _devTunnelApiVersion = '2023-09-27-preview';
  static const _tokenExpirySkew = Duration(minutes: 5);
  static const _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  final FlutterSecureStorage _storage;
  final http.Client _httpClient;
  final Duration _requestTimeout;

  /// Returns whether a GitHub login token is stored for Dev Tunnels.
  Future<bool> hasGitHubLogin() async {
    final token = await _readGitHubToken();
    if (token == null || token.isEmpty) {
      return false;
    }
    final expiresAt = await _readDateTime(_githubTokenExpiresAtKey);
    if (!_isExpired(expiresAt)) {
      return true;
    }
    final refreshToken = await _storage.read(
      key: _githubRefreshTokenKey,
      iOptions: _iosOptions,
    );
    final refreshExpiresAt = await _readDateTime(
      _githubRefreshTokenExpiresAtKey,
    );
    return refreshToken != null &&
        refreshToken.isNotEmpty &&
        !_isExpired(refreshExpiresAt);
  }

  /// Clears the stored GitHub login token.
  Future<void> signOutGitHub() async {
    await Future.wait([
      _storage.delete(key: _githubTokenKey, iOptions: _iosOptions),
      _storage.delete(key: _githubRefreshTokenKey, iOptions: _iosOptions),
      _storage.delete(key: _githubTokenExpiresAtKey, iOptions: _iosOptions),
      _storage.delete(
        key: _githubRefreshTokenExpiresAtKey,
        iOptions: _iosOptions,
      ),
    ]);
  }

  /// Starts the GitHub device-code login flow used by Dev Tunnels.
  Future<DevTunnelDeviceLogin> startGitHubDeviceLogin() async {
    final response = await _httpClient
        .post(
          Uri.parse('https://github.com/login/device/code'),
          headers: const {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
          },
          body: Uri(
            queryParameters: const {'client_id': _githubClientId},
          ).query,
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, 'starting GitHub login');

    final body = _decodeJsonObject(response.body);
    final deviceCode = _requiredString(body, 'device_code');
    final userCode = _requiredString(body, 'user_code');
    final verificationUri = Uri.tryParse(
      _requiredString(body, 'verification_uri'),
    );
    final expiresIn = _requiredPositiveInt(body, 'expires_in');
    final interval = _optionalPositiveInt(body, 'interval') ?? 5;
    if (verificationUri == null || !verificationUri.hasScheme) {
      throw const DevTunnelAuthException(
        'GitHub returned an invalid verification URL.',
      );
    }

    return DevTunnelDeviceLogin(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      expiresIn: Duration(seconds: expiresIn),
      interval: Duration(seconds: interval),
    );
  }

  /// Polls GitHub for a completed device-code login.
  Future<DevTunnelDeviceLoginPollResult> pollGitHubDeviceLogin(
    String deviceCode,
  ) async {
    final response = await _httpClient
        .post(
          Uri.parse('https://github.com/login/oauth/access_token'),
          headers: const {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
          },
          body: Uri(
            queryParameters: {
              'client_id': _githubClientId,
              'device_code': deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          ).query,
        )
        .timeout(_requestTimeout);
    _ensureSuccess(response, 'polling GitHub login');

    final body = _decodeJsonObject(response.body);
    final accessToken = _optionalString(body, 'access_token');
    if (accessToken != null && accessToken.isNotEmpty) {
      await _storeGitHubTokenResponse(body);
      return const DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.authorized,
      );
    }

    final error = _optionalString(body, 'error');
    return switch (error) {
      'authorization_pending' => const DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.pending,
      ),
      'slow_down' => const DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.slowDown,
      ),
      'expired_token' => const DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.expired,
      ),
      'access_denied' => DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.denied,
        message: _optionalString(body, 'error_description'),
      ),
      _ => DevTunnelDeviceLoginPollResult(
        status: DevTunnelDeviceLoginPollStatus.error,
        message:
            _optionalString(body, 'error_description') ??
            error ??
            'GitHub login failed.',
      ),
    };
  }

  /// Resolves the `X-Tunnel-Authorization` header for a forwarding URL.
  ///
  /// Returns null when the user is not signed in, allowing anonymous Dev
  /// Tunnels to connect without account login.
  Future<String?> resolveAuthorizationHeader(
    String forwardingUrl, {
    int? port,
  }) async {
    final DevTunnelForwardingUrl parsedUrl;
    try {
      parsedUrl = parseDevTunnelForwardingUrl(
        forwardingUrl,
        fallbackPort: port,
      );
    } on FormatException catch (error) {
      throw DevTunnelAuthException(error.message);
    }

    final githubToken = await _resolveGitHubToken();
    if (githubToken == null || githubToken.isEmpty) {
      return null;
    }

    final connectToken = await _resolveConnectToken(
      githubToken: githubToken,
      forwardingUrl: parsedUrl,
    );
    return 'tunnel $connectToken';
  }

  /// Lists tunnels visible to the signed-in GitHub account.
  Future<List<DevTunnel>> listTunnels() async {
    final githubToken = await _resolveGitHubToken();
    if (githubToken == null || githubToken.isEmpty) {
      throw const DevTunnelAuthException(
        'Sign in to Dev Tunnels to list tunnels.',
      );
    }

    return _listTunnels(githubToken);
  }

  Future<List<DevTunnel>> _listTunnels(String githubToken) async {
    final response = await _httpClient
        .get(
          Uri.https(
            'global.rel.tunnels.api.visualstudio.com',
            '/tunnels',
            const {
              'includePorts': 'true',
              'global': 'true',
              'api-version': _devTunnelApiVersion,
            },
          ),
          headers: {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.authorizationHeader: 'github $githubToken',
            HttpHeaders.userAgentHeader: 'MonkeySSH Dev Tunnels',
          },
        )
        .timeout(_requestTimeout);
    if (response.statusCode == 401) {
      await signOutGitHub();
      throw const DevTunnelAuthException(
        'Dev Tunnels sign-in expired. Sign in again.',
      );
    }
    _ensureSuccess(response, 'listing Dev Tunnels');

    final body = _decodeJson(response.body);
    final tunnels = <DevTunnel>[];
    for (final entry in _tunnelEntriesFromJson(body)) {
      final tunnel = _parseTunnel(
        entry.object,
        fallbackClusterId: entry.clusterId,
      );
      if (tunnel != null) {
        tunnels.add(tunnel);
      }
    }
    tunnels.sort((a, b) => a.displayName.compareTo(b.displayName));
    return tunnels;
  }

  Future<String> _resolveConnectToken({
    required String githubToken,
    required DevTunnelForwardingUrl forwardingUrl,
  }) async {
    try {
      return await _requestConnectToken(
        githubToken: githubToken,
        tunnelId: forwardingUrl.tunnelId,
        clusterId: forwardingUrl.clusterId,
        port: forwardingUrl.port,
      );
    } on _DevTunnelNotFoundException {
      final matchedPort = await _findListedPortForForwardingUrl(
        githubToken: githubToken,
        forwardingUrl: forwardingUrl,
      );
      if (matchedPort == null) {
        throw const DevTunnelAuthException(
          'Could not find this Dev Tunnel in the signed-in account. '
          'Refresh tunnels and select it again.',
        );
      }
      try {
        return await _requestConnectToken(
          githubToken: githubToken,
          tunnelId: matchedPort.tunnelId,
          clusterId: matchedPort.clusterId,
          port: matchedPort.portNumber,
        );
      } on _DevTunnelNotFoundException {
        throw const DevTunnelAuthException(
          'Could not find this Dev Tunnel in the signed-in account. '
          'Refresh tunnels and select it again.',
        );
      }
    }
  }

  Future<String> _requestConnectToken({
    required String githubToken,
    required String tunnelId,
    required String clusterId,
    required int? port,
  }) async {
    final queryParameters = <String, String>{
      'includePorts': 'true',
      'tokenScopes': 'connect',
      'api-version': _devTunnelApiVersion,
    };
    final uri = Uri.https(
      '$clusterId.rel.tunnels.api.visualstudio.com',
      '/tunnels/$tunnelId',
      queryParameters,
    );
    final response = await _httpClient
        .get(
          uri,
          headers: {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.authorizationHeader: 'github $githubToken',
            HttpHeaders.userAgentHeader: 'MonkeySSH Dev Tunnels',
          },
        )
        .timeout(_requestTimeout);
    if (response.statusCode == 401) {
      await signOutGitHub();
      throw const DevTunnelAuthException(
        'Dev Tunnels sign-in expired. Sign in again.',
      );
    }
    if (response.statusCode == 404) {
      throw const _DevTunnelNotFoundException();
    }
    _ensureSuccess(response, 'getting Dev Tunnel access');

    final body = _decodeJsonObject(response.body);
    final portToken = _connectTokenFromPorts(body, port);
    if (portToken != null) {
      return portToken;
    }
    final tunnelToken = _connectTokenFromObject(body);
    if (tunnelToken != null) {
      return tunnelToken;
    }

    throw const DevTunnelAuthException(
      'Signed-in account does not have access to connect to this Dev Tunnel.',
    );
  }

  Future<DevTunnelPort?> _findListedPortForForwardingUrl({
    required String githubToken,
    required DevTunnelForwardingUrl forwardingUrl,
  }) async {
    final targetHost = forwardingUrl.uri.host.toLowerCase();
    final targetPort = forwardingUrl.port;
    final tunnels = await _listTunnels(githubToken);
    for (final tunnel in tunnels) {
      for (final port in tunnel.ports) {
        final candidateUrl = port.forwardingUrl;
        if (candidateUrl == null || candidateUrl.isEmpty) {
          continue;
        }
        final DevTunnelForwardingUrl candidate;
        try {
          candidate = parseDevTunnelForwardingUrl(
            candidateUrl,
            fallbackPort: port.portNumber,
          );
        } on FormatException {
          continue;
        }
        if (candidate.uri.host.toLowerCase() != targetHost) {
          continue;
        }
        if (targetPort != null &&
            candidate.port != targetPort &&
            port.portNumber != targetPort) {
          continue;
        }
        return port;
      }
    }
    return null;
  }

  String? _connectTokenFromPorts(Map<String, Object?> body, int? port) {
    final ports = body['ports'];
    if (ports is! List<Object?>) {
      return null;
    }
    for (final portEntry in ports) {
      if (portEntry is! Map<String, Object?>) {
        continue;
      }
      if (port != null && portEntry['portNumber'] != port) {
        continue;
      }
      final token = _connectTokenFromObject(portEntry);
      if (token != null) {
        return token;
      }
    }
    return null;
  }

  String? _connectTokenFromObject(Map<String, Object?> object) {
    final accessTokens = object['accessTokens'];
    if (accessTokens is! Map<String, Object?>) {
      return null;
    }
    final token = accessTokens['connect'];
    return token is String && token.isNotEmpty ? token : null;
  }

  Future<String?> _readGitHubToken() =>
      _storage.read(key: _githubTokenKey, iOptions: _iosOptions);

  Future<String?> _resolveGitHubToken() async {
    final token = await _readGitHubToken();
    if (token == null || token.isEmpty) {
      return null;
    }

    final expiresAt = await _readDateTime(_githubTokenExpiresAtKey);
    if (!_isExpired(expiresAt)) {
      return token;
    }

    final refreshToken = await _storage.read(
      key: _githubRefreshTokenKey,
      iOptions: _iosOptions,
    );
    final refreshExpiresAt = await _readDateTime(
      _githubRefreshTokenExpiresAtKey,
    );
    if (refreshToken == null ||
        refreshToken.isEmpty ||
        _isExpired(refreshExpiresAt)) {
      await signOutGitHub();
      throw const DevTunnelAuthException(
        'Dev Tunnels sign-in expired. Sign in again.',
      );
    }

    return _refreshGitHubToken(refreshToken);
  }

  Future<String> _refreshGitHubToken(String refreshToken) async {
    final response = await _httpClient
        .post(
          Uri.parse('https://github.com/login/oauth/access_token'),
          headers: const {
            HttpHeaders.acceptHeader: 'application/json',
            HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
          },
          body: Uri(
            queryParameters: {
              'client_id': _githubClientId,
              'grant_type': 'refresh_token',
              'refresh_token': refreshToken,
            },
          ).query,
        )
        .timeout(_requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await signOutGitHub();
      throw const DevTunnelAuthException(
        'Dev Tunnels sign-in expired. Sign in again.',
      );
    }

    final body = _decodeJsonObject(response.body);
    final error = _optionalString(body, 'error');
    if (error != null && error.isNotEmpty) {
      await signOutGitHub();
      throw const DevTunnelAuthException(
        'Dev Tunnels sign-in expired. Sign in again.',
      );
    }

    await _storeGitHubTokenResponse(body);
    return _requiredString(body, 'access_token');
  }

  Future<void> _storeGitHubTokenResponse(Map<String, Object?> body) async {
    final accessToken = _requiredString(body, 'access_token');
    await _storage.write(
      key: _githubTokenKey,
      value: accessToken,
      iOptions: _iosOptions,
    );
    await _writeExpiry(
      key: _githubTokenExpiresAtKey,
      expiresIn: _optionalPositiveInt(body, 'expires_in'),
    );

    final refreshToken = _optionalString(body, 'refresh_token');
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _storage.write(
        key: _githubRefreshTokenKey,
        value: refreshToken,
        iOptions: _iosOptions,
      );
      await _writeExpiry(
        key: _githubRefreshTokenExpiresAtKey,
        expiresIn: _optionalPositiveInt(body, 'refresh_token_expires_in'),
      );
    }
  }

  Future<void> _writeExpiry({
    required String key,
    required int? expiresIn,
  }) async {
    if (expiresIn == null || expiresIn <= 0) {
      await _storage.delete(key: key, iOptions: _iosOptions);
      return;
    }

    await _storage.write(
      key: key,
      value: DateTime.now()
          .toUtc()
          .add(Duration(seconds: expiresIn))
          .toIso8601String(),
      iOptions: _iosOptions,
    );
  }

  Future<DateTime?> _readDateTime(String key) async {
    final value = await _storage.read(key: key, iOptions: _iosOptions);
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  bool _isExpired(DateTime? expiresAt) {
    if (expiresAt == null) {
      return false;
    }
    return !DateTime.now().toUtc().add(_tokenExpirySkew).isBefore(expiresAt);
  }

  List<({Object? object, String? clusterId})> _tunnelEntriesFromJson(
    Object? body,
  ) {
    final topLevelEntries = switch (body) {
      final List<Object?> list => list,
      final Map<String, Object?> object when object['value'] is List<Object?> =>
        object['value']! as List<Object?>,
      final Map<String, Object?> object when object['items'] is List<Object?> =>
        object['items']! as List<Object?>,
      _ => throw const DevTunnelAuthException(
        'Unexpected Dev Tunnels response.',
      ),
    };

    final entries = <({Object? object, String? clusterId})>[];
    for (final entry in topLevelEntries) {
      if (entry is Map<String, Object?> &&
          !_hasTunnelIdentifier(entry) &&
          entry['value'] is List<Object?>) {
        final fallbackClusterId =
            _optionalString(entry, 'clusterId') ??
            _optionalString(entry, 'cluster') ??
            _optionalString(entry, 'relayClusterId');
        for (final regionalEntry in entry['value']! as List<Object?>) {
          entries.add((object: regionalEntry, clusterId: fallbackClusterId));
        }
        continue;
      }
      entries.add((object: entry, clusterId: null));
    }
    return entries;
  }

  DevTunnel? _parseTunnel(Object? entry, {String? fallbackClusterId}) {
    if (entry is! Map<String, Object?>) {
      return null;
    }
    final tunnelId =
        _optionalString(entry, 'tunnelId') ??
        _optionalString(entry, 'id') ??
        _optionalString(entry, 'name');
    final clusterId =
        _optionalString(entry, 'clusterId') ??
        _optionalString(entry, 'cluster') ??
        _optionalString(entry, 'relayClusterId') ??
        fallbackClusterId;
    if (tunnelId == null || clusterId == null) {
      return null;
    }

    final ports = <DevTunnelPort>[];
    final portsJson = entry['ports'];
    if (portsJson is List<Object?>) {
      for (final portEntry in portsJson) {
        final port = _parseTunnelPort(
          portEntry,
          tunnelId: tunnelId,
          clusterId: clusterId,
        );
        if (port != null) {
          ports.add(port);
        }
      }
    }

    return DevTunnel(
      tunnelId: tunnelId,
      clusterId: clusterId,
      name: _optionalString(entry, 'name'),
      description: _optionalString(entry, 'description'),
      labels: List.unmodifiable(_optionalStringList(entry, 'labels')),
      ports: List.unmodifiable(ports),
    );
  }

  DevTunnelPort? _parseTunnelPort(
    Object? entry, {
    required String tunnelId,
    required String clusterId,
  }) {
    if (entry is! Map<String, Object?>) {
      return null;
    }
    final portNumber = _optionalPositiveInt(entry, 'portNumber');
    if (portNumber == null) {
      return null;
    }

    final portTunnelId = _optionalString(entry, 'tunnelId') ?? tunnelId;
    final portClusterId =
        _optionalString(entry, 'clusterId') ??
        _optionalString(entry, 'cluster') ??
        _optionalString(entry, 'relayClusterId') ??
        clusterId;

    return DevTunnelPort(
      tunnelId: portTunnelId,
      clusterId: portClusterId,
      portNumber: portNumber,
      forwardingUrl:
          _firstHttpStringFromList(entry['webForwardingUris']) ??
          _firstHttpStringFromList(entry['portForwardingUris']) ??
          'https://$portTunnelId-$portNumber.$portClusterId.devtunnels.ms',
      protocol: _optionalString(entry, 'protocol'),
      name: _optionalString(entry, 'name'),
      description: _optionalString(entry, 'description'),
    );
  }

  static bool _hasTunnelIdentifier(Map<String, Object?> object) =>
      _optionalString(object, 'tunnelId') != null ||
      _optionalString(object, 'id') != null;

  static String? _firstHttpStringFromList(Object? value) {
    if (value is! List<Object?>) {
      return null;
    }
    for (final entry in value) {
      if (entry is String &&
          (entry.startsWith('https://') || entry.startsWith('http://'))) {
        return entry;
      }
    }
    return null;
  }

  static Object? _decodeJson(String source) {
    try {
      return jsonDecode(source);
    } on FormatException {
      throw const DevTunnelAuthException('Unexpected Dev Tunnels response.');
    }
  }

  static Map<String, Object?> _decodeJsonObject(String source) {
    final decoded = _decodeJson(source);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    throw const DevTunnelAuthException('Unexpected Dev Tunnels response.');
  }

  static String _requiredString(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw DevTunnelAuthException('GitHub response is missing $key.');
  }

  static String? _optionalString(Map<String, Object?> body, String key) {
    final value = body[key];
    return value is String ? value : null;
  }

  static List<String> _optionalStringList(
    Map<String, Object?> body,
    String key,
  ) {
    final value = body[key];
    if (value is! List<Object?>) {
      return const [];
    }
    return [
      for (final entry in value)
        if (entry is String && entry.trim().isNotEmpty) entry,
    ];
  }

  static int _requiredPositiveInt(Map<String, Object?> body, String key) {
    final value = _optionalPositiveInt(body, key);
    if (value != null) {
      return value;
    }
    throw DevTunnelAuthException('GitHub response is missing $key.');
  }

  static int? _optionalPositiveInt(Map<String, Object?> body, String key) {
    final value = body[key];
    if (value is int && value > 0) {
      return value;
    }
    return null;
  }

  static void _ensureSuccess(http.Response response, String action) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw DevTunnelAuthException(
      'Dev Tunnels failed while $action (${response.statusCode}).',
    );
  }
}

/// Provider for [DevTunnelAuthService].
final devTunnelAuthServiceProvider = Provider<DevTunnelAuthService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return DevTunnelAuthService(httpClient: client);
});

/// Whether Dev Tunnels has a stored GitHub login.
final devTunnelSignedInProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(devTunnelAuthServiceProvider).hasGitHubLogin(),
);

/// Tunnels visible to the signed-in Dev Tunnels account.
final devTunnelListProvider = FutureProvider.autoDispose<List<DevTunnel>>(
  (ref) => ref.watch(devTunnelAuthServiceProvider).listTunnels(),
  retry: (_, _) => null,
);
