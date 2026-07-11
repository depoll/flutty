import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';

/// Returns whether the embedded WebView browser is available on [platform].
bool isPortForwardBrowserSupported({TargetPlatform? platform}) {
  final targetPlatform = platform ?? defaultTargetPlatform;
  return targetPlatform == TargetPlatform.android ||
      targetPlatform == TargetPlatform.iOS ||
      targetPlatform == TargetPlatform.macOS;
}

/// Returns whether [portForward] can be opened in the embedded browser.
bool canOpenPortForwardInBrowser(PortForward portForward) =>
    portForward.forwardType == 'local' &&
    isPortForwardBrowserHost(portForward.localHost) &&
    _isValidPort(portForward.localPort);

/// Returns whether [uri] is a valid initial embedded-browser URL.
bool isPortForwardBrowserEntryUri(Uri uri) {
  final port = portForwardBrowserUriPort(uri);
  return _isValidPort(port) &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      isPortForwardBrowserHost(uri.host);
}

/// Returns the effective network port for [uri], including scheme defaults.
int portForwardBrowserUriPort(Uri uri) {
  if (uri.hasPort) {
    return uri.port;
  }
  return switch (uri.scheme) {
    'http' => 80,
    'https' => 443,
    _ => 0,
  };
}

/// Builds the local URL used to browse a local port forward.
Uri buildPortForwardBrowserUri(PortForward portForward) =>
    buildPortForwardBrowserUriForBind(
      localHost: portForward.localHost,
      localPort: portForward.localPort,
    );

/// Builds the local URL used to browse a local bind address and port.
Uri buildPortForwardBrowserUriForBind({
  required String localHost,
  required int localPort,
}) => Uri(
  scheme: 'http',
  host: _browserHostForBindAddress(localHost),
  port: localPort,
);

/// Returns a stable localhost origin dedicated to [portForwardId].
///
/// Distinct hosts keep WebView cookies scoped to one forwarded service.
String portForwardBrowserHostForPortForwardId(int portForwardId) =>
    'monkeyssh-${portForwardId.abs().toRadixString(36)}.localhost';

/// Rewrites a loopback [uri] for one forwarded service's browser-only relay.
///
/// Returns null when [uri] does not target [sourceUri].
Uri? rewriteUriForPortForwardBrowser(
  Uri uri, {
  required Uri sourceUri,
  required Uri browserUri,
}) {
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !isPortForwardBrowserHost(uri.host) ||
      !_samePortForwardBrowserSourceHost(uri.host, sourceUri.host) ||
      portForwardBrowserUriPort(uri) != portForwardBrowserUriPort(sourceUri)) {
    return null;
  }
  return uri.replace(
    host: browserUri.host,
    port: portForwardBrowserUriPort(browserUri),
  );
}

/// Returns whether [uri] should stay inside the embedded browser.
///
/// Only loopback web links whose port is owned by an active local forward are
/// treated as forwarded pages; other localhost links keep the normal launcher.
bool shouldOpenUriInPortForwardBrowser(
  Uri uri, {
  required Iterable<int> activeLocalPorts,
}) =>
    isPortForwardBrowserHost(uri.host) &&
    activeLocalPorts.any((port) => isPortForwardBrowserUri(uri, port: port));

/// Returns whether [uri] is allowed for the forwarded local [port].
bool isPortForwardBrowserUri(Uri uri, {required int port}) =>
    _isValidPort(port) &&
    (uri.scheme == 'http' || uri.scheme == 'https') &&
    isPortForwardBrowserHost(uri.host) &&
    portForwardBrowserUriPort(uri) == port;

/// Normalizes wildcard and IPv6 loopback hosts for embedded browser loading.
Uri normalizePortForwardBrowserUri(Uri uri) =>
    uri.replace(host: _browserHostForBindAddress(uri.host));

/// Returns whether [host] is a browser-safe local bind address.
bool isPortForwardBrowserHost(String host) {
  final normalized = host.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'localhost' ||
      normalized == '0.0.0.0' ||
      normalized == '::' ||
      normalized == '::1' ||
      normalized == '[::]' ||
      normalized == '[::1]' ||
      normalized.endsWith('.localhost') ||
      _isLoopbackIpv4Address(normalized);
}

String _browserHostForBindAddress(String localHost) {
  final host = localHost.trim().toLowerCase();
  if (host.isEmpty || host == '0.0.0.0') {
    return '127.0.0.1';
  }
  if (_isLoopbackIpv4Address(host)) {
    return host;
  }
  if (host == '::' || host == '[::]' || host == '::1' || host == '[::1]') {
    return 'localhost';
  }
  return localHost.trim();
}

bool _samePortForwardBrowserSourceHost(String left, String right) {
  final normalizedLeft = _browserHostForBindAddress(left);
  final normalizedRight = _browserHostForBindAddress(right);
  if (normalizedLeft == normalizedRight) {
    return true;
  }
  return _isDefaultLoopbackBrowserHost(normalizedLeft) &&
      _isDefaultLoopbackBrowserHost(normalizedRight);
}

bool _isDefaultLoopbackBrowserHost(String host) =>
    host == '127.0.0.1' || host == 'localhost';

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

bool _isValidPort(int port) => port >= 1 && port <= 65535;
