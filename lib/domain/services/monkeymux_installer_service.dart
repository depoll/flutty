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
    this.installedDuringCall = false,
  });

  /// Absolute remote executable path.
  final String executablePath;

  /// Resolved remote platform key.
  final String platform;

  /// Installed MonkeyMux version.
  final String version;

  /// Whether this call uploaded the helper instead of reusing an existing copy.
  final bool installedDuringCall;

  /// Whether the resolved platform is Windows, which affects how the helper is
  /// invoked (native `.exe` path and double-quoted shell arguments).
  bool get isWindows => platform.startsWith('windows-');
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
  static final _installRequests = <int, _MonkeyMuxInstallInFlight>{};

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
    if (existingRequest != null &&
        (existingRequest.canPrompt || confirmInstall == null)) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'join_inflight',
        fields: {
          'connectionId': connectionId,
          'canPrompt': existingRequest.canPrompt,
        },
      );
      return existingRequest.future;
    }
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.install',
        'replace_probe_with_confirmable',
        fields: {'connectionId': connectionId},
      );
    }

    final request = _MonkeyMuxInstallInFlight(
      canPrompt: confirmInstall != null,
    );
    _installRequests[connectionId] = request;
    // A prompt-capable install supersedes a probe-only install, but callers
    // already waiting on the probe should receive the prompt-capable result.
    existingRequest?.supersedeWith(request.future);
    request.bind(
      _ensureInstalled(
        session,
        priority: priority,
        confirmInstall: confirmInstall,
      ),
    );
    request.future.then((installation) {
      if (identical(_installRequests[connectionId], request)) {
        _installCache[connectionId] = installation;
      }
    }, onError: (_) {}).ignore();
    request.future.whenComplete(() {
      if (identical(_installRequests[connectionId], request)) {
        _installRequests.remove(connectionId);
      }
    }).ignore();
    return request.future;
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

    final sftp = await session.openStandaloneSftp();
    try {
      final homeDirectory = await _remoteFileService.resolveInitialDirectory(
        sftp,
      );
      final installDirectory = joinRemotePath(
        homeDirectory,
        '.monkeyssh/bin/monkeymux/${manifest.version}/$platform',
      );
      final isWindows = _isWindowsPlatform(platform);
      final executableName = isWindows ? 'monkeymux.exe' : 'monkeymux';
      final executableSftpPath = joinRemotePath(
        installDirectory,
        executableName,
      );
      // SFTP presents Windows paths as `/C:/...`; the shell (attach/control
      // commands, certutil) needs the native `C:\...` form.
      final executablePath = isWindows
          ? sftpPathToWindowsShellPath(executableSftpPath)
          : executableSftpPath;
      if (await _remoteShaMatches(
        session,
        executablePath,
        entry.sha256,
        isWindows: isWindows,
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
      final temporaryCommandPath = isWindows
          ? sftpPathToWindowsShellPath(temporaryExecutablePath)
          : temporaryExecutablePath;
      var movedTemporaryExecutable = false;
      try {
        await _remoteFileService.uploadBytes(
          sftp: sftp,
          remotePath: temporaryExecutablePath,
          bytes: assetBytes,
        );
        if (!isWindows) {
          // Windows has no execute bit; a `.exe` runs by extension.
          await _runRemoteCommand(
            session,
            'chmod 700 ${_shellQuote(temporaryExecutablePath)}',
            priority: priority,
          );
        }
        if (!await _remoteShaMatches(
          session,
          temporaryCommandPath,
          entry.sha256,
          isWindows: isWindows,
          priority: priority,
        )) {
          throw const MonkeyMuxInstallException(
            'Uploaded MonkeyMux checksum verification failed.',
          );
        }
        if (isWindows) {
          // SFTP rename cannot overwrite an existing file and there is no
          // atomic force-move over cmd/PowerShell, so clear any stale target
          // first, then rename the verified upload into place. Only ignore a
          // missing target (the common fresh-install case); surface real errors
          // (for example a permission error or a locked, running helper) so we
          // abort with the existing binary intact instead of renaming onto a
          // half-removed target.
          try {
            await sftp.remove(executableSftpPath);
          } on SftpStatusError catch (error) {
            if (error.code != SftpStatusCode.noSuchFile) {
              rethrow;
            }
          }
          await sftp.rename(temporaryExecutablePath, executableSftpPath);
        } else {
          await _runRemoteCommand(
            session,
            'mv -f ${_shellQuote(temporaryExecutablePath)} '
            '${_shellQuote(executableSftpPath)}',
            priority: priority,
          );
        }
        movedTemporaryExecutable = true;
      } on Object catch (error, stackTrace) {
        if (!movedTemporaryExecutable) {
          await _removeRemoteTemporaryFile(
            session,
            temporaryExecutablePath,
            sftp: sftp,
            isWindows: isWindows,
            priority: priority,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (!await _remoteShaMatches(
        session,
        executablePath,
        entry.sha256,
        isWindows: isWindows,
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
        installedDuringCall: true,
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
    final platform = session.remoteIsWindows
        ? await _probeWindowsPlatform(session, priority: priority)
        : await _probePosixPlatform(session, priority: priority);
    DiagnosticsLogService.instance.info(
      'monkeymux.install',
      'platform_probe',
      fields: {'connectionId': session.connectionId, 'platform': platform},
    );
    return platform;
  }

  Future<String> _probePosixPlatform(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    String output;
    try {
      output = await _runRemoteCommand(
        session,
        r'printf "%s\n%s\n" "$(uname -s 2>/dev/null)" "$(uname -m 2>/dev/null)"',
        priority: priority,
      );
    } on MonkeyMuxInstallException {
      output = '';
    }
    final platform = _parsePosixPlatform(output);
    if (platform != null) {
      return platform;
    }
    // The POSIX probe produced nothing usable. The host may be a Windows SSH
    // server whose banner did not identify itself, so fall back to a Windows
    // probe that self-validates before being trusted.
    final arch = await _probeWindowsArch(session, priority: priority);
    if (arch != null) {
      return 'windows-$arch';
    }
    throw const MonkeyMuxInstallException(
      'Could not detect remote MonkeyMux platform.',
    );
  }

  String? _parsePosixPlatform(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) {
      return null;
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
    if (osName.isEmpty || arch.isEmpty) {
      return null;
    }
    return '$osName-$arch';
  }

  Future<String> _probeWindowsPlatform(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    final arch = await _probeWindowsArch(session, priority: priority);
    if (arch == null) {
      // The banner confirmed Windows but the architecture probe failed or was
      // unrecognized. Fail with a clear error rather than guessing amd64 and
      // installing a helper the host may not be able to run.
      throw const MonkeyMuxInstallException(
        'Could not detect the remote Windows CPU architecture.',
      );
    }
    return 'windows-$arch';
  }

  /// Detects the Windows CPU architecture. Returns `amd64`/`arm64` for
  /// supported hosts, a raw token such as `x86` for a recognized-but-unbundled
  /// architecture (so the caller surfaces a clear "not bundled" error), or null
  /// when the host does not look like Windows. Uses `cmd /c` so it works
  /// regardless of whether the default remote shell is cmd.exe or PowerShell.
  Future<String?> _probeWindowsArch(
    SshSession session, {
    required SshExecPriority priority,
  }) async {
    String output;
    try {
      output = await _runRawRemoteCommand(
        session,
        'cmd /c echo %OS% %PROCESSOR_ARCHITECTURE% %PROCESSOR_ARCHITEW6432%',
        priority: priority,
      );
    } on Object {
      return null;
    }
    final lower = output.toLowerCase();
    if (!lower.contains('windows_nt')) {
      return null;
    }
    if (lower.contains('arm64')) {
      return 'arm64';
    }
    if (lower.contains('amd64') || lower.contains('x86_64')) {
      return 'amd64';
    }
    if (lower.contains('x86')) {
      // 32-bit Windows: no bundled binary. Return the token so the caller fails
      // with an explicit "not bundled for windows-x86" instead of mis-selecting
      // the amd64 helper.
      return 'x86';
    }
    return null;
  }

  bool _isWindowsPlatform(String platform) => platform.startsWith('windows-');

  /// Extracts the SHA-256 digest from `certutil -hashfile` output, tolerating
  /// the byte-spaced formatting older certutil versions emit.
  String? _extractCertutilSha(String output) {
    for (final line in const LineSplitter().convert(output)) {
      final compact = line.replaceAll(RegExp(r'\s'), '').toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(compact)) {
        return compact;
      }
    }
    return null;
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
    required bool isWindows,
    required SshExecPriority priority,
  }) async {
    try {
      if (isWindows) {
        final output = await _runRawRemoteCommand(
          session,
          'certutil -hashfile "$executablePath" SHA256',
          priority: priority,
        );
        final digest = _extractCertutilSha(output);
        return digest != null && digest == expectedSha.toLowerCase();
      }
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
    required SftpClient sftp,
    required bool isWindows,
    required SshExecPriority priority,
  }) async {
    try {
      if (isWindows) {
        await sftp.remove(remotePath);
        return;
      }
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

class _MonkeyMuxInstallInFlight {
  _MonkeyMuxInstallInFlight({required this.canPrompt});

  final bool canPrompt;
  final _completer = Completer<MonkeyMuxInstallation>();
  bool _superseded = false;

  Future<MonkeyMuxInstallation> get future => _completer.future;

  void bind(Future<MonkeyMuxInstallation> operation) {
    operation
        .then(
          (installation) {
            if (!_superseded && !_completer.isCompleted) {
              _completer.complete(installation);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_superseded && !_completer.isCompleted) {
              _completer.completeError(error, stackTrace);
            }
          },
        )
        .ignore();
  }

  void supersedeWith(Future<MonkeyMuxInstallation> replacement) {
    if (_completer.isCompleted) {
      return;
    }
    _superseded = true;
    replacement
        .then(
          (installation) {
            if (!_completer.isCompleted) {
              _completer.complete(installation);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_completer.isCompleted) {
              _completer.completeError(error, stackTrace);
            }
          },
        )
        .ignore();
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

/// Runs a command without the POSIX completion-marker wrapper, collecting stdout
/// until the channel closes. Used for probes and Windows shells (cmd.exe /
/// PowerShell) that cannot evaluate the POSIX marker script.
Future<String> _runRawRemoteCommand(
  SshSession session,
  String command, {
  SshExecPriority priority = SshExecPriority.normal,
}) => session.runQueuedExec(() async {
  final execSession = await session.execute(command);
  try {
    execSession.stderr.drain<void>().ignore();
    final output = StringBuffer();
    await for (final chunk
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .timeout(_monkeyMuxInstallTimeout)) {
      output.write(chunk);
    }
    return output.toString();
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
