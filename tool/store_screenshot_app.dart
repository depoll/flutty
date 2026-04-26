// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

const _targetName = String.fromEnvironment('STORE_SCREENSHOT_TARGET');
const _sshPort = int.fromEnvironment('STORE_SCREENSHOT_SSH_PORT');
const _sshUsername = String.fromEnvironment('STORE_SCREENSHOT_SSH_USERNAME');
const _sshPrivateKeyB64 = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64',
);
const _sshHostKeyB64 = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_HOST_KEY_B64',
);
const _sshHostKeyFingerprint = String.fromEnvironment(
  'STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT',
);
const _tmuxSessionName = String.fromEnvironment(
  'STORE_SCREENSHOT_TMUX_SESSION',
);
const _fallbackOffer = MonetizationOffer(
  id: 'fallback',
  productId: 'store-screenshot-fallback',
  billingPeriod: MonetizationBillingPeriod.monthly,
  planLabel: 'Monthly',
  priceLabel: r'$0.00',
  displayPriceLabel: r'$0.00 / month',
  rawPrice: 0,
  currencyCode: 'USD',
  currencySymbol: r'$',
);

class _MockMonetizationService extends Mock implements MonetizationService {}

class _NoOpLocalNotificationService extends LocalNotificationService {
  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> showTmuxAlert({
    required int notificationId,
    required String title,
    required String body,
    required TmuxAlertNotificationPayload payload,
  }) async {}

  @override
  Future<void> clearTmuxAlert(int notificationId) async {}
}

class _ScreenshotTarget {
  const _ScreenshotTarget({required this.platform, required this.pathsByScene});

  final TargetPlatform platform;
  final List<List<String>> pathsByScene;
}

const _sceneNames = <String>[
  'terminal_copilot',
  'hosts',
  'snippets',
  'tmux_windows',
  'sftp',
  'terminal_claude',
];

final _targets = <String, _ScreenshotTarget>{
  'ios_phone': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_iphone_6_9.png',
        ],
    ],
  ),
  'ios_ipad': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_ipad_13.png',
        ],
    ],
  ),
  'android_phone': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/$index.png',
        ],
    ],
  ),
  'android_7_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/$index.png',
        ],
    ],
  ),
  'android_10_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _sceneNames.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/$index.png',
        ],
    ],
  ),
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final target = _targets[_targetName];
  if (target == null) {
    stderr.writeln(
      'Unknown STORE_SCREENSHOT_TARGET "$_targetName". '
      'Expected one of: ${_targets.keys.join(', ')}',
    );
    exit(64);
  }
  if (_sshPort <= 0 ||
      _sshUsername.isEmpty ||
      _sshPrivateKeyB64.isEmpty ||
      _sshHostKeyB64.isEmpty ||
      _sshHostKeyFingerprint.isEmpty) {
    stderr.writeln(
      'STORE_SCREENSHOT_SSH_PORT, STORE_SCREENSHOT_SSH_USERNAME, '
      'STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64, STORE_SCREENSHOT_SSH_HOST_KEY_B64, '
      'and STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT are required.',
    );
    exit(64);
  }
  if (_tmuxSessionName.isEmpty) {
    stderr.writeln('STORE_SCREENSHOT_TMUX_SESSION is required.');
    exit(64);
  }
  registerFallbackValue(MonetizationFeature.agentLaunchPresets);
  registerFallbackValue(_fallbackOffer);

  debugDefaultTargetPlatformOverride = target.platform;

  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final secrets = SecretEncryptionService.forTesting();
  final terminalHostId = await _seedDatabase(database, secrets, target);
  final monetizationService = _createMonetizationService();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        secretEncryptionServiceProvider.overrideWithValue(secrets),
        appDisplayNameProvider.overrideWithValue(defaultAppName),
        hostKeyPromptHandlerProvider.overrideWith(
          (_) =>
              (_) async => HostKeyTrustDecision.trust,
        ),
        monetizationServiceProvider.overrideWithValue(monetizationService),
        monetizationStateProvider.overrideWith(
          (ref) => monetizationService.states,
        ),
        localNotificationServiceProvider.overrideWithValue(
          _NoOpLocalNotificationService(),
        ),
        sharedClipboardProvider.overrideWith((ref) async => false),
      ],
      child: _StoreScreenshotFlow(
        target: target,
        terminalHostId: terminalHostId,
      ),
    ),
  );
}

