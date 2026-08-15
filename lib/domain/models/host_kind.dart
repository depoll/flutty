import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';

/// How a saved host opens a terminal session.
enum HostKind {
  /// Network SSH host (default).
  ssh,

  /// Local interactive shell on this device (desktop + Android sandbox).
  local,
}

/// Presentation and storage helpers for [HostKind].
extension HostKindX on HostKind {
  /// Stable database/storage value.
  String get storageValue => switch (this) {
    HostKind.ssh => 'ssh',
    HostKind.local => 'local',
  };

  /// Short diagnostics value.
  String get diagnosticsValue => storageValue;

  /// Human-readable label for UI.
  String get label => switch (this) {
    HostKind.ssh => 'SSH',
    HostKind.local => 'Local Terminal',
  };
}

/// Parses a stored host-kind value. Unknown/null values default to SSH.
HostKind hostKindFromStorage(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'local':
      return HostKind.local;
    case 'ssh':
    case null:
    case '':
      return HostKind.ssh;
    default:
      return HostKind.ssh;
  }
}

/// Returns the kind for [host].
HostKind hostKindOf(Host host) => hostKindFromStorage(host.hostKind);

/// Whether [host] opens a local device shell instead of SSH.
bool isLocalTerminalHost(Host host) => hostKindOf(host) == HostKind.local;

/// Whether this build/platform can spawn a local interactive PTY shell.
bool isLocalTerminalSupported({TargetPlatform? platform}) {
  if (kIsWeb) {
    return false;
  }
  final resolved = platform ?? defaultTargetPlatform;
  return switch (resolved) {
    TargetPlatform.android ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };
}

/// Default display label for a new local terminal host on this platform.
String defaultLocalTerminalHostLabel({TargetPlatform? platform}) {
  final resolved = platform ?? defaultTargetPlatform;
  return switch (resolved) {
    TargetPlatform.macOS => 'This Mac',
    TargetPlatform.windows => 'This PC',
    TargetPlatform.linux => 'This Linux PC',
    TargetPlatform.android => 'This Android device',
    _ => 'Local Terminal',
  };
}

/// Default username shown for a local terminal host.
String defaultLocalTerminalUsername() {
  if (kIsWeb) {
    return 'local';
  }
  final env = Platform.environment;
  final fromEnv = env['USER'] ?? env['USERNAME'] ?? env['LOGNAME'];
  final trimmed = fromEnv?.trim();
  if (trimmed != null && trimmed.isNotEmpty) {
    return trimmed;
  }
  return 'local';
}

/// Canonical hostname stored for local terminal hosts.
const String localTerminalHostname = 'local';

/// Canonical port stored for local terminal hosts (unused for connect).
const int localTerminalPort = 0;
