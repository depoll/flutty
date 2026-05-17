import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'remote_file_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Asset path for the bundled MonkeyMux binary manifest.
const monkeyMuxManifestAssetPath = 'assets/monkeymux/manifest.json';

const _monkeyMuxInstallTimeout = Duration(seconds: 20);
const _monkeyMuxExecMarker = '__monkeymux_exec_done__';

/// Provides the app-bundled MonkeyMux binary manifest.
final monkeyMuxManifestProvider = FutureProvider<MonkeyMuxManifest>(
  (ref) => MonkeyMuxManifest.load(),
);

/// Installs and verifies MonkeyMux helpers on remote SSH hosts.
final monkeyMuxInstallerServiceProvider = Provider<MonkeyMuxInstallerService>(
  (ref) => MonkeyMuxInstallerService(
    manifestFuture: ref.watch(monkeyMuxManifestProvider.future),
    remoteFileService: ref.watch(remoteFileServiceProvider),
  ),
);

/// Parsed MonkeyMux asset manifest.
class MonkeyMuxManifest {
  /// Creates a parsed MonkeyMux asset manifest.
  const MonkeyMuxManifest({required this.version, required this.entries});

  /// Parses a manifest JSON object.
  factory MonkeyMuxManifest.fromJson(Map<String, Object?> json) {
    final entriesJson = json['entries'];
    return MonkeyMuxManifest(
      version: json['version'] as String? ?? '',
      entries: entriesJson is List
          ? entriesJson
                .whereType<Map<String, Object?>>()
                .map(MonkeyMuxManifestEntry.fromJson)
                .toList(growable: false)
          : const <MonkeyMuxManifestEntry>[],
    );
  }

  /// Loads the default bundled manifest.
  static Future<MonkeyMuxManifest> load({AssetBundle? assetBundle}) async {
    final bundle = assetBundle ?? rootBundle;
    final jsonText = await bundle.loadString(monkeyMuxManifestAssetPath);
    return MonkeyMuxManifest.fromJson(
      jsonDecode(jsonText) as Map<String, Object?>,
    );
  }

  /// Version shared by all manifest entries.
  final String version;

  /// Bundled platform binaries.
  final List<MonkeyMuxManifestEntry> entries;

  /// Finds the entry for [platformKey].
  MonkeyMuxManifestEntry? entryForPlatform(String platformKey) {
    for (final entry in entries) {
      if (entry.platform == platformKey) {
        return entry;
      }
    }
    return null;
  }
}

/// One bundled MonkeyMux binary entry.
class MonkeyMuxManifestEntry {
  /// Creates a MonkeyMux manifest entry.
  const MonkeyMuxManifestEntry({
    required this.platform,
    required this.asset,
    required this.sha256,
    required this.size,
    this.encoding,
  });

  /// Parses a manifest entry JSON object.
  factory MonkeyMuxManifestEntry.fromJson(Map<String, Object?> json) =>
      MonkeyMuxManifestEntry(
        platform: json['platform'] as String? ?? '',
        asset: json['asset'] as String? ?? '',
        encoding: json['encoding'] as String?,
        sha256: json['sha256'] as String? ?? '',
        size: json['size'] as int? ?? 0,
      );

  /// Platform key, for example `linux-amd64`.
  final String platform;

  /// Flutter asset path for the binary data.
  final String asset;

  /// Optional asset encoding used to keep bundled executables as data files.
  final String? encoding;

  /// Expected SHA-256 of the binary bytes.
  final String sha256;

  /// Expected binary size in bytes.
  final int size;
}

/// Result of installing or reusing a remote MonkeyMux helper.
class MonkeyMuxInstallation {
  /// Creates a MonkeyMux installation result.
  const MonkeyMuxInstallation({
    required this.executablePath,
    required this.platform,
    required this.version,
  });

  /// Absolute remote executable path.
  final String executablePath;

  /// Resolved remote platform key.
  final String platform;