MonetizationService _createMonetizationService() {
  const state = MonetizationState(
    billingAvailability: MonetizationBillingAvailability.unavailable,
    entitlements: MonetizationEntitlements.free(),
    offers: [],
    debugUnlockAvailable: false,
    debugUnlocked: false,
  );
  final service = _MockMonetizationService();
  when(() => service.currentState).thenReturn(state);
  when(() => service.states).thenAnswer((_) => Stream.value(state));
  // ignore: unnecessary_lambdas
  when(() => service.initialize()).thenAnswer((_) => Future<void>.value());
  when(() => service.canUseFeature(any())).thenAnswer((_) async => false);
  when(() => service.purchaseOffer(any())).thenAnswer(
    (_) async => const MonetizationActionResult.cancelled(
      'Purchases are disabled for screenshots.',
    ),
  );
  // ignore: unnecessary_lambdas
  when(() => service.restorePurchases()).thenAnswer(
    (_) => Future.value(
      const MonetizationActionResult.cancelled(
        'Restore is disabled for screenshots.',
      ),
    ),
  );
  // ignore: unnecessary_lambdas
  when(() => service.dispose()).thenAnswer((_) => Future<void>.value());
  return service;
}

Future<int> _seedDatabase(
  AppDatabase database,
  SecretEncryptionService secrets,
  _ScreenshotTarget target,
) async {
  final keyRepository = KeyRepository(database, secrets);
  final hostRepository = HostRepository(database, secrets);
  final privateKey = utf8.decode(base64Decode(_sshPrivateKeyB64));
  final publicKey = _placeholderPublicKeyFromPrivateKey(privateKey);
  final hostname = target.platform == TargetPlatform.android
      ? '10.0.2.2'
      : '127.0.0.1';

  await database
      .into(database.knownHosts)
      .insert(
        KnownHostsCompanion.insert(
          hostname: hostname,
          port: _sshPort,
          keyType: 'ssh-ed25519',
          fingerprint: _sshHostKeyFingerprint,
          hostKey: _sshHostKeyB64,
        ),
      );

  final keyId = await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Release workspace key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:release-workspace-key'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Production deploy key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:production-deploy'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Build runner key',
      keyType: 'rsa',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:build-runner'),
    ),
  );
  await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Emergency access key',
      keyType: 'ecdsa',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:emergency-access'),
    ),
  );

  final groupId = await database
      .into(database.groups)
      .insert(
        GroupsCompanion.insert(
          name: 'Agent Workspaces',
          color: const Value('#00C9FF'),
          icon: const Value('terminal'),
        ),
      );

  final terminalHostId = await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Agent tmux',
      hostname: hostname,
      port: const Value(_sshPort),
      username: _sshUsername,
      keyId: Value(keyId),
      groupId: Value(groupId),
      isFavorite: const Value(true),
      color: const Value('#00C9FF'),
      tags: const Value('agent,tmux,release'),
      notes: const Value('Local release-demo workspace for store captures.'),
      terminalThemeDarkId: const Value('velvet'),
      terminalFontFamily: const Value('monospace'),
      tmuxSessionName: const Value(_tmuxSessionName),
      tmuxWorkingDirectory: const Value(
        '/Users/Shared/monkeyssh-release-workspace',
      ),
      sortOrder: const Value(0),
    ),
  );

  await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Production bastion',
      hostname: 'bastion.internal',
      username: 'ops',
      keyId: Value(keyId),
      isFavorite: const Value(true),
      color: const Value('#34C759'),
      tags: const Value('prod,jump'),
      sortOrder: const Value(1),
    ),
  );

  await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Build runner',
      hostname: 'runner.internal',
      username: 'ci',
      keyId: Value(keyId),
      color: const Value('#FF9500'),
      tags: const Value('ci,logs'),
      sortOrder: const Value(2),
    ),
  );

  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Preview server',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 5173,
          remoteHost: '127.0.0.1',
          remotePort: 5173,
          autoStart: const Value(true),
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'API dashboard',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 8080,
          remoteHost: '127.0.0.1',
          remotePort: 8080,
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Database tunnel',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 5432,
          remoteHost: '127.0.0.1',
          remotePort: 5432,
          autoStart: const Value(true),
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'Metrics dashboard',
          hostId: terminalHostId,
          forwardType: 'local',
          localPort: 9090,
          remoteHost: '127.0.0.1',
          remotePort: 9090,
        ),
      );

  final snippets = [
    (
      name: 'Resume Copilot safely',
      command: 'copilot --no-remote --log-level none',
      description: 'Resume a Copilot session with identity details redacted.',
      autoExecute: false,
      usageCount: 18,
    ),
    (
      name: 'Open Claude Code safely',
      command: 'claude --bare --name Claude Code Workspace',
      description: 'Start Claude Code with a privacy-safe API key setup.',
      autoExecute: false,
      usageCount: 12,
    ),
    (
      name: 'Attach tmux workspace',
      command: 'tmux new-session -A -s $_tmuxSessionName',
      description: 'Attach to the persistent remote agent workspace.',
      autoExecute: true,
      usageCount: 9,
    ),
    (
      name: 'List agent windows',
      command: 'tmux list-windows -t $_tmuxSessionName',
      description: 'Check active Copilot, Gemini, Claude, and Codex panes.',
      autoExecute: false,
      usageCount: 7,
    ),
    (
      name: 'Follow deploy logs',
      command: 'tail -f logs/deploy.log',
      description: 'Stream release logs after reconnecting.',
      autoExecute: false,
      usageCount: 5,
    ),
    (
      name: 'Open preview tunnel',
      command: 'ssh -L 5173:127.0.0.1:5173 preview',
      description: 'Forward the preview server through SSH.',
      autoExecute: false,
      usageCount: 4,
    ),
  ];
  for (final (index, snippet) in snippets.indexed) {
    await database
        .into(database.snippets)
        .insert(
          SnippetsCompanion.insert(
            name: snippet.name,
            command: snippet.command,
            description: Value(snippet.description),
            autoExecute: Value(snippet.autoExecute),
            usageCount: Value(snippet.usageCount),
            sortOrder: Value(index),
          ),
        );
  }

  final settings = SettingsService(database);
  await settings.setString(SettingKeys.themeMode, 'dark');
  await settings.setInt(SettingKeys.terminalFontSize, 13);
  await settings.setString(SettingKeys.defaultTerminalThemeDark, 'velvet');
  await settings.setBool(SettingKeys.terminalPathLinks, value: false);
  return terminalHostId;
}

