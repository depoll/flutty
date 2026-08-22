// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/theme.dart';
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
  List<AcpContentBlock>? lastPrompt;

  @override
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) async {
    promptCount++;
    lastPrompt = List<AcpContentBlock>.of(content);
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
  Widget? controls,
  AcpComposerFocusController? focusController,
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
              focusController: focusController,
              onOpenConfig: onOpenConfig,
              controls: controls,
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

  testWidgets('unsupported arbitrary file immediately offers private upload', (
    tester,
  ) async {
    final manager = _RecordingManager();
    final controller = _makeController(manager)
      ..addAttachment(
        AcpAttachmentCandidate.memory(
          name: 'notes.bin',
          bytes: Uint8List.fromList(const [1, 2, 3]),
          mimeType: 'application/octet-stream',
        ),
      );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Upload to the server?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Upload'), findsOneWidget);
    expect(manager.promptCount, 0);
  });

  testWidgets('streaming with an empty draft uses one primary Stop control', (
    tester,
  ) async {
    final manager = _RecordingManager();
    final controller = _makeController(
      manager,
      session: _session(promptStatus: AcpPromptStatus.streaming),
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    expect(find.byTooltip('Stop active turn'), findsOneWidget);
    expect(find.byTooltip('Queue message'), findsNothing);
    await tester.tap(find.byTooltip('Stop active turn'));
    await tester.pump();
    expect(manager.cancelCount, 1);
  });

  testWidgets('Cmd/Ctrl+Enter sends from a hardware keyboard', (tester) async {
    final manager = _RecordingManager();
    final controller = _makeController(manager)..setText('ship it');
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    await tester.tap(find.byType(TextField));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(manager.promptCount, 1);
  });

  testWidgets('send button meets the 44px minimum touch target', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final size = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward_rounded),
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

    final fieldFinder = find.byType(TextField);
    await tester.tap(fieldFinder);
    await tester.showKeyboard(fieldFinder);
    final editableBefore = tester.element(find.byType(EditableText));
    await tester.enterText(fieldFinder, '/');
    await tester.pump();
    expect(tester.element(find.byType(EditableText)), same(editableBefore));
    expect(tester.testTextInput.isVisible, isTrue);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    FocusManager.instance.primaryFocus?.unfocus();
    controller.setText('/dep');
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    expect(find.text('/deploy'), findsOneWidget);
    expect(find.text('Deploy the build'), findsOneWidget);

    await tester.tap(find.text('/deploy'));
    await tester.pump();
    expect(controller.text, '/deploy ');
    expect(find.text('Deploy the build'), findsNothing);
  });

  testWidgets('uses the proportional body style for prompt input', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final fieldFinder = find.byType(TextField);
    final field = tester.widget<TextField>(fieldFinder);
    final bodyFamily = Theme.of(
      tester.element(fieldFinder),
    ).textTheme.bodyMedium?.fontFamily;
    expect(field.style?.fontFamily, bodyFamily);
    expect(field.style?.fontFamily, isNot(FluttyTheme.monoStyle.fontFamily));
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

  testWidgets('large system paste becomes a removable text chip', (
    tester,
  ) async {
    final manager = _RecordingManager();
    final controller = _makeController(manager);
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    final pasted = List.generate(24, (index) => 'line $index').join('\n');

    await tester.enterText(find.byType(TextField), pasted);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(controller.attachments, hasLength(1));
    expect(controller.attachments.single.isPastedText, isTrue);
    expect(find.text('Pasted text · 24 lines'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();
    expect(manager.lastPrompt, hasLength(1));
    expect(manager.lastPrompt!.single, isA<AcpTextContent>());
    expect((manager.lastPrompt!.single as AcpTextContent).text, pasted);
  });

  testWidgets('focus controller collapses extended-keyboard large paste', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    final focusController = AcpComposerFocusController();
    addTearDown(controller.dispose);
    await _pump(tester, controller, focusController: focusController);

    focusController.pasteText('x' * kAcpLargePasteThresholdChars);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(controller.attachments.single.isPastedText, isTrue);
  });

  testWidgets('focus controller attaches extended-keyboard clipboard image', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    final focusController = AcpComposerFocusController();
    addTearDown(controller.dispose);
    await _pump(tester, controller, focusController: focusController);

    focusController.pasteImage(Uint8List.fromList(const [137, 80, 78, 71]));
    await tester.pump();

    expect(controller.attachments, hasLength(1));
    expect(controller.attachments.single.isImage, isTrue);
    expect(controller.attachments.single.name, 'Pasted image.png');
  });

  testWidgets('Android keyboard rich image becomes an attachment', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    final field = tester.widget<TextField>(find.byType(TextField));

    field.contentInsertionConfiguration!.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: 'content://keyboard/image',
        data: Uint8List.fromList(const [137, 80, 78, 71]),
      ),
    );
    await tester.pump();

    expect(controller.attachments, hasLength(1));
    expect(controller.attachments.single.isImage, isTrue);
    expect(controller.attachments.single.name, 'Pasted image.png');
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

  testWidgets('keeps editing and queue controls available while streaming', (
    tester,
  ) async {
    final controller = _makeController(
      _RecordingManager(),
      session: _session(promptStatus: AcpPromptStatus.streaming),
    )..setText('steer next');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller,
      actions: AcpComposerAttachmentActions(pickFiles: (_) async => const []),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isFalse);
    expect(find.byTooltip('Add to prompt'), findsOneWidget);
    expect(find.byTooltip('Queue message'), findsOneWidget);
    expect(find.byTooltip('Stop active turn'), findsOneWidget);
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

  testWidgets('add menu opens above the plus button', (tester) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller,
      actions: AcpComposerAttachmentActions(pickFiles: (_) async => const []),
    );

    final addButton = find.byTooltip('Add to prompt');
    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(find.text('Snippet'), findsNothing);
    expect(find.text('Choose file'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Choose file')).dy,
      lessThan(tester.getTopLeft(addButton).dy),
    );
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('focus promotes the unified surface border to the accent', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    final surface = find.byKey(const ValueKey('acp-composer-surface'));
    final context = tester.element(surface);
    final scheme = Theme.of(context).colorScheme;
    BoxDecoration decoration() =>
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;

    expect(decoration().border?.top.color, scheme.outlineVariant);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 120));
    expect(decoration().border?.top.color, scheme.primary);
  });

  testWidgets('input and actions share one upward-growing composer surface', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager())..setText('send');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller,
      controls: const SizedBox(
        key: ValueKey('test-composer-controls'),
        height: 44,
        child: Text('Model: Sonnet'),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textAlignVertical, TextAlignVertical.top);
    expect(
      field.decoration?.contentPadding,
      const EdgeInsets.fromLTRB(14, 14, 14, 10),
    );
    final sendFinder = find.ancestor(
      of: find.byIcon(Icons.arrow_upward_rounded),
      matching: find.byType(IconButton),
    );
    final send = tester.widget<IconButton>(sendFinder);
    expect(send.padding, EdgeInsets.zero);
    expect(
      send.constraints,
      const BoxConstraints.tightFor(width: 44, height: 44),
    );

    final surface = find.byKey(const ValueKey('acp-composer-surface'));
    expect(surface, findsOneWidget);
    expect(
      find.ancestor(of: find.byType(TextField), matching: surface),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('test-composer-controls')),
        matching: surface,
      ),
      findsOneWidget,
    );
    expect(find.ancestor(of: sendFinder, matching: surface), findsOneWidget);
    expect(
      tester.getTopLeft(sendFinder).dy,
      greaterThan(tester.getTopLeft(find.byType(TextField)).dy),
    );
  });

  testWidgets('multiline input grows upward while toolbar stays anchored', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    addTearDown(controller.dispose);
    await _pump(tester, controller, size: const Size(360, 700));

    final surface = find.byKey(const ValueKey('acp-composer-surface'));
    final send = find.byTooltip('Send');
    final initialSurface = tester.getRect(surface);
    final initialSendBottom = tester.getBottomLeft(send).dy;

    await tester.enterText(
      find.byType(TextField),
      'one\ntwo\nthree\nfour\nfive',
    );
    await tester.pump();

    final expandedSurface = tester.getRect(surface);
    expect(expandedSurface.height, greaterThan(initialSurface.height));
    expect(expandedSurface.top, lessThan(initialSurface.top));
    expect(tester.getBottomLeft(send).dy, closeTo(initialSendBottom, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('external focus controller opens and dismisses the composer', (
    tester,
  ) async {
    final controller = _makeController(_RecordingManager());
    final focusController = AcpComposerFocusController();
    addTearDown(controller.dispose);
    await _pump(tester, controller, focusController: focusController);

    focusController.requestFocus();
    await tester.pump();
    expect(focusController.hasFocus, isTrue);

    focusController.dismissKeyboard();
    await tester.pump();
    expect(focusController.hasFocus, isFalse);
  });
}
