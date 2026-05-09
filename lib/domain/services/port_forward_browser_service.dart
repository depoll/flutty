import '../../data/database/database.dart';

/// Returns whether [portForward] can be opened in the embedded browser.
bool canOpenPortForwardInBrowser(PortForward portForward) =>
    portForward.forwardType == 'local';

/// Builds the local URL used to browse a local port forward.
Uri buildPortForwardBrowserUri(PortForward portForward) => Uri(
  scheme: 'http',
  host: _browserHostForBindAddress(portForward.localHost),
  port: portForward.localPort,
);

/// Returns whether [uri] should stay inside the embedded browser.
///
/// Only loopback web links whose port is owned by an active local forward are
/// treated as forwarded pages; other localhost links keep the normal launcher.
bool shouldOpenUriInPortForwardBrowser(
  Uri uri, {
  required Iterable<int> activeLocalPorts,
}) =>
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    _isLoopbackOrWildcardHost(uri.host) &&
    activeLocalPorts.contains(uri.port);

/// Normalizes wildcard and IPv6 loopback hosts for embedded browser loading.
Uri normalizePortForwardBrowserUri(Uri uri) =>
    uri.replace(host: _browserHostForBindAddress(uri.host));

String _browserHostForBindAddress(String localHost) {
  final host = localHost.trim().toLowerCase();
  return switch (host) {
    '' || '0.0.0.0' || '::' || '[::]' => '127.0.0.1',
    '::1' || '[::1]' => 'localhost',
    _ => localHost.trim(),
  };
}

bool _isLoopbackOrWildcardHost(String host) {
  final normalized = host.trim().toLowerCase();
  return normalized == 'localhost' ||
      normalized == '0.0.0.0' ||
      normalized == '::' ||
      normalized == '::1' ||
      normalized == '[::]' ||
      normalized == '[::1]' ||
      _isLoopbackIpv4Address(normalized);
}

bool _isLoopbackIpv4Address(String host) {
  final parts = host.split('.');
  if (parts.length != 4 || parts.first != '127') {
    return false;
  }

  return parts.skip(1).every((part) {
    final value = int.tryParse(part);
    return value != null && value >= 0 && value <= 255;
  });
}
