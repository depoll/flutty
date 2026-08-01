import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import 'android_linux_terminal_launcher.dart';
import 'key_service.dart';
import 'local_notification_service.dart';

/// Default SSH port used by the Linux Terminal setup script.
const androidLinuxTerminalSetupPort = 8022;

/// Default username used inside the AVF Debian image.
const androidLinuxTerminalSetupUsername = 'droid';

/// Progress / result of an Android Linux Terminal setup attempt.
@immutable
class AndroidLinuxTerminalSetupState {
  /// Creates a setup state snapshot.
  const AndroidLinuxTerminalSetupState({
    required this.phase,
    required this.message,
    this.hostId,
    this.keyId,
    this.publicKey,
    this.script,
    this.reachableHost,
    this.reachablePort,
  });

  /// High-level phase for UI.
  final AndroidLinuxTerminalSetupPhase phase;

  /// User-visible status message (no secrets).
  final String message;

  /// Host created when setup succeeds.
  final int? hostId;

  /// SSH key generated for this setup.
  final int? keyId;

  /// Public key embedded in the setup script.
  final String? publicKey;

  /// Full setup script currently on the clipboard.
  final String? script;

  /// Host that answered the SSH probe.
  final String? reachableHost;

  /// Port that answered the SSH probe.
  final int? reachablePort;

  /// Idle state.
  static const idle = AndroidLinuxTerminalSetupState(
    phase: AndroidLinuxTerminalSetupPhase.idle,
    message: '',
  );
}

/// Phases of the Android Linux Terminal setup flow.
enum AndroidLinuxTerminalSetupPhase {
  /// No active setup.
  idle,

  /// Preparing key/script and launching Terminal.
  preparing,

  /// Waiting for the user to run the script / enable networking.
  waitingForUser,

  /// Probing for SSH.
  probing,

  /// SSH host was created successfully.
  succeeded,

  /// Setup failed or was cancelled.
  failed,
}

/// Coordinates clipboard script + notification + SSH probe for AVF Terminal.
class AndroidLinuxTerminalSetupService {
  /// Creates a setup service.
  AndroidLinuxTerminalSetupService({
    required HostRepository hostRepository,
    required KeyRepository keyRepository,
    required KeyService keyService,
    required LocalNotificationService notificationService,
    AndroidLinuxTerminalLauncher? launcher,
    Future<bool> Function(String host, int port)? probeSsh,
  }) : _hostRepository = hostRepository,
       _keyRepository = keyRepository,
       _keyService = keyService,
       _notificationService = notificationService,
       _launcher = launcher ?? AndroidLinuxTerminalLauncher(),
       _probeSsh = probeSsh ?? _defaultProbeSsh;

  final HostRepository _hostRepository;
  final KeyRepository _keyRepository;
  final KeyService _keyService;
  final LocalNotificationService _notificationService;
  final AndroidLinuxTerminalLauncher _launcher;
  final Future<bool> Function(String host, int port) _probeSsh;

  final _stateController =
      StreamController<AndroidLinuxTerminalSetupState>.broadcast();
  AndroidLinuxTerminalSetupState _state = AndroidLinuxTerminalSetupState.idle;
  StreamSubscription<LinuxTerminalSetupNotificationPayload>?
  _notificationSubscription;
  Timer? _probeTimer;
  int? _activeKeyId;
  String? _activePublicKey;
  String? _activeScript;
  bool _disposed = false;

  /// Latest setup state.
  AndroidLinuxTerminalSetupState get state => _state;

  /// Stream of setup state changes.
  Stream<AndroidLinuxTerminalSetupState> get states => _stateController.stream;

  /// Whether this flow is available on the current platform.
  bool get isSupported => _launcher.isSupported;

  /// Starts listening for setup notification actions.
  void start() {
    _notificationSubscription ??= _notificationService.linuxTerminalSetupTaps
        .listen(_handleNotificationAction);
  }

  /// Releases timers/subscriptions.
  void dispose() {
    _disposed = true;
    _probeTimer?.cancel();
    unawaited(_notificationSubscription?.cancel());
    unawaited(_stateController.close());
  }

