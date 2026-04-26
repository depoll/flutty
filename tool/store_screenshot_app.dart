// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/home_screen.dart';
import 'package:monkeyssh/presentation/screens/port_forwards_screen.dart';
import 'package:monkeyssh/presentation/screens/snippets_screen.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/screens/upgrade_screen.dart';

const _terminalHostId = 1;
const _terminalConnectionId = 101;
const _targetName = String.fromEnvironment('STORE_SCREENSHOT_TARGET');

class _MockSshClient extends Mock implements SSHClient {}

class _MockShellChannel extends Mock implements SSHSession {}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _ScreenshotTarget {
  const _ScreenshotTarget({required this.platform, required this.pathsByScene});

  final TargetPlatform platform;
  final List<List<String>> pathsByScene;
}

class _ScreenshotScene {
  const _ScreenshotScene({required this.name, required this.builder});

  final String name;
  final Widget Function(_ScreenshotHarness harness) builder;
}

class _ScreenshotHarness {
  _ScreenshotHarness({
    required this.database,
    required this.terminalSession,
    required this.monetizationService,
  });

  final AppDatabase database;
  final SshSession terminalSession;
  final MonetizationService monetizationService;

  // Riverpod does not export its Override type through flutter_riverpod.
  // ignore: always_declare_return_types, strict_top_level_inference, type_annotate_public_apis
  get overrides => [
    databaseProvider.overrideWithValue(database),
    appDisplayNameProvider.overrideWithValue(defaultAppName),
    monetizationServiceProvider.overrideWithValue(monetizationService),
    monetizationStateProvider.overrideWith((ref) => monetizationService.states),
    sharedClipboardProvider.overrideWith((ref) async => false),
    activeSessionsProvider.overrideWith(
      () => _ScreenshotActiveSessionsNotifier(terminalSession),
    ),
  ];
}

class _ScreenshotActiveSessionsNotifier extends ActiveSessionsNotifier {
  _ScreenshotActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? <int>[session.connectionId] : const <int>[];

  @override
  ActiveConnection? getActiveConnection(int connectionId) =>
      connectionId == session.connectionId
      ? ActiveConnection(
          connectionId: session.connectionId,
          hostId: session.hostId,
          state: SshConnectionState.connected,
          createdAt: DateTime(2026),
          config: session.config,
          preview: _terminalPreview,
          windowTitle: 'agent-api:vim',
          iconName: 'tmux',
          workingDirectory: Uri.parse('file://devbox/home/monkey/src/api'),
          shellStatus: TerminalShellStatus.prompt,
        )
      : null;

  @override
  List<ActiveConnection> getActiveConnections() => [
    getActiveConnection(session.connectionId)!,
  ];

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

class _StoreScreenshotApp extends StatefulWidget {
  const _StoreScreenshotApp({required this.harness, required this.target});

  final _ScreenshotHarness harness;
  final _ScreenshotTarget target;

  @override
  State<_StoreScreenshotApp> createState() => _StoreScreenshotAppState();
}

class _StoreScreenshotAppState extends State<_StoreScreenshotApp> {
  var _sceneIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _announceReady();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(widget.harness.database.close());
    super.dispose();
  }

  void _announceReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _timer = Timer(const Duration(milliseconds: 1600), () {
        FocusManager.instance.primaryFocus?.unfocus();
        unawaited(
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide'),
        );
        _timer = Timer(const Duration(milliseconds: 500), () {
          final scene = _scenes[_sceneIndex];
          debugPrint(
            'STORE_SCREENSHOT_READY ${jsonEncode({'scene': scene.name, 'index': _sceneIndex + 1, 'paths': widget.target.pathsByScene[_sceneIndex]})}',
          );
          _timer = Timer(const Duration(seconds: 3), _advanceScene);
        });
      });
    });
  }

  void _advanceScene() {
    if (!mounted) {
      return;
    }
    if (_sceneIndex == _scenes.length - 1) {
      debugPrint('STORE_SCREENSHOT_DONE');
      Timer(const Duration(milliseconds: 500), () => exit(0));
      return;
    }
    setState(() {
      _sceneIndex += 1;
    });
    _announceReady();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scenes[_sceneIndex];
    return ProviderScope(
      overrides: widget.harness.overrides,
      child: MaterialApp(
        title: defaultAppName,
        debugShowCheckedModeBanner: false,
        theme: FluttyTheme.light,
        darkTheme: FluttyTheme.dark,
        themeMode: ThemeMode.dark,
        home: scene.builder(widget.harness),
      ),
    );
  }
}

