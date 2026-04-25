// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/port_forward_repository.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/presentation/screens/host_edit_screen.dart';

Host _testHost({
  required int id,
  required String label,
  required bool autoConnectRequiresConfirmation,
  String? autoConnectCommand,
  int? autoConnectSnippetId,
  String? tmuxSessionName,
  String? tmuxWorkingDirectory,
  String? tmuxExtraFlags,
}) => Host(
  id: id,
  label: label,
  hostname: 'imported.example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  autoConnectCommand: autoConnectCommand,
  autoConnectSnippetId: autoConnectSnippetId,
  autoConnectRequiresConfirmation: autoConnectRequiresConfirmation,
  tmuxSessionName: tmuxSessionName,
  tmuxWorkingDirectory: tmuxWorkingDirectory,
  tmuxExtraFlags: tmuxExtraFlags,
  sortOrder: 0,
);

Snippet _testSnippet({
  required int id,
  required String name,
  required String command,
}) => Snippet(
  id: id,
  name: name,
  command: command,
  autoExecute: false,
  createdAt: DateTime(2024),
  usageCount: 0,
  sortOrder: 0,
);

class _FakeHostRepository extends HostRepository {
  _FakeHostRepository({
    required Host host,
    required AppDatabase database,
    required SecretEncryptionService encryptionService,
  }) : _host = host,
       super(database, encryptionService);

  Host _host;
  Host? updatedHost;
  HostsCompanion? insertedHost;

  @override
  Future<Host?> getById(int id) async => id == _host.id ? _host : null;

  @override
  Stream<List<Host>> watchAll() => Stream.value([_host]);

  @override
  Future<bool> update(Host host) async {
    _host = host;
    updatedHost = host;
    return true;
  }

  @override
  Future<int> insert(HostsCompanion host) async {
    insertedHost = host;
    return 2;
  }
}

class _FakeKeyRepository extends KeyRepository {
  _FakeKeyRepository({
    required AppDatabase database,
    required SecretEncryptionService encryptionService,
  }) : super(database, encryptionService);

  @override
  Stream<List<SshKey>> watchAll() => const Stream<List<SshKey>>.empty();
}

class _FakeSnippetRepository extends SnippetRepository {
  _FakeSnippetRepository({
    required List<Snippet> snippets,
    required AppDatabase database,
  }) : _snippets = snippets,
       super(database);

  final List<Snippet> _snippets;

  @override
  Future<Snippet?> getById(int id) async {
    for (final snippet in _snippets) {
      if (snippet.id == id) {
        return snippet;
      }
    }
    return null;
  }

  @override
  Stream<List<Snippet>> watchAll() => Stream.value(_snippets);
}

class _FakePortForwardRepository extends PortForwardRepository {
  _FakePortForwardRepository({required AppDatabase database}) : super(database);

  @override
  Future<List<PortForward>> getByHostId(int hostId) async => const [];
}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _MockAgentLaunchPresetService extends Mock
    implements AgentLaunchPresetService {}

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

MonetizationService _buildProMonetizationService() {
  final service = _MockMonetizationService();
  when(() => service.currentState).thenReturn(_proMonetizationState);
  when(
    () => service.states,
  ).thenAnswer((_) => Stream.value(_proMonetizationState));
  when(
    () => service.canUseFeature(MonetizationFeature.autoConnectAutomation),
  ).thenAnswer((_) async => true);
  when(
    () => service.canUseFeature(MonetizationFeature.agentLaunchPresets),
  ).thenAnswer((_) async => true);
  // ignore: unnecessary_lambdas
  when(() => service.initialize()).thenAnswer((_) => Future<void>.value());
  return service;
}

class _HostEditTestHarness {
  const _HostEditTestHarness({required this.hostRepository});

  final _FakeHostRepository hostRepository;
}

