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
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/host_edit_screen.dart';
import 'package:monkeyssh/presentation/view_models/host_edit_view_model.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';

import '../helpers/host_edit_fixture.dart';

Host _testHost({
  required int id,
  required String label,
  required bool autoConnectRequiresConfirmation,
  String? autoConnectCommand,
  int? autoConnectSnippetId,
  String? tmuxSessionName,
  String? tmuxWorkingDirectory,
  String? tmuxExtraFlags,
  String? remoteMuxBackend,
  String? terminalThemeLightId,
  String? terminalThemeDarkId,
  String? terminalFontFamily,
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
  autoForwardPorts: false,
  tmuxSessionName: tmuxSessionName,
  tmuxWorkingDirectory: tmuxWorkingDirectory,
  tmuxExtraFlags: tmuxExtraFlags,
  remoteMuxBackend: remoteMuxBackend,
  terminalThemeLightId: terminalThemeLightId,
  terminalThemeDarkId: terminalThemeDarkId,
  terminalFontFamily: terminalFontFamily,
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

  final FakeHostRepository hostRepository;
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

  final hostRepository = FakeHostRepository(
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
          FakeKeyRepository(
            database: database,
            encryptionService: encryptionService,
          ),
        ),
        snippetRepositoryProvider.overrideWithValue(
          FakeSnippetRepository(snippets: snippets, database: database),
        ),
        portForwardRepositoryProvider.overrideWithValue(
          FakePortForwardRepository(database: database),
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
  await tester.tap(startupModeField);
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

String _fieldText(WidgetTester tester, Key fieldKey) {
  final editableText = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(fieldKey),
      matching: find.byType(EditableText),
    ),
  );
  return editableText.controller.text;
}

/// Opens the startup-mode dropdown from any current selection and taps [label].
Future<void> _switchStartupMode(WidgetTester tester, String label) async {
  final startupModeField = find.byKey(const Key('host-startup-mode-field'));
  await tester.scrollUntilVisible(
    startupModeField,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(startupModeField);
  await tester.tap(startupModeField);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
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

    testWidgets('saves automatic forwarding and a custom proxy domain', (
      tester,
    ) async {
      final harness = await _pumpHostCreateScreen(tester);
      await _fillRequiredHostFields(tester);
      final switchFinder = find.byKey(
        const Key('host-auto-forward-ports-switch'),
      );
      await tester.scrollUntilVisible(
        switchFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(switchFinder);
      await tester.pump();

      final proxyNameField = find.byKey(
        const Key('host-port-proxy-name-field'),
      );
      expect(proxyNameField, findsOneWidget);
      await tester.enterText(proxyNameField, 'my.dev');
      await _tapBottomSave(tester);

      final insertedHost = harness.hostRepository.insertedHost;
      expect(insertedHost, isNotNull);
      expect(insertedHost!.autoForwardPorts.value, isTrue);
      expect(insertedHost.portProxyName.value, 'my.dev');
    });

    testWidgets('does not promise an unresolved generated proxy name', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester);
      await _fillRequiredHostFields(tester);
      final switchFinder = find.byKey(
        const Key('host-auto-forward-ports-switch'),
      );
      await tester.scrollUntilVisible(
        switchFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(switchFinder);
      await tester.pump();

      final proxyNameField = find.byKey(
        const Key('host-port-proxy-name-field'),
      );
      InputDecoration proxyNameDecoration() => tester
          .widget<InputDecorator>(
            find.descendant(
              of: proxyNameField,
              matching: find.byType(InputDecorator),
            ),
          )
          .decoration;
      expect(proxyNameDecoration().hintText, isNull);
      expect(
        proxyNameDecoration().helperText,
        'Leave blank to generate a unique name from the host label.',
      );
    });

    testWidgets('focuses an invalid automatic proxy domain on save', (
      tester,
    ) async {
      final harness = await _pumpHostCreateScreen(tester);
      await _fillRequiredHostFields(tester);
      final switchFinder = find.byKey(
        const Key('host-auto-forward-ports-switch'),
      );
      await tester.scrollUntilVisible(
        switchFinder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(switchFinder);
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('host-port-proxy-name-field')),
        '-invalid',
      );

      await _tapBottomSave(tester);

      expect(find.text('Fix proxy domain to save this host'), findsOneWidget);
      expect(
        _textFieldHasFocus(tester, const Key('host-port-proxy-name-field')),
        isTrue,
      );
      expect(harness.hostRepository.insertedHost, isNull);
    });

    testWidgets('warns before leaving with unsaved host changes', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester);

      await tester.enterText(
        find.byKey(const Key('host-label-field')),
        'Unsaved Host',
      );
      await tester.pump();
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(HostEditScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Discard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(HostEditScreen), findsNothing);
    });

    testWidgets('lets long host guidance text wrap', (tester) async {
      await _pumpHostCreateScreen(tester, hasPro: true);

      final startupModeField = tester
          .widget<DropdownButtonFormField<HostStartupMode>>(
            find.byKey(const Key('host-startup-mode-field')),
          );
      expect(startupModeField.decoration.helperMaxLines, greaterThan(1));

      await _selectStartupMode(tester, 'Launch coding agent');

      final backendField = tester
          .widget<DropdownButtonFormField<RemoteMuxBackend>>(
            find.byKey(const Key('host-agent-mux-backend-field')),
          );
      expect(backendField.decoration.helperMaxLines, greaterThan(1));

      final agentSessionField = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('host-agent-tmux-session-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(agentSessionField.decoration!.helperMaxLines, greaterThan(1));
    });

    testWidgets('shows explicit MonkeyMux and tmux startup choices', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester, hasPro: true);

      final startupModeField = find.byKey(const Key('host-startup-mode-field'));
      await tester.scrollUntilVisible(
        startupModeField,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(startupModeField);
      await tester.tap(startupModeField);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('MonkeyMux'), findsOneWidget);
      expect(find.text('tmux'), findsOneWidget);
      expect(find.text('Automatic windows'), findsNothing);
    });

    testWidgets('keeps app-wide agent window mode out of host settings', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester, hasPro: true);
      final modeField = find.byKey(const Key('host-agent-window-mode-field'));

      expect(modeField, findsNothing);
      await _selectStartupMode(tester, 'MonkeyMux');
      expect(modeField, findsNothing);
      await _selectStartupMode(tester, 'tmux');
      expect(modeField, findsNothing);
      await _selectStartupMode(tester, 'Launch coding agent');
      expect(modeField, findsNothing);
    });

    testWidgets('retains tmux session config when switching to coding agent', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester, hasPro: true);
      await _fillRequiredHostFields(tester);
      await _switchStartupMode(tester, 'tmux');

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
        '-x 160',
      );
      await tester.pump();

      await _switchStartupMode(tester, 'Launch coding agent');

      expect(
        _fieldText(tester, const Key('host-agent-tmux-session-field')),
        'workspace',
      );
      expect(
        _fieldText(tester, const Key('host-agent-working-directory-field')),
        '~/src/app',
      );
      // The agent tmux flags field only renders when the carried-over tmux
      // backend is applied, so its presence and value confirm both.
      expect(
        find.byKey(const Key('host-agent-tmux-extra-flags-field')),
        findsOneWidget,
      );
      expect(
        _fieldText(tester, const Key('host-agent-tmux-extra-flags-field')),
        '-x 160',
      );
    });

    testWidgets(
      'retains coding agent session config when switching to tmux startup',
      (tester) async {
        await _pumpHostCreateScreen(tester, hasPro: true);
        await _fillRequiredHostFields(tester);
        await _switchStartupMode(tester, 'Launch coding agent');

        await tester.enterText(
          find.byKey(const Key('host-agent-tmux-session-field')),
          'agent-workspace',
        );
        await tester.enterText(
          find.byKey(const Key('host-agent-working-directory-field')),
          '~/src/agent',
        );
        await tester.pump();

        await _switchStartupMode(tester, 'tmux');

        expect(
          _fieldText(tester, const Key('host-tmux-session-field')),
          'agent-workspace',
        );
        expect(
          _fieldText(tester, const Key('host-tmux-working-directory-field')),
          '~/src/agent',
        );
      },
    );

    testWidgets('does not overwrite existing coding agent values on switch', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester, hasPro: true);
      await _fillRequiredHostFields(tester);

      await _switchStartupMode(tester, 'Launch coding agent');
      await tester.enterText(
        find.byKey(const Key('host-agent-tmux-session-field')),
        'agent-session',
      );
      await tester.pump();

      await _switchStartupMode(tester, 'tmux');
      await tester.enterText(
        find.byKey(const Key('host-tmux-session-field')),
        'tmux-session',
      );
      await tester.pump();

      await _switchStartupMode(tester, 'Launch coding agent');

      expect(
        _fieldText(tester, const Key('host-agent-tmux-session-field')),
        'agent-session',
      );
    });

    testWidgets('scrolls to missing tmux session when saving tmux startup', (
      tester,
    ) async {
      final harness = await _pumpHostCreateScreen(tester);
      await _fillRequiredHostFields(tester);
      await _selectStartupMode(tester, 'tmux');

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

    testWidgets('shows one selected coding agent icon in closed dropdown', (
      tester,
    ) async {
      await _pumpHostCreateScreen(tester, hasPro: true);
      await _selectStartupMode(tester, 'Launch coding agent');

      final agentField = find.byKey(const Key('host-agent-tool-field'));
      await tester.ensureVisible(agentField);
      await tester.tap(agentField);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.widgetWithText(DropdownMenuItem<AgentLaunchTool>, 'Copilot CLI'),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.descendant(of: agentField, matching: find.byType(AgentToolIcon)),
        findsOneWidget,
      );
    });

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
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectCommand: 'tmux attach',
            autoConnectSnippetId: 7,
            autoConnectRequiresConfirmation: true,
          ),
        );
        await fixture.setSurfaceSize(tester);
        final hostRepository = fixture.hostRepository;

        await fixture.pump(
          tester,
          snippets: [
            _testSnippet(id: 7, name: 'Attach tmux', command: 'tmux attach'),
          ],
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
          ],
        );

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
      final fixture = HostEditFixture(
        host: _testHost(
          id: 1,
          label: 'Imported Host',
          autoConnectRequiresConfirmation: false,
          tmuxSessionName: 'old-workspace',
          remoteMuxBackend: RemoteMuxBackend.tmux.storageValue,
        ),
      );
      await fixture.setSurfaceSize(tester);
      final hostRepository = fixture.hostRepository;

      await fixture.pump(tester);

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
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectRequiresConfirmation: false,
            tmuxSessionName: 'old-workspace',
            remoteMuxBackend: RemoteMuxBackend.tmux.storageValue,
          ),
        );
        await fixture.setSurfaceSize(tester);
        final hostRepository = fixture.hostRepository;

        await fixture.pump(tester);

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
      final fixture = HostEditFixture(
        host: _testHost(
          id: 1,
          label: 'Imported Host',
          autoConnectRequiresConfirmation: false,
          tmuxSessionName: 'workspace',
          tmuxExtraFlags: r'-f ~/.tmux.conf \; set status off',
          remoteMuxBackend: RemoteMuxBackend.tmux.storageValue,
        ),
      );
      await fixture.setSurfaceSize(tester);
      final hostRepository = fixture.hostRepository;

      await fixture.pump(tester);

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
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Agent Host',
            autoConnectRequiresConfirmation: false,
          ),
        );
        await fixture.setSurfaceSize(tester);
        final hostRepository = fixture.hostRepository;

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

        await fixture.pump(
          tester,
          overrides: [
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),

            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
          ],
        );

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
      'defaults agent startup to MonkeyMux and hides tmux-only options',
      (tester) async {
        await _pumpHostCreateScreen(tester, hasPro: true);

        await _selectStartupMode(tester, 'Launch coding agent');

        final backendField = find.byKey(
          const Key('host-agent-mux-backend-field'),
        );
        expect(backendField, findsOneWidget);
        expect(find.text('MonkeyMux session (optional)'), findsOneWidget);
        expect(
          find.byKey(const Key('host-agent-disable-status-bar-checkbox')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('host-agent-tmux-extra-flags-field')),
          findsNothing,
        );
        expect(
          find.text(
            'MonkeyMux is managed by MonkeySSH, so there are no tmux flags or tmux status-bar settings.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('claude', findRichText: true), findsWidgets);

        await tester.tap(backendField);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('tmux').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('tmux session (optional)'), findsOneWidget);
        expect(
          find.byKey(const Key('host-agent-disable-status-bar-checkbox')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('host-agent-tmux-extra-flags-field')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'uses the host CLI yolo mode setting in generated agent commands',
      (tester) async {
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Agent Host',
            autoConnectRequiresConfirmation: false,
          ),
        );
        await fixture.setSurfaceSize(tester);
        final hostRepository = fixture.hostRepository;
        final database = fixture.database;

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

        await fixture.pump(
          tester,
          overrides: [
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),

            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
          ],
        );

        expect(
          find.byKey(const Key('host-agent-window-mode-field')),
          findsNothing,
        );

        final yoloFinder = find.byKey(const Key('host-cli-yolo-mode-checkbox'));
        expect(yoloFinder, findsOneWidget);
        expect(tester.widget<CheckboxListTile>(yoloFinder).value, isFalse);

        await tester.scrollUntilVisible(
          yoloFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(yoloFinder);
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
        final savedPreferences = await HostCliLaunchPreferencesService(
          SettingsService(database),
        ).getPreferencesForHost(1);
        expect(savedPreferences.startInYoloMode, isTrue);
      },
    );

    testWidgets('validates agent tmux flags before saving', (tester) async {
      final fixture = HostEditFixture(
        host: _testHost(
          id: 1,
          label: 'Agent Host',
          autoConnectRequiresConfirmation: false,
        ),
      );
      await fixture.setSurfaceSize(tester);

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

      await fixture.pump(
        tester,
        overrides: [
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proMonetizationState),
          ),

          agentLaunchPresetServiceProvider.overrideWithValue(presetService),
        ],
      );

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
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Legacy Mixed Host',
            autoConnectRequiresConfirmation: false,
            tmuxSessionName: 'workspace',
          ),
        );
        await fixture.setSurfaceSize(tester);
        final hostRepository = fixture.hostRepository;

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

        await fixture.pump(
          tester,
          overrides: [
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),

            agentLaunchPresetServiceProvider.overrideWithValue(presetService),
          ],
        );

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
        final fixture = HostEditFixture(
          host: _testHost(
            id: 1,
            label: 'Imported Host',
            autoConnectCommand: 'tmux attach',
            autoConnectRequiresConfirmation: true,
          ),
        );
        final hostRepository = fixture.hostRepository;

        final monetizationService = _buildProMonetizationService();

        await fixture.pump(
          tester,
          overrides: [
            monetizationServiceProvider.overrideWithValue(monetizationService),
          ],
        );

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

    testWidgets('explains launch behavior without plan-gating copy', (
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
              FakeHostRepository(
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
              FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              FakePortForwardRepository(database: database),
            ),
          ],
          child: const MaterialApp(home: HostEditScreen()),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(
          'Choose what MonkeySSH starts after SSH connects. MonkeyMux and tmux keep remote shells alive across reconnects and add the window switcher; agent, command, and snippet options start a workflow automatically.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Terminal windows stay free'), findsNothing);
    });

    testWidgets(
      'dirty-state notifier: typing marks form dirty without extra setState pumps',
      (tester) async {
        // Verify that the ValueNotifier path correctly drives UnsavedChangesGuard
        // without the removed Form.onChanged whole-screen-rebuild.
        await _pumpHostCreateScreen(tester);

        // Type a single character – dirty state should update via controller
        // listener, not Form.onChanged.
        await tester.enterText(find.byKey(const Key('host-label-field')), 'X');
        await tester.pump();

        // Navigating back should trigger the discard dialog.
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Discard changes?'), findsOneWidget);

        await tester.tap(find.text('Discard'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(HostEditScreen), findsNothing);
      },
    );

    testWidgets(
      'dirty-state notifier: non-text state change (dropdown) marks form dirty',
      (tester) async {
        // Verify that UnsavedChangesGuard responds to non-text setStates that
        // call _updateDirtyState() – previously only Form.onChanged did this.
        await _pumpHostCreateScreen(tester);

        // Switch the startup mode dropdown (a pure non-text setState).
        await _selectStartupMode(tester, 'tmux');

        // Navigating back must trigger the discard dialog because startup mode
        // changed from the initial "Do nothing" value.
        await tester.pageBack();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Discard changes?'), findsOneWidget);

        await tester.tap(find.text('Discard'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(HostEditScreen), findsNothing);
      },
    );

    testWidgets(
      'dirty-state notifier: save resets dirty state so back-nav is clean',
      (tester) async {
        final harness = await _pumpHostCreateScreen(tester);

        await _fillRequiredHostFields(tester);
        await _tapBottomSave(tester);

        // After a successful save, host is inserted. The screen pops back.
        expect(harness.hostRepository.insertedHost, isNotNull);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(HostEditScreen), findsNothing);
      },
    );

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
              FakeHostRepository(
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
              FakeKeyRepository(
                database: database,
                encryptionService: encryptionService,
              ),
            ),
            snippetRepositoryProvider.overrideWithValue(
              FakeSnippetRepository(snippets: const [], database: database),
            ),
            portForwardRepositoryProvider.overrideWithValue(
              FakePortForwardRepository(database: database),
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

    testWidgets('selects a host font and saves reset font and theme overrides', (
      tester,
    ) async {
      final fixture = HostEditFixture(
        host: _testHost(
          id: 1,
          label: 'Themed Host',
          autoConnectRequiresConfirmation: false,
          terminalThemeLightId: 'iterm2-monokai-pro',
          terminalThemeDarkId: 'iterm2-dracula',
          terminalFontFamily: 'monospace',
        ),
      );
      await fixture.setSurfaceSize(tester);
      final hostRepository = fixture.hostRepository;
      await fixture.pump(tester);

      // Expand Advanced tile
      final advancedTile = find.byKey(const Key('host-advanced-tile'));
      await tester.scrollUntilVisible(
        advancedTile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(advancedTile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Scroll to the theme section
      await tester.scrollUntilVisible(
        find.text('terminal theme'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      // Verify monokai and dracula names are displayed
      expect(find.text('Monokai Pro'), findsOneWidget);
      expect(find.text('Dracula'), findsOneWidget);

      // Find the clear buttons and tap them. Since both tiles show a clear button,
      // we can find by Icon(Icons.clear). Let's verify we have 2 clear icons.
      final clearButtons = find.byIcon(Icons.clear);
      expect(clearButtons, findsNWidgets(3));

      // Tap the first one (Light theme clear button)
      await tester.tap(clearButtons.first);
      await tester.pump();

      // Verify light theme has been reset to "Use default"
      expect(find.text('Monokai Pro'), findsNothing);
      expect(find.text('Dracula'), findsOneWidget);

      // Tap the remaining clear button
      await tester.tap(find.byIcon(Icons.clear).first);
      await tester.pump();

      // Verify both are cleared
      expect(find.text('Dracula'), findsNothing);
      expect(find.text('Monokai Pro'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Terminal Font'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Terminal Font'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('JetBrains Mono'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('JetBrains Mono'), findsOneWidget);
      await tester.tap(find.byTooltip('Reset to default'));
      await tester.pump();
      expect(find.text('JetBrains Mono'), findsNothing);

      // Tap save
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

      // Verify database repositories received updated host with null themes
      expect(hostRepository.updatedHost, isNotNull);
      expect(hostRepository.updatedHost!.terminalThemeLightId, isNull);
      expect(hostRepository.updatedHost!.terminalThemeDarkId, isNull);
      expect(hostRepository.updatedHost!.terminalFontFamily, isNull);
    });
  });
}