  /// Begins setup: generate key, copy script, notify, open Terminal.
  Future<AndroidLinuxTerminalSetupState> beginSetup() async {
    if (!isSupported) {
      return _emit(
        const AndroidLinuxTerminalSetupState(
          phase: AndroidLinuxTerminalSetupPhase.failed,
          message: 'Linux Terminal setup is only available on Android.',
        ),
      );
    }

    _emit(
      const AndroidLinuxTerminalSetupState(
        phase: AndroidLinuxTerminalSetupPhase.preparing,
        message: 'Preparing setup script…',
      ),
    );

    final status = await _launcher.getStatus();
    final key = await _ensureSetupKey();
    if (key == null) {
      return _emit(
        const AndroidLinuxTerminalSetupState(
          phase: AndroidLinuxTerminalSetupPhase.failed,
          message: 'Could not create an SSH key for Linux Terminal setup.',
        ),
      );
    }

    final publicKey = _keyService.exportPublicKey(
      key,
      comment: 'monkeyssh-android-linux-terminal',
    );
    final script = buildAndroidLinuxTerminalSetupScript(
      publicKey: publicKey,
      username: androidLinuxTerminalSetupUsername,
      port: androidLinuxTerminalSetupPort,
    );

    _activeKeyId = key.id;
    _activePublicKey = publicKey;
    _activeScript = script;

    await Clipboard.setData(ClipboardData(text: script));
    await _notificationService.showLinuxTerminalSetup(
      title: 'Linux Terminal setup',
      body: status.canLaunch
          ? 'Script copied. Paste it in Terminal, then tap Test SSH.'
          : 'Enable Linux Terminal in Developer options, then open Terminal.',
    );

    if (status.canLaunch) {
      await _launcher.openTerminal();
    } else {
      await _launcher.openDeveloperOptions();
    }

    _startProbing();
    return _emit(
      AndroidLinuxTerminalSetupState(
        phase: AndroidLinuxTerminalSetupPhase.waitingForUser,
        message: status.canLaunch
            ? 'Paste the script in Linux Terminal, then return here or tap Test SSH.'
            : 'Turn on Linux development environment, open Terminal, paste the script.',
        keyId: key.id,
        publicKey: publicKey,
        script: script,
      ),
    );
  }

  /// Copies the active setup script to the clipboard again.
  Future<void> copyScriptAgain() async {
    final script = _activeScript;
    if (script == null || script.isEmpty) {
      await beginSetup();
      return;
    }
    await Clipboard.setData(ClipboardData(text: script));
    await _notificationService.showLinuxTerminalSetup(
      title: 'Linux Terminal setup',
      body: 'Setup script copied again. Paste it in Terminal.',
    );
    _emit(
      _state.copyWith(
        phase: AndroidLinuxTerminalSetupPhase.waitingForUser,
        message: 'Setup script copied again. Paste it in Terminal.',
      ),
    );
  }

  /// Opens Terminal or Developer Options.
  Future<void> openTerminalOrSettings() async {
    final status = await _launcher.getStatus();
    if (status.canLaunch) {
      await _launcher.openTerminal();
      return;
    }
    await _launcher.openDeveloperOptions();
  }

  /// Opens Terminal port-forward settings when available.
  Future<void> openPortForwardingSettings() =>
      _launcher.openPortForwardingSettings();