Future<_HostEditTestHarness> _pumpHostCreateScreen(
  WidgetTester tester, {
  bool hasPro = false,
  List<Snippet> snippets = const [],
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final encryptionService = SecretEncryptionService.forTesting();
  addTearDown(database.close);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.binding.setSurfaceSize(const Size(420, 900));

  final hostRepository = _FakeHostRepository(
    host: _testHost(
      id: 1,
      label: 'Unused Host',
      autoConnectRequiresConfirmation: false,
    ),
    database: database,
    encryptionService: encryptionService,
  );
  final presetService = _MockAgentLaunchPresetService();
  when(
    () => presetService.getPresetForHost(any()),
  ).thenAnswer((_) async => null);
  when(
    () => presetService.setPresetForHost(any(), any()),
  ).thenAnswer((_) async {});
  when(() => presetService.deletePresetForHost(any())).thenAnswer((_) async {});

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/add',
        builder: (context, state) => const HostEditScreen(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (hasPro) ...[
          monetizationServiceProvider.overrideWithValue(
            _buildProMonetizationService(),
          ),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proMonetizationState),
          ),
        ],
        databaseProvider.overrideWithValue(database),
        hostRepositoryProvider.overrideWithValue(hostRepository),
        agentLaunchPresetServiceProvider.overrideWithValue(presetService),
        keyRepositoryProvider.overrideWithValue(
          _FakeKeyRepository(
            database: database,
            encryptionService: encryptionService,
          ),
        ),
        snippetRepositoryProvider.overrideWithValue(
          _FakeSnippetRepository(snippets: snippets, database: database),
        ),
        portForwardRepositoryProvider.overrideWithValue(
          _FakePortForwardRepository(database: database),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );

  unawaited(router.push('/add'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  return _HostEditTestHarness(hostRepository: hostRepository);
}

Future<void> _fillRequiredHostFields(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('host-label-field')), 'New Host');
  await tester.enterText(
    find.byKey(const Key('host-hostname-field')),
    'new.example.com',
  );
  await tester.enterText(find.byKey(const Key('host-username-field')), 'root');
}

