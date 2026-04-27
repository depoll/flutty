import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal layout helpers', () {
    test('keeps the terminal flush with the viewport edges', () {
      expect(terminalViewportPadding, EdgeInsets.zero);
      expect(terminalViewportPadding.bottom, 0);
    });

    test('positions the upsell snackbar above visible bottom chrome only', () {
      const mediaQuery = MediaQueryData(padding: EdgeInsets.only(bottom: 34));

      // Flutter's floating SnackBar already lifts above the home-indicator
      // safe area, so the margin just needs a small visual gap when there is
      // no in-body keyboard toolbar to clear.
      expect(upgradeSnackBarBottomMargin(mediaQuery), 16);
      expect(
        upgradeSnackBarBottomMargin(mediaQuery, showKeyboardToolbar: true),
        100,
      );
    });

    test('tmux bar expansion uses the available terminal height', () {
      expect(resolveTmuxBarMaxContentHeight(320), closeTo(217.6, 0.01));
      expect(resolveTmuxBarMaxContentHeight(24), 0);
      expect(
        resolveTmuxBarMaxContentHeight(0, fallbackAvailableHeight: 320),
        closeTo(217.6, 0.01),
      );
    });

    test('tmux handle keeps a full touch target', () {
      expect(tmuxHandleMinTouchExtent, greaterThanOrEqualTo(44));
    });

    test('terminal connection labels distinguish connection states', () {
      expect(
        describeTerminalConnectionState(
          SshConnectionState.disconnected,
          isConnecting: true,
        ),
        'Connecting',
      );
      expect(
        describeTerminalConnectionState(
          SshConnectionState.authenticating,
          isConnecting: false,
        ),
        'Authenticating',
      );
      expect(
        describeTerminalConnectionState(
          SshConnectionState.error,
          isConnecting: false,
        ),
        'Connection error',
      );
    });

    test('terminal identity includes remote host and session id', () {
      expect(
        formatTerminalConnectionIdentity(
          username: 'deploy',
          hostname: 'example.com',
          port: 2222,
          connectionId: 7,
        ),
        'deploy@example.com:2222 · session #7',
      );
      expect(
        formatTerminalConnectionIdentity(
          username: null,
          hostname: null,
          port: null,
          connectionId: 8,
        ),
        'session #8',
      );
    });

    test('tmux bar reveal stays aligned with terminal padding', () {
      expect(resolveTmuxBarRevealBottomOffset(0), -44);
      expect(resolveTmuxBarRevealBottomOffset(22), -22);
      expect(resolveTmuxBarRevealBottomOffset(44), 0);
      expect(resolveTmuxBarRevealBottomOffset(78), 34);

      expect(resolveTmuxBarRevealOpacity(-10), 0);
      expect(resolveTmuxBarRevealOpacity(0), 0);
      expect(resolveTmuxBarRevealOpacity(22), 0.5);
      expect(resolveTmuxBarRevealOpacity(44), 1);
      expect(resolveTmuxBarRevealOpacity(60), 1);
    });

    test('uses the active tmux window title in the handle label', () {
      const windows = <TmuxWindow>[
        TmuxWindow(
          index: 0,
          name: 'shell',
          isActive: false,
          paneTitle: 'Ignored',
        ),
        TmuxWindow(
          index: 1,
          name: 'copilot',
          isActive: true,
          currentCommand: 'copilot',
          paneTitle: '✨ Editing main.dart',
        ),
      ];

      expect(resolveTmuxBarActiveWindowTitle(windows), '✨ Editing main.dart');
      expect(
        resolveTmuxBarHandleLabel(
          'workspace',
          activeWindowTitle: resolveTmuxBarActiveWindowTitle(windows),
        ),
        'workspace · ✨ Editing main.dart',
      );
    });

    test('optimistically shows the tapped tmux window as active', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: true, paneTitle: 'Shell'),
        TmuxWindow(
          index: 1,
          name: 'copilot',
          isActive: false,
          currentCommand: 'copilot',
          paneTitle: '✨ Editing main.dart',
        ),
      ];

      final displayedWindows = resolveTmuxBarDisplayedWindows(
        windows,
        pendingSelectedWindowIndex: 1,
      );

      expect(
        resolveTmuxBarActiveWindowTitle(displayedWindows),
        '✨ Editing main.dart',
      );
      expect(
        displayedWindows
            ?.where((window) => window.isActive)
            .map((window) => window.index),
        [1],
      );
    });

    test('clears optimistic selection once tmux confirms it', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: false),
        TmuxWindow(
          index: 1,
          name: 'copilot',
          isActive: true,
          currentCommand: 'copilot',
          paneTitle: '✨ Editing main.dart',
        ),
      ];

      final displayedWindows = resolveTmuxBarDisplayedWindows(
        windows,
        pendingSelectedWindowIndex: 1,
      );

      expect(
        resolveTmuxBarActiveWindowTitle(displayedWindows),
        '✨ Editing main.dart',
      );
      expect(
        displayedWindows
            ?.where((window) => window.isActive)
            .map((window) => window.index),
        [1],
      );
      expect(
        resolveTmuxBarActiveWindowTool(displayedWindows),
        AgentLaunchTool.copilotCli,
      );
    });

    test('clears optimistic selection once tmux confirms it', () {
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: false),
        TmuxWindow(
          index: 1,
          name: 'copilot',
          isActive: true,
          currentCommand: 'copilot',
          paneTitle: '✨ Editing main.dart',
        ),
      ];

      expect(
        resolveTmuxBarPendingSelectedWindowIndex(
          windows,
          pendingSelectedWindowIndex: 1,
        ),
        isNull,
      );
    });

    test('uses the active tmux foreground tool for the handle icon', () {
      const windows = <TmuxWindow>[
        TmuxWindow(
          index: 0,
          name: 'shell',
          isActive: false,
          currentCommand: 'bash',
        ),
        TmuxWindow(
          index: 1,
          name: 'agent',
          isActive: true,
          currentCommand: 'claude',
          paneTitle: '✨ Editing main.dart',
        ),
      ];

      expect(
        resolveTmuxBarActiveWindowTool(windows),
        AgentLaunchTool.claudeCode,
      );
      expect(resolveTmuxBarActiveWindowTool(const <TmuxWindow>[]), isNull);
    });

    test('omits duplicate or blank tmux window titles in the handle label', () {
      expect(resolveTmuxBarActiveWindowTitle(const <TmuxWindow>[]), isNull);
      expect(
        resolveTmuxBarHandleLabel('workspace', activeWindowTitle: 'workspace'),
        'workspace',
      );
      expect(
        resolveTmuxBarHandleLabel('workspace', activeWindowTitle: '  '),
        'workspace',
      );
    });

    test('tmux bar stays inside visible safe insets', () {
      const portraitMediaQuery = MediaQueryData(
        size: Size(390, 844),
        padding: EdgeInsets.only(bottom: 34),
      );
      const portraitKeyboardMediaQuery = MediaQueryData(
        size: Size(390, 844),
        viewPadding: EdgeInsets.only(bottom: 34),
        viewInsets: EdgeInsets.only(bottom: 320),
      );
      const landscapeMediaQuery = MediaQueryData(
        size: Size(844, 390),
        padding: EdgeInsets.fromLTRB(44, 0, 34, 21),
      );

      expect(
        resolveTmuxBarSafeInsets(portraitMediaQuery),
        const EdgeInsets.only(bottom: 34),
      );
      expect(
        resolveTmuxBarSafeInsets(portraitKeyboardMediaQuery),
        EdgeInsets.zero,
      );
      expect(
        resolveTmuxBarSafeInsets(landscapeMediaQuery),
        const EdgeInsets.fromLTRB(44, 0, 34, 21),
      );
    });

    test(
      'tmux detection retries immediately instead of waiting two seconds',
      () {
        expect(resolveTmuxDetectionRetrySchedule(), const <Duration>[
          Duration.zero,
          Duration(milliseconds: 150),
          Duration(milliseconds: 350),
          Duration(milliseconds: 700),
          Duration(milliseconds: 1400),
        ]);
        expect(
          resolveTmuxDetectionRetrySchedule(skipDelay: true),
          const <Duration>[Duration.zero],
        );
      },
    );

    test('preserves visible tmux UI only after non-definitive detection', () {
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadVisibleOrPrimedTmuxState: true,
          confirmedTmuxActive: false,
          hadDetectionFailure: true,
        ),
        isTrue,
      );
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadVisibleOrPrimedTmuxState: true,
          confirmedTmuxActive: false,
          hadDetectionFailure: false,
        ),
        isFalse,
      );
    });

    test('preserves tmux state after tmux is confirmed active', () {
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadVisibleOrPrimedTmuxState: false,
          confirmedTmuxActive: true,
          hadDetectionFailure: false,
        ),
        isTrue,
      );
    });

    test('resolves preferred tmux session name before remote verification', () {
      expect(
        resolvePreferredTmuxSessionName(
          structuredSessionName: 'workspace',
          autoConnectCommand: 'tmux attach -t ignored',
        ),
        'workspace',
      );
      expect(
        resolvePreferredTmuxSessionName(
          autoConnectCommand: 'tmux new-session -A -s parsed-session',
        ),
        'parsed-session',
      );
      expect(resolvePreferredTmuxSessionName(), isNull);
    });

    test('prefers explicit and active tmux directories for new windows', () {
      expect(
        resolveTmuxWindowWorkingDirectory(
          explicitWorkingDirectory: '/tmp/explicit',
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
          launchWorkingDirectory: '/tmp/launch',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/explicit',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
          launchWorkingDirectory: '/tmp/launch',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/current',
      );
    });

    test('falls back through observed, launch, and host tmux directories', () {
      expect(
        resolveTmuxWindowWorkingDirectory(
          observedWorkingDirectory: '/tmp/observed',
          launchWorkingDirectory: '/tmp/launch',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/observed',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(
          launchWorkingDirectory: '/tmp/launch',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/launch',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(hostWorkingDirectory: '/tmp/host'),
        '/tmp/host',
      );
      expect(resolveTmuxWindowWorkingDirectory(), isNull);
    });

    test('reattaches tmux window actions only when tmux lost foreground', () {
      expect(
        shouldReattachTmuxAfterWindowAction(
          hasForegroundClient: true,
          shellStatus: TerminalShellStatus.prompt,
        ),
        isFalse,
      );
      expect(
        shouldReattachTmuxAfterWindowAction(
          hasForegroundClient: false,
          shellStatus: TerminalShellStatus.prompt,
        ),
        isTrue,
      );
      expect(
        shouldReattachTmuxAfterWindowAction(
          hasForegroundClient: false,
          shellStatus: TerminalShellStatus.editingCommand,
        ),
        isTrue,
      );
      expect(
        shouldReattachTmuxAfterWindowAction(
          hasForegroundClient: false,
          shellStatus: TerminalShellStatus.runningCommand,
        ),
        isFalse,
      );
      expect(
        shouldReattachTmuxAfterWindowAction(
          hasForegroundClient: false,
          shellStatus: null,
        ),
        isTrue,
      );
    });

    test('reviews terminal command insertion at shell prompts', () {
      expect(
        shouldReviewTerminalCommandInsertion(
          shellStatus: TerminalShellStatus.prompt,
          isUsingAltBuffer: false,
        ),
        isTrue,
      );
      expect(
        shouldReviewTerminalCommandInsertion(
          shellStatus: TerminalShellStatus.editingCommand,
          isUsingAltBuffer: false,
        ),
        isTrue,
      );
      expect(
        shouldReviewTerminalCommandInsertion(
          shellStatus: null,
          isUsingAltBuffer: false,
        ),
        isTrue,
      );
    });

    test('suppresses terminal command insertion review in CLI contexts', () {
      expect(
        shouldReviewTerminalCommandInsertion(
          shellStatus: TerminalShellStatus.runningCommand,
          isUsingAltBuffer: false,
        ),
        isFalse,
      );
      expect(
        shouldReviewTerminalCommandInsertion(
          shellStatus: TerminalShellStatus.prompt,
          isUsingAltBuffer: true,
        ),
        isFalse,
      );
    });
  });

  group('tmux bar safe insets vs. keyboard toolbar', () {
    testWidgets(
      'collapses to zero when the chrome below already absorbs the safe area',
      (tester) async {
        late MediaQueryData strippedMediaQuery;
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(bottom: 34),
              viewPadding: EdgeInsets.only(bottom: 34),
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Builder(
                builder: (outerContext) => Column(
                  children: [
                    Expanded(
                      child: MediaQuery.removePadding(
                        context: outerContext,
                        removeBottom: true,
                        child: Builder(
                          builder: (innerContext) {
                            strippedMediaQuery = MediaQuery.of(innerContext);
                            return const SizedBox.expand();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 84),
                  ],
                ),
              ),
            ),
          ),
        );

        // The tmux bar is positioned via resolveTmuxBarSafeInsets, which uses
        // the surrounding MediaQuery's bottom padding. When a chrome below the
        // terminal absorbs the home-indicator inset, the upper area must see
        // padding.bottom == 0 so the bar sits flush against that chrome
        // instead of floating above it.
        expect(resolveTmuxBarSafeInsets(strippedMediaQuery).bottom, 0);
        expect(
          resolveTmuxBarRevealBottomOffset(
            _tmuxExpandableBarHandleHeight +
                resolveTmuxBarSafeInsets(strippedMediaQuery).bottom,
          ),
          0,
        );
      },
    );
  });
}

const double _tmuxExpandableBarHandleHeight = tmuxHandleMinTouchExtent;
