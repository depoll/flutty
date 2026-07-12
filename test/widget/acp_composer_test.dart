// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/presentation/controllers/acp_composer_controller.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';

class _FakeConnector extends Fake implements AcpBridgeConnector {}

class _FakeProviderService extends Fake implements AcpProviderService {}

class _FakeRecent extends Fake implements AcpRecentSessionsService {}

class _RecordingManager extends AcpSessionManager {
  _RecordingManager()
    : super(
        connector: _FakeConnector(),
        providerService: _FakeProviderService(),
        recentSessions: _FakeRecent(),
        isProUnlocked: () => true,
      );

  int promptCount = 0;
  int cancelCount = 0;

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) async {
    promptCount++;
    return const AcpPromptResult(stopReason: AcpStopReason.endTurn);
  }

  @override
  Future<void> cancelPrompt(AcpSessionKey key) async {
    cancelCount++;
  }
}

AcpSessionKey _key() => AcpSessionKey.of(
  hostId: 1,
  providerId: 'copilot',
  bridgeId: 'bridge',
  acpSessionId: 'session',
);

AcpSessionState _session({
  AcpPromptStatus promptStatus = AcpPromptStatus.idle,
  List<AcpAvailableCommand> commands = const <AcpAvailableCommand>[],
}) {
  final now = DateTime(2026);
  return AcpSessionState(
    key: _key(),
    providerLabel: 'Copilot',
    cwd: '/home',
    status: AcpConnectionStatus.ready,
    createdAt: now,
    lastActivityAt: now,
    promptStatus: promptStatus,
    availableCommands: commands,
    initialization: const AcpInitializeResult(protocolVersion: 1),
  );
}

Future<void> _pump(
  WidgetTester tester,
  AcpComposerController controller, {
  AcpComposerAttachmentActions actions = const AcpComposerAttachmentActions(),
  ThemeData? theme,
  Size size = const Size(400, 800),
  VoidCallback? onOpenConfig,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            AcpComposer(
              controller: controller,
              attachmentActions: actions,
              onOpenConfig: onOpenConfig,
            ),
          ],
        ),
      ),
    ),
  );
}

AcpComposerController _makeController(
  _RecordingManager manager, {
  AcpSessionState? session,
}) => AcpComposerController(
  manager: manager,
  sessionKey: _key(),
  initialSession: session ?? _session(),
);

void main() {
  testWidgets('send is disabled empty and enabled after typing', (
    tester,
  ) async {
    final manager = _RecordingManager();
    final controller = _makeController(manager);
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(controller.canSend, isFalse);
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(controller.canSend, isTrue);

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();
    expect(manager.promptCount, 1);
  });

  testWidgets('primary action becomes Stop while streaming and cancels', (
    tester,
  ) async {
    final manager = _RecordingManager();
    final controller = _makeController(
      manager,
      session: _session(promptStatus: AcpPromptStatus.streaming),
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.bySemanticsLabel('Stop'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    expect(manager.cancelCount, 1);
  });

  testWidgets('send button meets the 44px minimum touch target', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final size = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(IconButton),
      ),
    );
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('slash picker appears and touch selection inserts the command', (
    tester,
  ) async {
    final controller = _makeController(
      _RecordingManager(),
      session: _session(
        commands: const [
          AcpAvailableCommand(name: 'deploy', description: 'Deploy the build'),
        ],
      ),
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.enterText(find.byType(TextField), '/dep');
    await tester.pump();
    expect(find.text('/deploy'), findsOneWidget);
    expect(find.text('Deploy the build'), findsOneWidget);

    await tester.tap(find.text('/deploy'));
    await tester.pump();
    expect(controller.text, '/deploy ');
    expect(find.text('Deploy the build'), findsNothing);
  });

  testWidgets('keyboard arrow + enter selects a slash command', (tester) async {
    final controller = _makeController(
      _RecordingManager(),
      session: _session(
        commands: const [
          AcpAvailableCommand(name: 'build', description: 'Build'),
          AcpAvailableCommand(name: 'debug', description: 'Debug'),
        ],
      ),
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '/debug ');
  });

  testWidgets('add menu adds an attachment shown in the strip', (tester) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    final actions = AcpComposerAttachmentActions(
      pickFiles: (_) async => [
        AcpAttachmentCandidate.memory(
          name: 'notes.txt',
          bytes: Uint8List.fromList('hello'.codeUnits),
          mimeType: 'text/plain',
        ),
      ],
    );
    await _pump(tester, controller, actions: actions);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();

    expect(controller.attachments, hasLength(1));
    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove notes.txt'));
    await tester.pump();
    expect(controller.attachments, isEmpty);
  });

  testWidgets('error banner surfaces a dismissable message', (tester) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    controller.addAttachment(
      const AcpAttachmentCandidate.remoteFile(
        name: 'huge.bin',
        remotePath: '/huge.bin',
        sizeBytes: 500 * 1024 * 1024,
      ),
    );
    await tester.pump();
    expect(find.text('That file is too large to attach.'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss error'));
    await tester.pump();
    expect(find.text('That file is too large to attach.'), findsNothing);
  });

  testWidgets('renders in light and dark themes and wide layout', (
    tester,
  ) async {
    for (final theme in [
      ThemeData.light(useMaterial3: true),
      ThemeData.dark(useMaterial3: true),
    ]) {
      final controller = _makeController(_RecordingManager());
      addTearDown(controller.dispose);
      await _pump(
        tester,
        controller,
        theme: theme,
        size: const Size(1200, 800),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(AcpComposer), findsOneWidget);
    }
  });

  testWidgets('config affordance is shown when a handler is provided', (
    tester,
  ) async {
    var opened = false;
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller, onOpenConfig: () => opened = true);

    await tester.tap(find.byTooltip('Session settings'));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('rebinds to a replacement controller in didUpdateWidget', (
    tester,
  ) async {
    final controllerA = _makeController(_RecordingManager())..setText('from A');
    final controllerB = _makeController(_RecordingManager())..setText('from B');
    addTearDown(controllerA.dispose);
    addTearDown(controllerB.dispose);

    await _pump(tester, controllerA);
    expect(find.text('from A'), findsOneWidget);

    await _pump(tester, controllerB);
    await tester.pump();
    expect(find.text('from B'), findsOneWidget);

    // Edits now flow to the new controller, not the detached old one.
    await tester.enterText(find.byType(TextField), 'edited');
    await tester.pump();
    expect(controllerB.text, 'edited');
    expect(controllerA.text, 'from A');
  });

  testWidgets('disables editing controls while a turn streams', (tester) async {
    final controller = _makeController(
      _RecordingManager(),
      session: _session(promptStatus: AcpPromptStatus.streaming),
    );
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller,
      actions: AcpComposerAttachmentActions(pickFiles: (_) async => const []),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
    final addButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add),
    );
    expect(addButton.onPressed, isNull);
  });

  testWidgets('adds no extra keyboard inset padding under a Scaffold', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 250)),
            child: Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox.expand()),
                  AcpComposer(controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final paddings = tester.widgetList<Padding>(
      find.descendant(
        of: find.byType(AcpComposer),
        matching: find.byType(Padding),
      ),
    );
    final doublePadded = paddings.any(
      (padding) => padding.padding.resolve(TextDirection.ltr).bottom >= 250,
    );
    expect(doublePadded, isFalse);
  });
}