  /// Probes for SSH and creates a host on success.
  Future<AndroidLinuxTerminalSetupState> testConnectionAndFinish() async {
    if (_activeKeyId == null || _activePublicKey == null) {
      return beginSetup();
    }
    _emit(
      _state.copyWith(
        phase: AndroidLinuxTerminalSetupPhase.probing,
        message: 'Looking for SSH on port $androidLinuxTerminalSetupPort…',
      ),
    );
    final endpoint = await _findReachableEndpoint();
    if (endpoint == null) {
      await _notificationService.showLinuxTerminalSetup(
        title: 'Linux Terminal setup',
        body:
            'SSH not reachable yet. In Terminal, run the script and enable port forwarding if needed.',
      );
      return _emit(
        _state.copyWith(
          phase: AndroidLinuxTerminalSetupPhase.waitingForUser,
          message:
              'SSH not reachable on port $androidLinuxTerminalSetupPort yet. '
              'If the VM is isolated, open Terminal port forwarding to $androidLinuxTerminalSetupPort.',
        ),
      );
    }

    final hostId = await _createOrUpdateHost(
      hostname: endpoint.host,
      port: endpoint.port,
      keyId: _activeKeyId!,
    );
    _stopProbing();
    await _notificationService.clearLinuxTerminalSetup();
    return _emit(
      AndroidLinuxTerminalSetupState(
        phase: AndroidLinuxTerminalSetupPhase.succeeded,
        message: 'Added Linux Terminal host ${endpoint.host}:${endpoint.port}.',
        hostId: hostId,
        keyId: _activeKeyId,
        publicKey: _activePublicKey,
        script: _activeScript,
        reachableHost: endpoint.host,
        reachablePort: endpoint.port,
      ),
    );
  }

  /// Cancels an in-progress setup.
  Future<void> cancel() async {
    _stopProbing();
    await _notificationService.clearLinuxTerminalSetup();
    _activeKeyId = null;
    _activePublicKey = null;
    _activeScript = null;
    _emit(AndroidLinuxTerminalSetupState.idle);
  }

  Future<void> _handleNotificationAction(
    LinuxTerminalSetupNotificationPayload payload,
  ) async {
    switch (payload.action) {
      case linuxTerminalSetupActionCopy:
        await copyScriptAgain();
      case linuxTerminalSetupActionOpen:
        await openTerminalOrSettings();
      case linuxTerminalSetupActionTest:
        await testConnectionAndFinish();
      case linuxTerminalSetupActionCancel:
        await cancel();
      case null:
        // Body tap: bring user back and restate status.
        await _notificationService.showLinuxTerminalSetup(
          title: 'Linux Terminal setup',
          body: _state.message.isEmpty
              ? 'Continue setup from MonkeySSH.'
              : _state.message,
        );
      default:
        break;
    }
  }

  void _startProbing() {
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_probeInBackground());
    });
  }

  void _stopProbing() {
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  Future<void> _probeInBackground() async {
    if (_disposed ||
        _state.phase == AndroidLinuxTerminalSetupPhase.succeeded ||
        _state.phase == AndroidLinuxTerminalSetupPhase.idle ||
        _state.phase == AndroidLinuxTerminalSetupPhase.failed) {
      return;
    }
    final endpoint = await _findReachableEndpoint();
    if (endpoint == null) {
      return;
    }
    await testConnectionAndFinish();
  }

  Future<({String host, int port})?> _findReachableEndpoint() async {
    final candidates = await _candidateHosts();
    for (final host in candidates) {
      if (await _probeSsh(host, androidLinuxTerminalSetupPort)) {
        return (host: host, port: androidLinuxTerminalSetupPort);
      }
    }
    return null;
  }

  Future<List<String>> _candidateHosts() async {
    final hosts = <String>{'127.0.0.1', 'localhost'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            hosts.add(address.address);
          }
        }
      }
    } on Object {
      // Best-effort only.
    }
    return hosts.toList(growable: false);
  }

  Future<SshKey?> _ensureSetupKey() async {
    final existing = await _keyRepository.getAll();
    for (final key in existing) {
      if (key.name == 'Android Linux Terminal' &&
          key.publicKey.trim().isNotEmpty &&
          key.privateKey.trim().isNotEmpty) {
        return key;
      }
    }
    return _keyService.generateKey(
      name: 'Android Linux Terminal',
      keyType: SshKeyType.ed25519,
    );
  }

  Future<int> _createOrUpdateHost({
    required String hostname,
    required int port,
    required int keyId,
  }) async {
    final hosts = await _hostRepository.getAll();
    for (final host in hosts) {
      if (host.label == 'Android Linux Terminal' ||
          (host.hostname == hostname && host.port == port)) {
        await _hostRepository.update(
          host.copyWith(
            label: 'Android Linux Terminal',
            hostname: hostname,
            port: port,
            username: androidLinuxTerminalSetupUsername,
            keyId: Value(keyId),
            password: const Value(null),
            notes: const Value(
              'Created by MonkeySSH Linux Terminal setup. '
              'If connect fails, enable port forwarding in the Terminal app.',
            ),
          ),
        );
        return host.id;
      }
    }

    return _hostRepository.insert(
      HostsCompanion.insert(
        label: 'Android Linux Terminal',
        hostname: hostname,
        port: Value(port),
        username: androidLinuxTerminalSetupUsername,
        keyId: Value(keyId),
        notes: const Value(
          'Created by MonkeySSH Linux Terminal setup. '
          'If connect fails, enable port forwarding in the Terminal app.',
        ),
      ),
    );
  }

  AndroidLinuxTerminalSetupState _emit(AndroidLinuxTerminalSetupState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
    return next;
  }

  static Future<bool> _defaultProbeSsh(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 700),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }
}