Future<void> _selectStartupMode(WidgetTester tester, String label) async {
  final formScroll = find.byType(Scrollable).first;
  final startupModeField = find.byKey(const Key('host-startup-mode-field'));
  await tester.scrollUntilVisible(
    startupModeField,
    200,
    scrollable: formScroll,
  );
  await tester.ensureVisible(startupModeField);
  await tester.tap(find.text('Do nothing'), warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapBottomSave(WidgetTester tester) async {
  final saveButton = find.byKey(
    const Key('host-save-button'),
    skipOffstage: false,
  );
  await tester.scrollUntilVisible(
    saveButton,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(saveButton);
  tester.widget<FilledButton>(saveButton).onPressed!();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

bool _textFieldHasFocus(WidgetTester tester, Key fieldKey) {
  final editableText = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(fieldKey),
      matching: find.byType(EditableText),
    ),
  );
  return editableText.focusNode.hasFocus;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AgentLaunchPreset(tool: AgentLaunchTool.codex));
  });

  group('HostEditScreen', () {
    testWidgets(
      'scrolls to the first base field and summarizes validation errors',
      (tester) async {
        final harness = await _pumpHostCreateScreen(tester);

        await _tapBottomSave(tester);

        expect(find.text('Fix label to save this host'), findsOneWidget);
        expect(find.text('Please enter a label'), findsOneWidget);
        expect(
          _textFieldHasFocus(tester, const Key('host-label-field')),
          isTrue,
        );
        expect(harness.hostRepository.insertedHost, isNull);
      },
    );

    testWidgets('scrolls to missing tmux session when saving tmux startup', (
      tester,
    ) async {
      final harness = await _pumpHostCreateScreen(tester);
      await _fillRequiredHostFields(tester);
      await _selectStartupMode(tester, 'Open tmux session');

      await _tapBottomSave(tester);

      expect(
        find.text('Fix tmux session name to save this host'),
        findsOneWidget,
      );
      expect(find.text('Enter a tmux session name'), findsOneWidget);
      expect(
        _textFieldHasFocus(tester, const Key('host-tmux-session-field')),
        isTrue,
      );
      expect(harness.hostRepository.insertedHost, isNull);
    });

    testWidgets(
      'scrolls to missing custom command when saving custom startup',
      (tester) async {
        final harness = await _pumpHostCreateScreen(tester, hasPro: true);
        await _fillRequiredHostFields(tester);
        await _selectStartupMode(tester, 'Run custom command');

        await _tapBottomSave(tester);

        expect(
          find.text('Fix custom command to save this host'),
          findsOneWidget,
        );
        expect(
          find.text('Enter a command or choose "Do nothing"'),
          findsOneWidget,
        );
        expect(
          _textFieldHasFocus(
            tester,
            const Key('host-auto-connect-command-field'),
          ),
          isTrue,
        );
        expect(harness.hostRepository.insertedHost, isNull);
      },
    );

    testWidgets('scrolls to missing snippet when saving snippet startup', (
      tester,
    ) async {
      final harness = await _pumpHostCreateScreen(
        tester,
        hasPro: true,
        snippets: [
          _testSnippet(id: 7, name: 'Bootstrap', command: 'bootstrap.sh'),
        ],
      );
      await _fillRequiredHostFields(tester);
      await _selectStartupMode(tester, 'Run saved snippet');

      await _tapBottomSave(tester);

      expect(
        find.text('Choose a startup snippet to save this host'),
        findsOneWidget,
      );
      expect(
        find.text('Choose a snippet or select "Do nothing"'),
        findsOneWidget,
      );
      expect(harness.hostRepository.insertedHost, isNull);
    });

    testWidgets(
      'preserves imported auto-connect review when saving unrelated edits',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(420, 900));

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectCommand: 'tmux attach',
            autoConnectSnippetId: 7,
            autoConnectRequiresConfirmation: true,
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final snippetRepository = _FakeSnippetRepository(
          snippets: [
            _testSnippet(id: 7, name: 'Attach tmux', command: 'tmux attach'),
          ],
          database: database,
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(
                  const MonetizationState(
                    billingAvailability:
                        MonetizationBillingAvailability.available,
                    entitlements: MonetizationEntitlements.pro(),
                    offers: [],
                    debugUnlockAvailable: false,
                    debugUnlocked: false,
                  ),
                ),
              ),
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(snippetRepository),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.enterText(
          find.byKey(const Key('host-label-field')),
          'Reviewed Host',
        );

        final formScroll = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('host-save-button')),
          200,
          scrollable: formScroll,
        );
        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.ensureVisible(saveButton);
        tester.widget<FilledButton>(saveButton).onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(hostRepository.updatedHost!.label, 'Reviewed Host');
        expect(hostRepository.updatedHost!.autoConnectCommand, 'tmux attach');
        expect(hostRepository.updatedHost!.autoConnectSnippetId, 7);
        expect(
          hostRepository.updatedHost!.autoConnectRequiresConfirmation,
          isTrue,
        );
      },
    );

    testWidgets('saves tmux startup without a custom command', (tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      addTearDown(database.close);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(420, 900));

      final hostRepository = _FakeHostRepository(
        host: _testHost(
          id: 1,
          label: 'Imported Host',
          autoConnectRequiresConfirmation: false,
          tmuxSessionName: 'old-workspace',
        ),
        database: database,
        encryptionService: encryptionService,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
          GoRoute(
            path: '/edit',
            builder: (context, state) => const HostEditScreen(hostId: 1),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            keyRepositoryProvider.overrideWithValue(
              _FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              _FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              _FakePortForwardRepository(database: database),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      unawaited(router.push('/edit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byKey(const Key('host-tmux-session-field')),
        'workspace',
      );
      await tester.enterText(
        find.byKey(const Key('host-tmux-working-directory-field')),
        '~/src/app',
      );
      await tester.enterText(
        find.byKey(const Key('host-tmux-extra-flags-field')),
        '-f ~/.tmux.conf',
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('host-save-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final saveButton = find.byKey(
        const Key('host-save-button'),
        skipOffstage: false,
      );
      await tester.ensureVisible(saveButton);
      tester.widget<FilledButton>(saveButton).onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(hostRepository.updatedHost, isNotNull);
      expect(hostRepository.updatedHost!.autoConnectCommand, isNull);
      expect(hostRepository.updatedHost!.autoConnectSnippetId, isNull);
      expect(
        hostRepository.updatedHost!.autoConnectRequiresConfirmation,
        isFalse,
      );
      expect(hostRepository.updatedHost!.tmuxSessionName, 'workspace');
      expect(hostRepository.updatedHost!.tmuxWorkingDirectory, '~/src/app');
      expect(hostRepository.updatedHost!.tmuxExtraFlags, '-f ~/.tmux.conf');
    });

    testWidgets(
      'adds the tmux status bar command when the checkbox is enabled',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(420, 900));

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectRequiresConfirmation: false,
            tmuxSessionName: 'old-workspace',
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(
                _FakeSnippetRepository(snippets: const [], database: database),
              ),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.enterText(
          find.byKey(const Key('host-tmux-session-field')),
          'workspace',
        );
        await tester.enterText(
          find.byKey(const Key('host-tmux-extra-flags-field')),
          '-f ~/.tmux.conf',
        );
        final statusBarCheckbox = tester.widget<CheckboxListTile>(
          find.byKey(const Key('host-tmux-disable-status-bar-checkbox')),
        );
        statusBarCheckbox.onChanged!(true);
        await tester.pump();

        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.scrollUntilVisible(
          saveButton,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(saveButton);
        tester.widget<FilledButton>(saveButton).onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(
          hostRepository.updatedHost!.tmuxExtraFlags,
          r'-f ~/.tmux.conf \; set status off',
        );
      },
    );

    testWidgets('loads an existing tmux status bar command into the checkbox', (
      tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      addTearDown(database.close);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(420, 900));

      final hostRepository = _FakeHostRepository(
        host: _testHost(
          id: 1,
          label: 'Imported Host',
          autoConnectRequiresConfirmation: false,
          tmuxSessionName: 'workspace',
          tmuxExtraFlags: r'-f ~/.tmux.conf \; set status off',
        ),
        database: database,
        encryptionService: encryptionService,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
          GoRoute(
            path: '/edit',
            builder: (context, state) => const HostEditScreen(hostId: 1),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            keyRepositoryProvider.overrideWithValue(
              _FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              _FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              _FakePortForwardRepository(database: database),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      unawaited(router.push('/edit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final extraFlagsField = tester.widget<TextFormField>(
        find.byKey(const Key('host-tmux-extra-flags-field')),
      );
      final statusBarCheckbox = tester.widget<CheckboxListTile>(
        find.byKey(const Key('host-tmux-disable-status-bar-checkbox')),
      );

      expect(extraFlagsField.controller!.text, '-f ~/.tmux.conf');
      expect(statusBarCheckbox.value, isTrue);

      await tester.scrollUntilVisible(
        find.byKey(const Key('host-save-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final saveButton = find.byKey(
        const Key('host-save-button'),
        skipOffstage: false,
      );
      await tester.ensureVisible(saveButton);
      tester.widget<FilledButton>(saveButton).onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(hostRepository.updatedHost, isNotNull);
      expect(
        hostRepository.updatedHost!.tmuxExtraFlags,
        r'-f ~/.tmux.conf \; set status off',
      );
    });

    testWidgets(
      'shows and saves the tmux status bar checkbox for agent startup',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(420, 900));

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Agent Host',
            autoConnectRequiresConfirmation: false,
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final presetService = _MockAgentLaunchPresetService();
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: 'agent-session',
          tmuxExtraFlags: '-x 160 -y 48',
        );
        when(
          () => presetService.getPresetForHost(1),
        ).thenAnswer((_) async => preset);
        when(
          () => presetService.setPresetForHost(1, any()),
        ).thenAnswer((_) async {});
        when(
          () => presetService.deletePresetForHost(1),
        ).thenAnswer((_) async {});

        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              agentLaunchPresetServiceProvider.overrideWithValue(presetService),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(
                _FakeSnippetRepository(snippets: const [], database: database),
              ),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const Key('host-agent-tool-field')), findsOneWidget);
        expect(find.byKey(const Key('host-tmux-session-field')), findsNothing);
        expect(
          find.byKey(const Key('host-agent-tmux-extra-flags-field')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('host-agent-tmux-extra-flags-field')),
              )
              .controller!
              .text,
          '-x 160 -y 48',
        );

        await tester.enterText(
          find.byKey(const Key('host-agent-tmux-extra-flags-field')),
          '-x 200 -y 60',
        );
        await tester.pump();
        expect(
          find.textContaining(
            "tmux new-session -A -s 'agent-session' -x 200 -y 60",
            findRichText: true,
          ),
          findsOneWidget,
        );
        final checkboxFinder = find.byKey(
          const Key('host-agent-disable-status-bar-checkbox'),
        );
        expect(checkboxFinder, findsOneWidget);
        final checkbox = tester.widget<CheckboxListTile>(checkboxFinder);
        expect(checkbox.value, isFalse);

        checkbox.onChanged!(true);
        await tester.pump();

        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.scrollUntilVisible(
          saveButton,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(saveButton);
        tester.widget<FilledButton>(saveButton).onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(
          hostRepository.updatedHost!.autoConnectCommand,
          contains(r'\; set status off'),
        );
        final savedPreset =
            verify(
                  () => presetService.setPresetForHost(1, captureAny()),
                ).captured.single
                as AgentLaunchPreset;
        expect(savedPreset.tmuxDisableStatusBar, isTrue);
        expect(savedPreset.tmuxSessionName, 'agent-session');
        expect(savedPreset.tmuxExtraFlags, '-x 200 -y 60');
      },
    );

    testWidgets(
      'uses the host CLI yolo mode setting in generated agent commands',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(420, 900));

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Agent Host',
            autoConnectRequiresConfirmation: false,
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final presetService = _MockAgentLaunchPresetService();
        const preset = AgentLaunchPreset(tool: AgentLaunchTool.codex);
        when(
          () => presetService.getPresetForHost(1),
        ).thenAnswer((_) async => preset);
        when(
          () => presetService.setPresetForHost(1, any()),
        ).thenAnswer((_) async {});
        when(
          () => presetService.deletePresetForHost(1),
        ).thenAnswer((_) async {});

        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              agentLaunchPresetServiceProvider.overrideWithValue(presetService),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(
                _FakeSnippetRepository(snippets: const [], database: database),
              ),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final yoloFinder = find.byKey(const Key('host-cli-yolo-mode-checkbox'));
        expect(yoloFinder, findsOneWidget);
        expect(tester.widget<CheckboxListTile>(yoloFinder).value, isFalse);

        await tester.tap(yoloFinder);
        await tester.pump();

        expect(
          find.textContaining('codex --yolo', findRichText: true),
          findsOneWidget,
        );

        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.scrollUntilVisible(
          saveButton,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(saveButton);
        tester.widget<FilledButton>(saveButton).onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(
          hostRepository.updatedHost!.autoConnectCommand,
          contains('--yolo'),
        );
      },
    );

    testWidgets('validates agent tmux flags before saving', (tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      addTearDown(database.close);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(420, 900));

      final hostRepository = _FakeHostRepository(
        host: _testHost(
          id: 1,
          label: 'Agent Host',
          autoConnectRequiresConfirmation: false,
        ),
        database: database,
        encryptionService: encryptionService,
      );
      final presetService = _MockAgentLaunchPresetService();
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxSessionName: 'agent-session',
      );
      when(
        () => presetService.getPresetForHost(1),
      ).thenAnswer((_) async => preset);
      when(
        () => presetService.setPresetForHost(1, any()),
      ).thenAnswer((_) async {});
      when(() => presetService.deletePresetForHost(1)).thenAnswer((_) async {});

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: SizedBox.shrink()),
          ),
          GoRoute(
            path: '/edit',
            builder: (context, state) => const HostEditScreen(hostId: 1),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
            databaseProvider.overrideWithValue(database),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
            keyRepositoryProvider.overrideWithValue(
              _FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              _FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              _FakePortForwardRepository(database: database),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      unawaited(router.push('/edit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byKey(const Key('host-agent-tmux-extra-flags-field')),
        r'\; set status off',
      );
      await tester.pump();

      expect(
        find.text(
          r'tmux new-session flags cannot include tmux command separators like \;.',
        ),
        findsWidgets,
      );

      final saveButton = find.byKey(
        const Key('host-save-button'),
        skipOffstage: false,
      );
      await tester.scrollUntilVisible(
        saveButton,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(saveButton);
      tester.widget<FilledButton>(saveButton).onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.text('Fix agent tmux flags to save this host'),
        findsOneWidget,
      );
      verifyNever(() => presetService.setPresetForHost(1, any()));
      expect(
        _textFieldHasFocus(
          tester,
          const Key('host-agent-tmux-extra-flags-field'),
        ),
        isTrue,
      );
    });

    testWidgets(
      'prefers an existing agent preset over legacy tmux startup fields',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(const Size(420, 900));

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Legacy Mixed Host',
            autoConnectRequiresConfirmation: false,
            tmuxSessionName: 'workspace',
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final presetService = _MockAgentLaunchPresetService();
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          tmuxSessionName: 'agent-session',
          tmuxDisableStatusBar: true,
        );
        when(
          () => presetService.getPresetForHost(1),
        ).thenAnswer((_) async => preset);
        when(
          () => presetService.setPresetForHost(1, any()),
        ).thenAnswer((_) async {});
        when(
          () => presetService.deletePresetForHost(1),
        ).thenAnswer((_) async {});

        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              agentLaunchPresetServiceProvider.overrideWithValue(presetService),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(
                _FakeSnippetRepository(snippets: const [], database: database),
              ),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const Key('host-agent-tool-field')), findsOneWidget);
        final checkboxFinder = find.byKey(
          const Key('host-agent-disable-status-bar-checkbox'),
        );
        expect(checkboxFinder, findsOneWidget);
        expect(tester.widget<CheckboxListTile>(checkboxFinder).value, isTrue);
        expect(find.byKey(const Key('host-tmux-session-field')), findsNothing);

        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.scrollUntilVisible(
          saveButton,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(saveButton);
        tester.widget<FilledButton>(saveButton).onPressed!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(
          hostRepository.updatedHost!.autoConnectCommand,
          contains(r'\; set status off'),
        );
        final savedPreset =
            verify(
                  () => presetService.setPresetForHost(1, captureAny()),
                ).captured.single
                as AgentLaunchPreset;
        expect(savedPreset.tmuxDisableStatusBar, isTrue);
        verifyNever(() => presetService.deletePresetForHost(1));
      },
    );

    testWidgets(
      'clears imported auto-connect review after replacing the command',
      (tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final encryptionService = SecretEncryptionService.forTesting();
        addTearDown(database.close);

        final hostRepository = _FakeHostRepository(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectCommand: 'tmux attach',
            autoConnectRequiresConfirmation: true,
          ),
          database: database,
          encryptionService: encryptionService,
        );
        final monetizationService = _buildProMonetizationService();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) =>
                  const Scaffold(body: SizedBox.shrink()),
            ),
            GoRoute(
              path: '/edit',
              builder: (context, state) => const HostEditScreen(hostId: 1),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              monetizationServiceProvider.overrideWithValue(
                monetizationService,
              ),
              databaseProvider.overrideWithValue(database),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              keyRepositoryProvider.overrideWithValue(
                _FakeKeyRepository(
                  database: database,
                  encryptionService: encryptionService,
                ),
              ),
              snippetRepositoryProvider.overrideWithValue(
                _FakeSnippetRepository(snippets: const [], database: database),
              ),
              portForwardRepositoryProvider.overrideWithValue(
                _FakePortForwardRepository(database: database),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );

        unawaited(router.push('/edit'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final formScroll = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('host-auto-connect-command-field')),
          200,
          scrollable: formScroll,
        );
        await tester.enterText(
          find.byKey(const Key('host-auto-connect-command-field')),
          'tmux new -As MonkeySSH',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('Save Changes'),
          200,
          scrollable: formScroll,
        );
        final saveButton = find.byKey(
          const Key('host-save-button'),
          skipOffstage: false,
        );
        await tester.ensureVisible(saveButton);
        await tester.tap(saveButton, warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(hostRepository.updatedHost, isNotNull);
        expect(
          hostRepository.updatedHost!.autoConnectCommand,
          'tmux new -As MonkeySSH',
        );
        expect(hostRepository.updatedHost!.autoConnectSnippetId, isNull);
        expect(
          hostRepository.updatedHost!.autoConnectRequiresConfirmation,
          isFalse,
        );
      },
    );

    testWidgets('shows Pro helper copy for auto-run automation', (
      tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      addTearDown(database.close);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(420, 900));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            hostRepositoryProvider.overrideWithValue(
              _FakeHostRepository(
                host: _testHost(
                  id: 1,
                  label: 'Imported Host',
                  autoConnectRequiresConfirmation: false,
                ),
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            keyRepositoryProvider.overrideWithValue(
              _FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              _FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              _FakePortForwardRepository(database: database),
            ),
          ],
          child: const MaterialApp(home: HostEditScreen()),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(
          'Free hosts can still open tmux automatically. MonkeySSH Pro unlocks coding agents, custom commands, and saved snippets after connect.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('keeps auto-run command read-only without Pro access', (
      tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      addTearDown(database.close);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(420, 900));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            hostRepositoryProvider.overrideWithValue(
              _FakeHostRepository(
                host: _testHost(
                  id: 1,
                  label: 'Imported Host',
                  autoConnectCommand: 'tmux attach',
                  autoConnectRequiresConfirmation: false,
                ),
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            keyRepositoryProvider.overrideWithValue(
              _FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              _FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              _FakePortForwardRepository(database: database),
            ),
          ],
          child: const MaterialApp(home: HostEditScreen(hostId: 1)),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.byKey(const Key('host-auto-connect-command-field')),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      final commandField = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('host-auto-connect-command-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(commandField.readOnly, isTrue);
    });
  });
}