const _monthlyOffer = MonetizationOffer(
  id: 'monthly',
  productId: MonetizationProductIds.iosMonthlyProd,
  billingPeriod: MonetizationBillingPeriod.monthly,
  planLabel: 'Monthly',
  priceLabel: r'$4.99',
  displayPriceLabel: r'$4.99 / month',
  rawPrice: 4.99,
  currencyCode: 'USD',
  currencySymbol: r'$',
  detailLabel: 'Billed monthly. Cancel anytime.',
);

const _annualOffer = MonetizationOffer(
  id: 'annual',
  productId: MonetizationProductIds.iosAnnualProd,
  billingPeriod: MonetizationBillingPeriod.annual,
  planLabel: 'Annual',
  priceLabel: r'$39.99',
  displayPriceLabel: r'$39.99 / year',
  rawPrice: 39.99,
  currencyCode: 'USD',
  currencySymbol: r'$',
  detailLabel: 'Best value for multi-device workflows.',
);

const _monetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.free(),
  offers: [_monthlyOffer, _annualOffer],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

final _scenes = <_ScreenshotScene>[
  _ScreenshotScene(name: 'hosts', builder: (_) => const HomeScreen()),
  _ScreenshotScene(
    name: 'terminal',
    builder: (_) => const TerminalScreen(
      hostId: _terminalHostId,
      connectionId: _terminalConnectionId,
    ),
  ),
  _ScreenshotScene(name: 'snippets', builder: (_) => const SnippetsScreen()),
  _ScreenshotScene(name: 'ports', builder: (_) => const PortForwardsScreen()),
  _ScreenshotScene(
    name: 'pro',
    builder: (_) =>
        const UpgradeScreen(feature: MonetizationFeature.agentLaunchPresets),
  ),
];

final _targets = <String, _ScreenshotTarget>{
  'ios_phone': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _scenes.length; index += 1)
        [
          'ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_iphone_6_9.png',
        ],
    ],
  ),
  'ios_ipad': _ScreenshotTarget(
    platform: TargetPlatform.iOS,
    pathsByScene: [
      for (var index = 1; index <= _scenes.length; index += 1)
        [
          'ios/fastlane/screenshots/en-US/${index.toString().padLeft(2, '0')}_ipad_13.png',
        ],
    ],
  ),
  'android_phone': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _scenes.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/$index.png',
        ],
    ],
  ),
  'android_7_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _scenes.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/$index.png',
        ],
    ],
  ),
  'android_10_tablet': _ScreenshotTarget(
    platform: TargetPlatform.android,
    pathsByScene: [
      for (var index = 1; index <= _scenes.length; index += 1)
        [
          'android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/$index.png',
          'android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/$index.png',
        ],
    ],
  ),
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const SSHPtyConfig());
  registerFallbackValue(Uint8List(0));
  registerFallbackValue(MonetizationFeature.agentLaunchPresets);

  final target = _targets[_targetName];
  if (target == null) {
    stderr.writeln(
      'Unknown STORE_SCREENSHOT_TARGET "$_targetName". '
      'Expected one of: ${_targets.keys.join(', ')}',
    );
    exit(64);
  }
  debugDefaultTargetPlatformOverride = target.platform;

  final harness = await _createHarness();
  runApp(_StoreScreenshotApp(harness: harness, target: target));
}

Future<_ScreenshotHarness> _createHarness() async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  await _seedDatabase(database);

  final sshClient = _MockSshClient();
  final shellChannel = _MockShellChannel();
  when(
    () => sshClient.shell(pty: any(named: 'pty')),
  ).thenAnswer((_) async => shellChannel);
  when(
    () => shellChannel.stdout,
  ).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(
    () => shellChannel.stderr,
  ).thenAnswer((_) => const Stream<Uint8List>.empty());
  when(() => shellChannel.done).thenAnswer((_) => Completer<void>().future);
  when(() => shellChannel.write(any())).thenReturn(null);
  // ignore: unnecessary_lambdas
  when(() => shellChannel.close()).thenReturn(null);

  final terminalSession = SshSession(
    connectionId: _terminalConnectionId,
    hostId: _terminalHostId,
    client: sshClient,
    config: const SshConnectionConfig(
      hostname: 'devbox.example.com',
      port: 22,
      username: 'monkey',
    ),
  );
  terminalSession.getOrCreateTerminal().write(_terminalTranscript);

  final monetizationService = _MockMonetizationService();
  when(() => monetizationService.currentState).thenReturn(_monetizationState);
  when(
    () => monetizationService.states,
  ).thenAnswer((_) => Stream<MonetizationState>.value(_monetizationState));
  // ignore: unnecessary_lambdas
  when(() => monetizationService.initialize()).thenAnswer((_) async {});
  when(
    () => monetizationService.canUseFeature(any()),
  ).thenAnswer((_) async => false);
  when(() => monetizationService.purchaseOffer(any())).thenAnswer(
    (_) async => const MonetizationActionResult.cancelled(
      'Purchases are disabled for screenshots.',
    ),
  );
  // ignore: unnecessary_lambdas
  when(() => monetizationService.restorePurchases()).thenAnswer(
    (_) async => const MonetizationActionResult.cancelled(
      'Restore is disabled for screenshots.',
    ),
  );

  return _ScreenshotHarness(
    database: database,
    terminalSession: terminalSession,
    monetizationService: monetizationService,
  );
}