/// Builds the shell script the user pastes into Android Linux Terminal.
@visibleForTesting
String buildAndroidLinuxTerminalSetupScript({
  required String publicKey,
  required String username,
  required int port,
}) {
  final normalizedKey = publicKey.trim();
  return '''
# MonkeySSH → Android Linux Terminal setup
# 1) Paste this whole script into Linux Terminal and press Enter
# 2) If SSH is not reachable from MonkeySSH, open Terminal → Port forwarding
#    and forward host 127.0.0.1:$port → guest $port
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y openssh-server
sudo mkdir -p /run/sshd /home/$username/.ssh
sudo chmod 700 /home/$username/.ssh
echo ${shellSingleQuote(normalizedKey)} | sudo tee /home/$username/.ssh/authorized_keys >/dev/null
sudo chown -R $username:$username /home/$username/.ssh
sudo chmod 600 /home/$username/.ssh/authorized_keys
if [ -f /etc/ssh/sshd_config ]; then
  sudo sed -i 's/^#\\?Port .*/Port $port/' /etc/ssh/sshd_config || true
  grep -q '^Port $port' /etc/ssh/sshd_config || echo 'Port $port' | sudo tee -a /etc/ssh/sshd_config >/dev/null
  sudo sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  sudo sed -i 's/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config || true
fi
sudo ssh-keygen -A
sudo service ssh restart || sudo systemctl restart ssh || sudo /usr/sbin/sshd
echo
echo "MONKEYSSH_AVF_READY user=$username port=$port"
echo "Next: return to MonkeySSH and tap Test SSH (or wait for auto-detect)."
''';
}

/// Shell-single-quotes [value] for embedding in a POSIX script.
@visibleForTesting
String shellSingleQuote(String value) =>
    "'${value.replaceAll("'", "'\"'\"'")}'";

extension on AndroidLinuxTerminalSetupState {
  AndroidLinuxTerminalSetupState copyWith({
    AndroidLinuxTerminalSetupPhase? phase,
    String? message,
    int? hostId,
    int? keyId,
    String? publicKey,
    String? script,
    String? reachableHost,
    int? reachablePort,
  }) => AndroidLinuxTerminalSetupState(
    phase: phase ?? this.phase,
    message: message ?? this.message,
    hostId: hostId ?? this.hostId,
    keyId: keyId ?? this.keyId,
    publicKey: publicKey ?? this.publicKey,
    script: script ?? this.script,
    reachableHost: reachableHost ?? this.reachableHost,
    reachablePort: reachablePort ?? this.reachablePort,
  );
}

/// Provider for [AndroidLinuxTerminalSetupService].
final androidLinuxTerminalSetupServiceProvider =
    Provider<AndroidLinuxTerminalSetupService>((ref) {
      final service = AndroidLinuxTerminalSetupService(
        hostRepository: ref.watch(hostRepositoryProvider),
        keyRepository: ref.watch(keyRepositoryProvider),
        keyService: ref.watch(keyServiceProvider),
        notificationService: ref.watch(localNotificationServiceProvider),
      )..start();
      ref.onDispose(service.dispose);
      return service;
    });
