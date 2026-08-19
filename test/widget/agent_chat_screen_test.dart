// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/acp_attachment.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_chat_typography.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_inline_image.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_permission_surface.dart';
import 'package:monkeyssh/presentation/widgets/cursor_block.dart';
import 'package:monkeyssh/presentation/widgets/terminal_pinch_zoom_gesture_handler.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockSshSession extends Mock implements SshSession {}

class _FakeSftpClient extends Fake implements SftpClient {}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

Widget _wrap(
  FakeAcpSessionManager manager, {
  Size size = const Size(390, 800),
  AcpSessionKey? routeKey,
  bool hasActiveSshSession = false,
  bool embedded = false,
  double? preferredFontSize,
  String? preferredFontFamily,
  ValueChanged<double>? onFontSizeCommitted,
  AcpChatPreviewChanged? onPreviewChanged,
  SftpClient? sftpClient,
  AcpChatAttachmentActionsBuilder? attachmentActionsBuilder,
  EdgeInsets mediaPadding = EdgeInsets.zero,
}) {
  final ssh = _MockSshService();
  final key = routeKey ?? fakeAcpKey();
  final sshSession = _MockSshSession();
  when(() => sshSession.connectionId).thenReturn(7);
  when(() => sshSession.hostId).thenReturn(key.hostId);
  when(
    sshSession.sftp,
  ).thenAnswer((_) async => sftpClient ?? _FakeSftpClient());
  when(() => ssh.getSessionsForHost(any())).thenReturn(
    hasActiveSshSession ? <SshSession>[sshSession] : const <SshSession>[],
  );
  return ProviderScope(
    overrides: [
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: mediaPadding,
          viewPadding: mediaPadding,
        ),
        child: AgentChatScreen(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          attachmentActionsBuilder:
              attachmentActionsBuilder ??
              (_, _) => const AcpComposerAttachmentActions(),
          embedded: embedded,
          preferredFontSize: preferredFontSize,
          preferredFontFamily: preferredFontFamily,
          onFontSizeCommitted: onFontSizeCommitted,
          onPreviewChanged: onPreviewChanged,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the live timeline and composer on mobile', (
    tester,
  ) async {
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Hello from the agent'),
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byType(AcpMessageThread), findsOneWidget);
    expect(find.textContaining('Hello from the agent'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.byTooltip('MonkeyMux windows'), findsOneWidget);
    expect(find.byTooltip('Session settings'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Session settings'), findsOneWidget);
  });

  testWidgets('publishes a throttled native connection preview', (
    tester,
  ) async {
    final previews = <String?>[];
    final previewKeys = <AcpSessionKey>[];
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Preview from the native agent'),
    );
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        embedded: true,
        onPreviewChanged: (key, preview) {
          previewKeys.add(key);
          previews.add(preview);
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(previews, isNotEmpty);
    expect(previewKeys.single.value, fakeAcpKey().value);
    expect(previews.last, contains('Preview from the native agent'));
  });

  testWidgets('Pi model picker reads scope metadata and expands all models', (
    tester,
  ) async {
    final sftp = _MockSftpClient();
    final settingsFile = _MockSftpFile();
    final settingsBytes = Uint8List.fromList(
      utf8.encode('{"enabledModels":["anthropic/*:high"]}'),
    );
    const globalSettingsPath = '/home/demo/.pi/agent/settings.json';
    when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
    when(() => sftp.stat(any(), followLink: false)).thenAnswer((
      invocation,
    ) async {
      final path = invocation.positionalArguments.single as String;
      if (path == globalSettingsPath) {
        return SftpFileAttrs(size: settingsBytes.length);
      }
      throw StateError('missing optional project settings');
    });
    when(
      () => sftp.open(globalSettingsPath),
    ).thenAnswer((_) async => settingsFile);
    when(settingsFile.read).thenAnswer((_) => Stream.value(settingsBytes));
    when(settingsFile.close).thenAnswer((_) async {});

    final key = fakeAcpKey(providerId: AcpBuiltinProviderIds.pi);
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          key: key,
          providerLabel: 'Pi',
          configOptions: const [
            AcpSelectConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'anthropic/claude-sonnet',
              options: [
                AcpConfigValue(
                  value: 'anthropic/claude-sonnet',
                  name: 'anthropic/Claude Sonnet',
                ),
                AcpConfigValue(value: 'openai/gpt-5', name: 'openai/GPT-5'),
                AcpConfigValue(
                  value: 'google/gemini-pro',
                  name: 'google/Gemini Pro',
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        manager,
        routeKey: key,
        hasActiveSshSession: true,
        sftpClient: sftp,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Model:'));
    await tester.pumpAndSettle();
    expect(find.text('Scoped models'), findsOneWidget);
    expect(find.text('anthropic/Claude Sonnet'), findsOneWidget);
    expect(find.text('openai/GPT-5'), findsNothing);
    expect(find.text('google/Gemini Pro'), findsNothing);

    await tester.tap(find.text('Show all models'));
    await tester.pumpAndSettle();
    expect(find.text('All models'), findsOneWidget);
    expect(find.text('anthropic/Claude Sonnet'), findsOneWidget);
    expect(find.text('openai/GPT-5'), findsOneWidget);
    expect(find.text('google/Gemini Pro'), findsOneWidget);
  });

  testWidgets('top bar changes model, effort, and mode directly', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'model',
              name: 'Model',
              currentValue: 'sonnet',
              category: 'model',
              options: [
                AcpConfigValue(value: 'sonnet', name: 'Sonnet'),
                AcpConfigValue(value: 'opus', name: 'Opus'),
              ],
            ),
            AcpSelectConfigOption(
              id: 'effort',
              name: 'Reasoning effort',
              currentValue: 'medium',
              category: 'thought',
              options: [
                AcpConfigValue(value: 'medium', name: 'Medium'),
                AcpConfigValue(value: 'high', name: 'High'),
              ],
            ),
          ],
          modeState: const AcpSessionModeState(
            currentModeId: 'code',
            availableModes: [
              AcpSessionMode(id: 'code', name: 'Code'),
              AcpSessionMode(id: 'ask', name: 'Ask'),
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(manager, embedded: true, preferredFontSize: 20),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Model: Sonnet'), findsOneWidget);
    expect(find.text('Effort: Medium'), findsOneWidget);
    expect(find.text('Mode: Code'), findsOneWidget);
    final selectorContext = tester.element(find.text('Model: Sonnet'));
    expect(MediaQuery.of(selectorContext).textScaler.scale(14), 14);
    expect(
      tester.getTopLeft(find.text('Model: Sonnet')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(AcpComposer)).dy),
    );

    await tester.tap(find.byTooltip('Change model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opus').last);
    await tester.pumpAndSettle();
    expect(manager.configOptionSets, contains(('model', 'opus')));

    await tester.tap(find.byTooltip('Change effort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    expect(manager.configOptionSets, contains(('effort', 'high')));

    await tester.tap(find.byTooltip('Change mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask').last);
    await tester.pumpAndSettle();
    expect(manager.modeSets, contains('ask'));
  });

  testWidgets('legacy thinking levels render as Effort, not Mode', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          modeState: const AcpSessionModeState(
            currentModeId: 'medium',
            availableModes: [
              AcpSessionMode(id: 'low', name: 'Low'),
              AcpSessionMode(id: 'medium', name: 'Medium'),
              AcpSessionMode(id: 'high', name: 'High'),
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('Effort: Medium'), findsOneWidget);
    expect(find.textContaining('Mode:'), findsNothing);
    await tester.tap(find.byTooltip('Change effort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    expect(manager.modeSets, contains('high'));
  });

  testWidgets('generic mode-shaped effort levels do not create a Mode pill', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'session-mode',
              name: 'Mode',
              currentValue: 'medium',
              category: 'mode',
              options: [
                AcpConfigValue(value: 'low', name: 'Low'),
                AcpConfigValue(value: 'medium', name: 'Medium'),
                AcpConfigValue(value: 'high', name: 'High'),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('Effort: Medium'), findsOneWidget);
    expect(find.textContaining('Mode:'), findsNothing);
    await tester.tap(find.byTooltip('Change effort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    expect(manager.configOptionSets, contains(('session-mode', 'high')));
  });

  testWidgets('standalone pills respect SafeArea and default/off stays Mode', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          configOptions: const [
            AcpSelectConfigOption(
              id: 'interaction-mode',
              name: 'Mode',
              currentValue: 'default',
              category: 'mode',
              options: [
                AcpConfigValue(value: 'default', name: 'Default'),
                AcpConfigValue(value: 'off', name: 'Off'),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(manager, mediaPadding: const EdgeInsets.only(bottom: 34)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mode: Default'), findsOneWidget);
    expect(find.textContaining('Effort:'), findsNothing);
    final pillSafeAreas = tester
        .widgetList<SafeArea>(
          find.ancestor(
            of: find.text('Mode: Default'),
            matching: find.byType(SafeArea),
          ),
        )
        .where((safeArea) => safeArea.bottom);
    expect(pillSafeAreas, isNotEmpty);
  });

  testWidgets('opens an inline image in a sized interactive viewer', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
        'AAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    final session = fakeAcpSession(
      timeline: AcpTimeline(
        entries: [
          AcpMessageEntry(
            role: AcpMessageRole.user,
            order: 0,
            content: const [AcpImageContent(data: png, mimeType: 'image/png')],
          ),
        ],
      ),
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    final inlineImage = tester.widget<AcpInlineImage>(
      find.byType(AcpInlineImage),
    );
    inlineImage.onTap!(inlineImage.image);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    final interactive = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    expect(interactive.minScale, 0.5);
    expect(interactive.maxScale, 8);
    expect(interactive.panEnabled, isTrue);
    expect(interactive.scaleEnabled, isTrue);
    expect(interactive.clipBehavior, Clip.none);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, Colors.black);
    final viewerImage = tester
        .widgetList<AcpInlineImage>(find.byType(AcpInlineImage))
        .last;
    expect(viewerImage.showFrame, isFalse);
    expect(find.byTooltip('Close image'), findsOneWidget);
    final viewerSize = tester.getSize(
      find.byKey(const ValueKey('acp-image-viewer')),
    );
    expect(viewerSize.width, greaterThan(0));
    expect(viewerSize.height, greaterThan(0));
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('renders a persistent session rail on wide layouts', (
    tester,
  ) async {
    final session = fakeAcpSession();
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        size: const Size(1100, 800),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('sessions'), findsOneWidget);
    expect(find.text('ready when you are'), findsOneWidget);
  });

  testWidgets('shows inline recovery when a live session fails', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [fakeAcpSession(status: AcpConnectionStatus.failed)],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.text('agent connection failed'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reconnect'), findsOneWidget);
  });

  testWidgets('adopts the replacement bridge key after resuming an expired '
      'bridge', (tester) async {
    final oldKey = fakeAcpKey(bridgeId: 'expired-bridge');
    final resumedKey = fakeAcpKey(bridgeId: 'replacement-bridge');
    final now = DateTime(2026);
    final resumedSession = fakeAcpSession(
      key: resumedKey,
      timeline: fakeAcpTimeline('Recovered session'),
    );
    final manager =
        FakeAcpSessionManager(
            recents: [
              AcpRecentSessionRef(
                hostId: oldKey.hostId,
                providerId: oldKey.providerId,
                bridgeId: oldKey.bridgeId,
                acpSessionId: oldKey.acpSessionId,
                cwd: '/repo',
                createdAt: now,
                lastActivityAt: now,
              ),
            ],
          )
          ..reconnectSessionResult = AcpSessionLaunchStarted(resumedKey)
          ..reconnectSessionState = resumedSession;

    await tester.pumpWidget(
      _wrap(manager, routeKey: oldKey, hasActiveSshSession: true),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Recovered session'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
    expect(manager.selected, contains(resumedKey.value));
    expect(manager.selected, isNot(contains(oldKey.value)));
    expect(manager.reconnects, hasLength(1));
    expect(manager.reconnects.single.bridgeId, oldKey.bridgeId);
  });

  testWidgets('surfaces a pending permission and resolves with the exact '
      'option id', (tester) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          pendingPermissions: [
            AcpPendingPermission(
              requestKey: 'req-1',
              sessionId: 'session-1',
              toolCallId: 'tool-1',
              options: const [
                AcpPermissionOption(
                  id: 'allow-1',
                  name: 'Allow once',
                  kind: AcpPermissionOptionKind.allowOnce,
                ),
              ],
              requestedAt: DateTime(2026),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.byType(AcpPermissionSurface), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);

    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(manager.permissionResponses, [('req-1', 'allow-1')]);
  });

  testWidgets('pending write offers explicit in-chat content review', (
    tester,
  ) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          pendingWrites: [
            AcpPendingWrite(
              requestKey: 'write-1',
              sessionId: 'session-1',
              path: '/repo/lib/main.dart',
              contentByteLength: 18,
              requestedAt: DateTime(2026),
            ),
          ],
        ),
      ],
    )..pendingWriteContents['write-1'] = 'updated contents';
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.text('Write to main.dart'), findsOneWidget);
    expect(find.text('updated contents'), findsNothing);
    await tester.tap(find.text('Review changes'));
    await tester.pump();
    expect(find.text('updated contents'), findsOneWidget);
  });

  testWidgets('cancelling delete keeps the remote session', (tester) async {
    final key = fakeAcpKey();
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(key: key, capabilities: fakeAcpForkCapabilities()),
      ],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete session'));
    await tester.pumpAndSettle();

    expect(find.text('Delete session?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(manager.deleted, isEmpty);
    expect(find.byType(AcpComposer), findsOneWidget);
  });

  testWidgets('a failed fork surfaces a safe error snackbar', (tester) async {
    final manager =
        FakeAcpSessionManager(
            sessions: [fakeAcpSession(capabilities: fakeAcpForkCapabilities())],
          )
          ..forkResults.add(
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Fork could not start.',
              ),
            ),
          );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    expect(manager.forkCount, 1);
    expect(find.text('Fork could not start.'), findsOneWidget);
  });

  testWidgets('a blocked fork stops the blocking session and retries after '
      'stop-and-continue', (tester) async {
    final currentKey = fakeAcpKey();
    final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
    final manager =
        FakeAcpSessionManager(
            sessions: [
              fakeAcpSession(
                key: currentKey,
                capabilities: fakeAcpForkCapabilities(),
              ),
              fakeAcpSession(key: blockingKey, title: 'Busy session'),
            ],
          )
          ..forkResults.addAll([
            AcpSessionLaunchBlocked(
              AcpConcurrencyRequiresChoice(
                blockingSessionKeys: [blockingKey.value],
              ),
            ),
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Retry failed.',
              ),
            ),
          ]);
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    // The shared concurrency choice is presented.
    expect(find.text('Stop and continue free'), findsOneWidget);
    await tester.tap(find.text('Stop and continue free'));
    await tester.pumpAndSettle();

    // The blocking session was stopped and the fork was retried.
    expect(manager.stopped, contains(blockingKey.value));
    expect(manager.forkCount, 2);
    expect(find.text('Retry failed.'), findsOneWidget);
  });

  testWidgets(
    'embedded native chat uses terminal typography without a second session rail',
    (tester) async {
      final session = fakeAcpSession(
        timeline: fakeAcpTimeline('Scaled native response'),
      );
      await tester.pumpWidget(
        _wrap(
          FakeAcpSessionManager(sessions: [session]),
          size: const Size(1100, 800),
          embedded: true,
          preferredFontSize: 20,
          preferredFontFamily: 'Roboto Mono',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('sessions'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('MonkeyMux windows'), findsNothing);
      final threadContext = tester.element(find.byType(AcpMessageThread));
      expect(
        MediaQuery.of(threadContext).textScaler.scale(14),
        closeTo(20, 0.01),
      );
      expect(
        AcpChatTypography.monoStyleOf(threadContext).fontFamily,
        contains('RobotoMono'),
      );
    },
  );

  testWidgets('pinch zoom resizes native chat and commits the font size', (
    tester,
  ) async {
    final committed = <double>[];
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Pinch-resizable response'),
    );
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        embedded: true,
        preferredFontSize: 14,
        onFontSizeCommitted: committed.add,
      ),
    );
    await tester.pumpAndSettle();

    final target = find.byType(TerminalPinchZoomGestureHandler);
    final center = tester.getCenter(target);
    final first = await tester.createGesture(pointer: 21);
    final second = await tester.createGesture(pointer: 22);
    await first.down(center - const Offset(30, 0));
    await second.down(center + const Offset(30, 0));
    await tester.pump();
    await second.moveTo(center + const Offset(60, 0));
    await tester.pump();

    expect(find.text('21 pt'), findsOneWidget);
    final threadContext = tester.element(find.byType(AcpMessageThread));
    expect(MediaQuery.of(threadContext).textScaler.scale(14), closeTo(21, 0.1));

    await first.up();
    await second.up();
    await tester.pump();
    expect(committed.single, closeTo(21, 0.1));
  });

  testWidgets('native chat shows working state and determinate plan progress', (
    tester,
  ) async {
    final session = fakeAcpSession(
      promptStatus: AcpPromptStatus.streaming,
      plan: const [
        AcpPlanEntry(
          content: 'done',
          priority: AcpPlanPriority.high,
          status: AcpPlanStatus.completed,
        ),
        AcpPlanEntry(
          content: 'next',
          priority: AcpPlanPriority.medium,
          status: AcpPlanStatus.inProgress,
        ),
      ],
      timeline: fakeAcpTimeline('Working response'),
    );
    await tester.pumpWidget(
      _wrap(FakeAcpSessionManager(sessions: [session]), embedded: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('agent is working'), findsOneWidget);
    final cursor = find.byKey(const ValueKey('acp-running-cursor'));
    expect(cursor, findsOneWidget);
    expect(find.byType(CursorBlock), findsOneWidget);
    final messageViewport = find
        .ancestor(of: cursor, matching: find.byType(Stack))
        .first;
    expect(
      tester.getBottomRight(cursor).dy,
      closeTo(
        tester.getBottomRight(messageViewport).dy - FluttyTheme.spacingMd,
        0.1,
      ),
    );
    final statusStripProgress = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .where((indicator) => indicator.minHeight == 2);
    expect(
      statusStripProgress,
      isEmpty,
      reason: 'embedded status progress belongs to terminal chrome only',
    );
  });

  testWidgets('remote selection adds a visible composer attachment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [fakeAcpSession()]),
        embedded: true,
        attachmentActionsBuilder: (_, _) => AcpComposerAttachmentActions(
          pickRemoteFiles: (_) async => [
            const AcpAttachmentCandidate.remoteFile(
              name: 'report.txt',
              remotePath: '/repo/report.txt',
              sizeBytes: 42,
              mimeType: 'text/plain',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote file (SFTP)'));
    await tester.pumpAndSettle();

    expect(find.text('report.txt'), findsOneWidget);
    expect(
      tester.widget<AcpComposer>(find.byType(AcpComposer)).useBottomSafeArea,
      isFalse,
    );
  });

  testWidgets('waiting for input takes priority over native working state', (
    tester,
  ) async {
    final session = fakeAcpSession(
      promptStatus: AcpPromptStatus.streaming,
      pendingWrites: [
        AcpPendingWrite(
          requestKey: 'write-1',
          sessionId: 'session-1',
          path: '/repo/file.dart',
          contentByteLength: 12,
          requestedAt: DateTime(2026),
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(FakeAcpSessionManager(sessions: [session]), embedded: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('waiting for input'), findsOneWidget);
    expect(find.text('agent is working'), findsNothing);
    expect(find.byType(AcpPermissionSurface), findsOneWidget);
  });

  testWidgets('two-finger tap without scaling does not pin a font override', (
    tester,
  ) async {
    final committed = <double>[];
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [fakeAcpSession()]),
        embedded: true,
        preferredFontSize: 14,
        onFontSizeCommitted: committed.add,
      ),
    );
    await tester.pumpAndSettle();

    final center = tester.getCenter(
      find.byType(TerminalPinchZoomGestureHandler),
    );
    final first = await tester.createGesture(pointer: 31);
    final second = await tester.createGesture(pointer: 32);
    await first.down(center - const Offset(30, 0));
    await second.down(center + const Offset(30, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    expect(committed, isEmpty);
  });
}
