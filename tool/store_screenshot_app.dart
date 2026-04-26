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

const _terminalHostId = 1;
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
  'hosts',
  'terminal_claude',
  'terminal_copilot',
  'terminal_agents',
  'hosts_connected',
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
  await _seedDatabase(database, secrets, target);
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
      child: _StoreScreenshotFlow(target: target),
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

Future<void> _seedDatabase(
  AppDatabase database,
  SecretEncryptionService secrets,
  _ScreenshotTarget target,
) async {
  final keyRepository = KeyRepository(database, secrets);
  final hostRepository = HostRepository(database, secrets);
  final privateKey = utf8.decode(base64Decode(_sshPrivateKeyB64));
  final publicKey = _derivePublicKeyCommentFree(privateKey);
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
      name: 'Store demo key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      fingerprint: const Value('SHA256:store-demo-key'),
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

  await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Claude + Copilot tmux',
      hostname: hostname,
      port: const Value(_sshPort),
      username: _sshUsername,
      keyId: Value(keyId),
      groupId: Value(groupId),
      isFavorite: const Value(true),
      color: const Value('#00C9FF'),
      tags: const Value('agent,tmux,store-demo'),
      notes: const Value('Local release-demo workspace for store captures.'),
      terminalThemeDarkId: const Value('velvet'),
      terminalFontFamily: const Value('monospace'),
      tmuxSessionName: const Value(_tmuxSessionName),
      tmuxWorkingDirectory: const Value('/Users/Shared/monkeyssh-store-demo'),
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
          hostId: _terminalHostId,
          forwardType: 'local',
          localPort: 5173,
          remoteHost: '127.0.0.1',
          remotePort: 5173,
          autoStart: const Value(false),
        ),
      );
  await database
      .into(database.portForwards)
      .insert(
        PortForwardsCompanion.insert(
          name: 'API dashboard',
          hostId: _terminalHostId,
          forwardType: 'local',
          localPort: 8080,
          remoteHost: '127.0.0.1',
          remotePort: 8080,
        ),
      );

  await database
      .into(database.snippets)
      .insert(
        SnippetsCompanion.insert(
          name: 'Resume Copilot safely',
          command:
              'copilot --no-remote --log-level none --secret-env-vars=USER,EMAIL,GITHUB_TOKEN,GH_TOKEN',
          description: const Value(
            'Resume a Copilot session with identity details redacted.',
          ),
          usageCount: const Value(18),
          sortOrder: const Value(0),
        ),
      );
  await database
      .into(database.snippets)
      .insert(
        SnippetsCompanion.insert(
          name: 'Open Claude Code safely',
          command: 'claude --bare --permission-mode plan',
          description: const Value(
            'Resume Claude Code without loading user or project identity state.',
          ),
          usageCount: const Value(12),
          sortOrder: const Value(1),
        ),
      );
  await database
      .into(database.snippets)
      .insert(
        SnippetsCompanion.insert(
          name: 'Open tmux workspace',
          command: 'tmux new-session -A -s $_tmuxSessionName',
          description: const Value(
            'Attach to the persistent remote agent workspace.',
          ),
          autoExecute: const Value(true),
          usageCount: const Value(9),
          sortOrder: const Value(2),
        ),
      );

  final settings = SettingsService(database);
  await settings.setString(SettingKeys.themeMode, 'dark');
  await settings.setInt(SettingKeys.terminalFontSize, 14);
  await settings.setString(SettingKeys.defaultTerminalThemeDark, 'velvet');
  await settings.setBool(SettingKeys.terminalPathLinks, value: false);
}

String _derivePublicKeyCommentFree(String privateKey) {
  final firstLine = privateKey
      .split('\n')
      .firstWhere(
        (line) => line.trim().isNotEmpty,
        orElse: () => 'store-demo-key',
      );
  return 'ssh-ed25519 ${base64Encode(utf8.encode(firstLine))} store-demo-key';
}

class _StoreScreenshotFlow extends ConsumerStatefulWidget {
  const _StoreScreenshotFlow({required this.target});

  final _ScreenshotTarget target;

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
      await _announceScene(0);

      final result = await ref
          .read(activeSessionsProvider.notifier)
          .connect(_terminalHostId);
      if (!result.success || result.connectionId == null) {
        throw StateError(result.error ?? 'SSH connection did not open.');
      }
      _connectionId = result.connectionId;

      _go('/terminal/$_terminalHostId?connectionId=$_connectionId');
      await Future<void>.delayed(const Duration(seconds: 6));
      await _announceScene(1);

      await _sendTmuxWindowKey('1');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(2);

      await _sendTmuxWindowKey('2');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(3);

      _go('/');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _announceScene(4);

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

  Future<void> _sendTmuxWindowKey(String key) async {
    final connectionId = _connectionId;
    if (connectionId == null) {
      throw StateError('SSH connection is unavailable.');
    }
    final session = ref
        .read(activeSessionsProvider.notifier)
        .getSession(connectionId);
    if (session == null) {
      throw StateError('SSH session is unavailable.');
    }
    final shell = await session.getShell();
    shell.write(utf8.encode('\x02$key'));
  }
}