  /// Installed MonkeyMux version.
  final String version;
}

/// Details for a pending MonkeyMux helper install.
class MonkeyMuxInstallRequest {
  /// Creates pending MonkeyMux install details.
  const MonkeyMuxInstallRequest({
    required this.platform,
    required this.version,
    required this.size,
  });

  /// Remote platform key for the helper, for example `linux-amd64`.
  final String platform;

  /// MonkeyMux helper version that would be installed.
  final String version;

  /// Helper binary size in bytes.
  final int size;
}

/// Confirms whether MonkeyMux may install its helper on the connected host.
typedef MonkeyMuxInstallConfirmation =
    Future<bool> Function(MonkeyMuxInstallRequest request);

/// Error thrown when MonkeyMux cannot be installed or used.
class MonkeyMuxInstallException implements Exception {
  /// Creates a MonkeyMux installation error.
  const MonkeyMuxInstallException(this.message);

  /// Human-readable failure message.
  final String message;

  @override
  String toString() => message;
}

/// Error thrown when MonkeyMux needs app-level install confirmation.
class MonkeyMuxInstallConfirmationRequiredException
    extends MonkeyMuxInstallException {
  /// Creates a confirmation-required install error.
  const MonkeyMuxInstallConfirmationRequiredException()
    : super('MonkeyMux install requires confirmation.');
}

/// Error thrown when the user declines a MonkeyMux helper install.
class MonkeyMuxInstallDeclinedException extends MonkeyMuxInstallException {
  /// Creates a declined install error.
  const MonkeyMuxInstallDeclinedException()
    : super('MonkeyMux install was canceled.');
}

/// Installs and verifies the bundled MonkeyMux helper on a remote host.
class MonkeyMuxInstallerService {
  /// Creates a MonkeyMux installer.
  const MonkeyMuxInstallerService({
    required Future<MonkeyMuxManifest> manifestFuture,
    required RemoteFileService remoteFileService,
    AssetBundle? assetBundle,
  }) : _manifestFuture = manifestFuture,
       _remoteFileService = remoteFileService,
       _assetBundle = assetBundle;

  final Future<MonkeyMuxManifest> _manifestFuture;
  final RemoteFileService _remoteFileService;
  final AssetBundle? _assetBundle;
  static final _installCache = <int, MonkeyMuxInstallation>{};
  static final _installRequests = <int, Future<MonkeyMuxInstallation>>{};