String _placeholderPublicKeyFromPrivateKey(String privateKey) {
  final firstLine = privateKey
      .split('\n')
      .firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => 'release-workspace-key',
      );
  return 'ssh-ed25519 ${base64Encode(utf8.encode(firstLine))} release-workspace-key';
}

class _StoreScreenshotFlow extends ConsumerStatefulWidget {
  const _StoreScreenshotFlow({
    required this.target,
    required this.terminalHostId,
  });

  final _ScreenshotTarget target;
  final int terminalHostId;

  @override
  ConsumerState<_StoreScreenshotFlow> createState() =>
      _StoreScreenshotFlowState();
}

class _StoreScreenshotFlowState extends ConsumerState<_StoreScreenshotFlow> {
  Future<void>? _flow;
  int? _connectionId;

  @override
  void initState() {
    super.initState();
    _flow = _runFlow();
  }

  @override
  void dispose() {
    unawaited(_flow?.catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const FluttyApp();

  Future<void> _runFlow() async {
    try {
      await _waitForApp();
      final terminalHostId = widget.terminalHostId;
      final result = await ref
          .read(activeSessionsProvider.notifier)
          .connect(terminalHostId);
      if (!result.success || result.connectionId == null) {
        throw StateError(result.error ?? 'SSH connection did not open.');
      }
      _connectionId = result.connectionId;

      _go('/terminal/$terminalHostId?connectionId=$_connectionId');
      await Future<void>.delayed(const Duration(seconds: 6));
      await _announceScene(0);

      _go('/');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(1);

      _go('/snippets');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(2);

      _go(
        '/terminal/$terminalHostId?connectionId=$_connectionId'
        '&expandTmux=1',
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      await _announceScene(3);

      _go(
        '/sftp/$terminalHostId?connectionId=$_connectionId'
        '&path=%2FUsers%2FShared%2Fmonkeyssh-release-workspace',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(4);

      final session = ref
          .read(activeSessionsProvider.notifier)
          .getSession(_connectionId!);
      if (session == null) {
        throw StateError('SSH session not available for Claude screenshot.');
      }
      await ref
          .read(tmuxServiceProvider)
          .selectWindow(session, _tmuxSessionName, 2);
      _go('/terminal/$terminalHostId?connectionId=$_connectionId');
      await Future<void>.delayed(const Duration(seconds: 4));
      await _announceScene(5);

      debugPrint('STORE_SCREENSHOT_DONE');
      await ref.read(databaseProvider).close();
      exit(0);
    } on Object catch (error, stackTrace) {
      debugPrint('STORE_SCREENSHOT_ERROR $error');
      debugPrint('$stackTrace');
      await ref.read(databaseProvider).close();
      exit(1);
    }
  }

  Future<void> _waitForApp() async {
    while (appNavigatorKey.currentContext == null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  Future<void> _announceScene(int index) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final payload = {
      'scene': _sceneNames[index],
      'index': index + 1,
      'paths': widget.target.pathsByScene[index],
    };
    debugPrint('STORE_SCREENSHOT_READY ${jsonEncode(payload)}');
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  void _go(String location) {
    final context = appNavigatorKey.currentContext;
    if (context == null) {
      throw StateError('Navigator context is unavailable.');
    }
    GoRouter.of(context).go(location);
  }
}