Future<void> _seedDatabase(AppDatabase database) async {
  final keyId = await database
      .into(database.sshKeys)
      .insert(
        SshKeysCompanion.insert(
          name: 'Deploy Ed25519',
          keyType: 'ed25519',
          publicKey:
              'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMonkeySSHStoreScreenshot deploy@example',
          privateKey: 'store-screenshot-private-key-placeholder',
          fingerprint: const Value('SHA256:monkeyssh-demo-key'),
        ),
      );
  final groupId = await database
      .into(database.groups)
      .insert(
        GroupsCompanion.insert(
          name: 'Production',
          color: const Value('#00C9FF'),
          icon: const Value('cloud'),
        ),
      );

  await database
      .into(database.hosts)
      .insert(
        HostsCompanion.insert(
          label: 'Agent devbox',
          hostname: 'devbox.example.com',
          username: 'monkey',
          keyId: Value(keyId),
          groupId: Value(groupId),
          isFavorite: const Value(true),
          color: const Value('#00C9FF'),
          tags: const Value('agent,tmux,prod'),
          notes: const Value('Primary remote coding workspace.'),
          lastConnectedAt: Value(DateTime(2026, 4, 24, 21, 30)),
          tmuxSessionName: const Value('agent-api'),
          tmuxWorkingDirectory: const Value('~/src/api'),
          autoConnectCommand: const Value('tmux new-session -A -s agent-api'),
          autoConnectRequiresConfirmation: const Value(true),
          sortOrder: const Value(0),
        ),
      );
  await database
      .into(database.hosts)
      .insert(
        HostsCompanion.insert(
          label: 'Staging jump host',
          hostname: 'jump.staging.example.com',
          username: 'deploy',
          keyId: Value(keyId),
          isFavorite: const Value(true),
          color: const Value('#34C759'),
          tags: const Value('staging,jump'),
          sortOrder: const Value(1),
        ),
      );
  await database
      .into(database.hosts)
      .insert(
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
          name: 'Vite preview',
          hostId: _terminalHostId,
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
          name: 'Resume agent',
          command: 'copilot resume --recent',
          description: const Value(
            'Jump back into the latest coding-agent session.',
          ),
          autoExecute: const Value(false),
          usageCount: const Value(18),
          sortOrder: const Value(0),
        ),
      );
  await database
      .into(database.snippets)
      .insert(
        SnippetsCompanion.insert(
          name: 'Tail API logs',
          command: 'docker compose logs -f api',
          description: const Value(
            'Watch the API container while testing changes.',
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
          command: 'tmux new-session -A -s agent-api -c ~/src/api',
          description: const Value(
            'Attach to the persistent remote workspace.',
          ),
          autoExecute: const Value(true),
          usageCount: const Value(9),
          sortOrder: const Value(2),
        ),
      );

  final settings = SettingsService(database);
  await settings.setString(SettingKeys.themeMode, 'dark');
  await settings.setInt(SettingKeys.terminalFontSize, 14);
  await settings.setBool(SettingKeys.terminalPathLinks, value: false);
}

const _terminalPreview = r'''
monkey@devbox ~/src/api
$ copilot resume --recent
Found recent coding sessions for ~/src/api
Resuming "polish initial release metadata"...''';

const _terminalTranscript = r'''
Last login: Fri Apr 24 21:30:18 on pts/4
monkey@devbox:~/src/api$ tmux attach -t agent-api

[agent-api] 0:server* 1:tests 2:logs 3:copilot
monkey@devbox ~/src/api
$ copilot resume --recent
Found recent coding sessions for ~/src/api

  1. fix ssh reconnect flow
  2. review paste safety guard
  3. polish initial release metadata

Resuming "polish initial release metadata"...
Copilot> Store assets are staged. Running validation now.
$ flutter test test/domain/services/tmux_service_test.dart
00:03 +42: All tests passed!
$ git status --short
 M ios/fastlane/metadata-production/en-US/description.txt
 M android/fastlane/metadata-production/android/en-US/full_description.txt
''';