  /// Installs the helper if needed and returns its executable path.
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final connectionId = session.connectionId;
    final cachedInstallation = _installCache[connectionId];
    if (cachedInstallation != null) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'reuse_cached',
        fields: {
          'connectionId': connectionId,
          'platform': cachedInstallation.platform,
        },
      );
      return cachedInstallation;
    }

    final existingRequest = _installRequests[connectionId];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'join_inflight',
        fields: {'connectionId': connectionId},
      );
      return existingRequest;
    }

    final request = _ensureInstalled(
      session,
      priority: priority,
      confirmInstall: confirmInstall,
    );
    _installRequests[connectionId] = request;
    request.then((installation) {
      if (identical(_installRequests[connectionId], request)) {
        _installCache[connectionId] = installation;
      }
    }, onError: (_) {}).ignore();
    request.whenComplete(() {
      if (identical(_installRequests[connectionId], request)) {
        _installRequests.remove(connectionId);
      }
    }).ignore();
    return request;
  }

  /// Clears cached install state for a disconnected SSH connection.
  void clearCache(int connectionId) {
    _installCache.remove(connectionId);
    _installRequests.remove(connectionId);
  }

  Future<MonkeyMuxInstallation> _ensureInstalled(
    SshSession session, {
    required SshExecPriority priority,
    required MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final platform = await probePlatform(session, priority: priority);
    final manifest = await _manifestFuture;
    final entry = manifest.entryForPlatform(platform);
    if (entry == null) {
      throw MonkeyMuxInstallException(
        'MonkeyMux is not bundled for $platform.',
      );
    }
    final assetBytes = await _loadAssetBytes(entry);
    final localDigest = sha256.convert(assetBytes).toString();
    if (localDigest != entry.sha256) {
      throw const MonkeyMuxInstallException(
        'Bundled MonkeyMux checksum does not match the manifest.',
      );
    }

    final sftp = await session.sftp();
    try {
      final homeDirectory = await _remoteFileService.resolveInitialDirectory(
        sftp,
      );
      final installDirectory = joinRemotePath(
        homeDirectory,
        '.monkeyssh/bin/monkeymux/${manifest.version}/$platform',
      );
      final executablePath = joinRemotePath(installDirectory, 'monkeymux');
      if (await _remoteShaMatches(
        session,
        executablePath,
        entry.sha256,
        priority: priority,
      )) {
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'reuse_existing',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );
        return MonkeyMuxInstallation(
          executablePath: executablePath,
          platform: platform,
          version: manifest.version,
        );
      }

      final installRequest = MonkeyMuxInstallRequest(
        platform: platform,
        version: manifest.version,
        size: entry.size,
      );
      if (confirmInstall == null) {
        DiagnosticsLogService.instance.warning(
          'monkeymux.install',
          'confirmation_required',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );
        throw const MonkeyMuxInstallConfirmationRequiredException();
      }
      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        'confirmation_requested',
        fields: {
          'connectionId': session.connectionId,
          'platform': platform,
          'size': entry.size,
        },
      );
      final confirmed = await confirmInstall(installRequest);
      if (!confirmed) {
        DiagnosticsLogService.instance.info(
          'monkeymux.install',
          'confirmation_declined',
          fields: {'connectionId': session.connectionId, 'platform': platform},
        );
        throw const MonkeyMuxInstallDeclinedException();
      }
      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        'confirmation_accepted',
        fields: {'connectionId': session.connectionId, 'platform': platform},
      );

      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        'upload_start',
        fields: {
          'connectionId': session.connectionId,
          'platform': platform,
          'size': entry.size,
        },
      );
      await _remoteFileService.ensureDirectoryExists(sftp, installDirectory);
      final temporaryExecutablePath = joinRemotePath(
        installDirectory,
        '.monkeymux.${session.connectionId}.'
        '${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      var movedTemporaryExecutable = false;
      try {
        await _remoteFileService.uploadBytes(
          sftp: sftp,
          remotePath: temporaryExecutablePath,
          bytes: assetBytes,
        );
        await _runRemoteCommand(
          session,
          'chmod 700 ${_shellQuote(temporaryExecutablePath)}',
          priority: priority,
        );
        if (!await _remoteShaMatches(
          session,
          temporaryExecutablePath,
          entry.sha256,
          priority: priority,
        )) {
          throw const MonkeyMuxInstallException(
            'Uploaded MonkeyMux checksum verification failed.',
          );
        }
        await _runRemoteCommand(
          session,
          'mv -f ${_shellQuote(temporaryExecutablePath)} '
          '${_shellQuote(executablePath)}',
          priority: priority,
        );
        movedTemporaryExecutable = true;
      } on Object catch (error, stackTrace) {
        if (!movedTemporaryExecutable) {
          await _removeRemoteTemporaryFile(
            session,
            temporaryExecutablePath,
            priority: priority,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!await _remoteShaMatches(
        session,
        executablePath,
        entry.sha256,
        priority: priority,
      )) {
        throw const MonkeyMuxInstallException(
          'Installed MonkeyMux checksum verification failed.',
        );
      }
      DiagnosticsLogService.instance.info(
        'monkeymux.install',
        'upload_complete',
        fields: {'connectionId': session.connectionId, 'platform': platform},
      );
      return MonkeyMuxInstallation(
        executablePath: executablePath,
        platform: platform,
        version: manifest.version,
      );
    } finally {
      sftp.close();
    }
  }

  /// Probes the remote host and returns a manifest platform key.
  Future<String> probePlatform(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
  }) async {
    final output = await _runRemoteCommand(
      session,
      r'printf "%s\n%s\n" "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"',
      priority: priority,
    );
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) {
      throw const MonkeyMuxInstallException(
        'Could not detect remote MonkeyMux platform.',
      );
    }
    final osName = switch (lines[0].toLowerCase()) {
      'darwin' => 'darwin',
      'linux' => 'linux',
      final value => value,
    };
    final arch = switch (lines[1].toLowerCase()) {
      'x86_64' || 'amd64' => 'amd64',
      'aarch64' || 'arm64' => 'arm64',
      final value => value,
    };
    final platform = '$osName-$arch';
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'platform_probe',
      fields: {'connectionId': session.connectionId, 'platform': platform},
    );
    return platform;
  }

  Future<Uint8List> _loadAssetBytes(MonkeyMuxManifestEntry entry) async {
    final bundle = _assetBundle ?? rootBundle;
    final bytes = await bundle.load(entry.asset);
    final assetBytes = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    switch (entry.encoding) {
      case null:
      case '':
      case 'none':
        return assetBytes;
      case 'gzip':
        return Uint8List.fromList(gzip.decode(assetBytes));
      default:
        throw MonkeyMuxInstallException(
          'Unsupported MonkeyMux asset encoding: ${entry.encoding}',
        );
    }
  }

  Future<bool> _remoteShaMatches(
    SshSession session,
    String executablePath,
    String expectedSha, {
    required SshExecPriority priority,
  }) async {
    try {
      final output = await _runRemoteCommand(
        session,
        '(sha256sum ${_shellQuote(executablePath)} 2>/dev/null || '
        'shasum -a 256 ${_shellQuote(executablePath)} 2>/dev/null) | '
        r"awk '{print $1}'",
        priority: priority,
      );
      return output.trim() == expectedSha;
    } on Exception {
      return false;
    }
  }

  Future<void> _removeRemoteTemporaryFile(
    SshSession session,
    String remotePath, {
    required SshExecPriority priority,
  }) async {
    try {
      await _runRemoteCommand(
        session,
        'rm -f ${_shellQuote(remotePath)}',
        priority: priority,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'temp_cleanup_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }
}

Future<String> _runRemoteCommand(
  SshSession session,
  String command, {
  SshExecPriority priority = SshExecPriority.normal,
}) => session.runQueuedExec(() async {
  final execSession = await session.execute(_markRemoteCommandDone(command));
  try {
    execSession.stderr.drain<void>().ignore();
    return await _readStdoutUntilMarker(execSession);
  } finally {
    execSession.close();
  }
}, priority: priority);

String _markRemoteCommandDone(String command) =>
    '{ $command; __monkeymux_status__=\$?; '
    'printf ${_shellQuote('\n$_monkeyMuxExecMarker:%s\n')} '
    r'"$__monkeymux_status__"; }';

Future<String> _readStdoutUntilMarker(SSHSession execSession) async {
  final output = StringBuffer();
  await for (final chunk
      in execSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .timeout(_monkeyMuxInstallTimeout)) {
    output.write(chunk);
    final currentOutput = output.toString();
    final markerPattern = RegExp(
      '(?:^|\\n)${RegExp.escape(_monkeyMuxExecMarker)}:([0-9]+)\\n',
    );
    final markers = markerPattern.allMatches(currentOutput);
    final marker = markers.isEmpty ? null : markers.last;
    if (marker == null) {
      continue;
    }
    final status = int.parse(marker.group(1)!);
    if (status != 0) {
      throw MonkeyMuxInstallException(
        'Remote command failed with exit status $status.',
      );
    }
    return currentOutput.substring(0, marker.start).trimRight();
  }
  throw const MonkeyMuxInstallException(
    'Remote command closed before completion marker.',
  );
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
