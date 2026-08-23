import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';
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

    test('native focus leaves the connection on Back', () {
      expect(resolveTerminalScreenCanPop(isTmuxBarExpanded: false), isTrue);
      expect(resolveTerminalScreenCanPop(isTmuxBarExpanded: true), isFalse);
    });

    test('native mode hides only terminal-viewport menu actions', () {
      expect(
        resolveShowTerminalViewportMenuActions(nativeAgentActive: false),
        isTrue,
      );
      expect(
        resolveShowTerminalViewportMenuActions(nativeAgentActive: true),
        isFalse,
      );
    });

    test('uses platform IME state over stale inset geometry', () {
      expect(
        resolveTerminalSystemKeyboardVisible(
          bottomInset: 300,
          platformKeyboardVisible: null,
          terminalInputConnectionVisible: false,
          nativeComposerInputOwner: true,
        ),
        isTrue,
      );
      expect(
        resolveTerminalSystemKeyboardVisible(
          bottomInset: 300,
          platformKeyboardVisible: false,
          terminalInputConnectionVisible: true,
          nativeComposerInputOwner: true,
        ),
        isFalse,
      );
      expect(
        resolveTerminalSystemKeyboardVisible(
          bottomInset: 300,
          platformKeyboardVisible: null,
          terminalInputConnectionVisible: false,
          nativeComposerInputOwner: false,
        ),
        isFalse,
      );
      expect(
        resolveTerminalSystemKeyboardVisible(
          bottomInset: 300,
          platformKeyboardVisible: true,
          terminalInputConnectionVisible: false,
          nativeComposerInputOwner: false,
        ),
        isTrue,
      );
      expect(
        resolveTerminalSystemKeyboardVisible(
          bottomInset: 0,
          platformKeyboardVisible: true,
          terminalInputConnectionVisible: true,
          nativeComposerInputOwner: true,
        ),
        isFalse,
      );
    });

    test('moves tmux controls to a sidebar only when width allows it', () {
      const breakpoint = tmuxSidebarExpandedWidth + tmuxSidebarMinTerminalWidth;

      expect(
        resolveTmuxBarPlacement(breakpoint - 1),
        TmuxBarPlacement.bottomOverlay,
      );
      expect(resolveTmuxBarPlacement(breakpoint), TmuxBarPlacement.sidebar);
      expect(
        resolveTmuxBarPlacement(double.infinity),
        TmuxBarPlacement.bottomOverlay,
      );
      expect(tmuxSidebarCollapsedWidth, lessThan(tmuxSidebarExpandedWidth));
      expect(
        resolveTmuxSidebarWidth(isExpanded: false, dragOffset: 40),
        tmuxSidebarCollapsedWidth + 40,
      );
      expect(
        resolveTmuxSidebarWidth(isExpanded: false, dragOffset: 400),
        tmuxSidebarExpandedWidth,
      );
      expect(
        resolveTmuxSidebarWidth(isExpanded: true, dragOffset: -40),
        tmuxSidebarExpandedWidth - 40,
      );
      expect(
        resolveTmuxSidebarWidth(isExpanded: true, dragOffset: -400),
        tmuxSidebarCollapsedWidth,
      );
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

    test('formats detected remote multiplexer versions', () {
      expect(
        formatRemoteMuxVersionLabel(RemoteMuxBackend.monkeyMux, '0.2.4'),
        'MonkeyMux 0.2.4',
      );
      expect(
        formatRemoteMuxVersionLabel(RemoteMuxBackend.tmux, '3.4'),
        'tmux 3.4',
      );
      expect(
        formatRemoteMuxVersionLabel(RemoteMuxBackend.tmux, 'tmux next-3.5'),
        'tmux next-3.5',
      );
      expect(
        formatRemoteMuxVersionLabel(RemoteMuxBackend.monkeyMux, '  '),
        isNull,
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

    test('uses the live agent session title as the handle primary value', () {
      const windows = <TmuxWindow>[
        TmuxWindow(
          index: 1,
          name: 'copilot',
          isActive: true,
          currentCommand: 'copilot',
          paneTitle: 'Editing main.dart',
          activeAgentSessionId: 'session-1',
          agentSessionTitle: 'Fix tmux session labels',
        ),
      ];

      expect(
        resolveTmuxBarActiveWindowTitle(windows),
        'Fix tmux session labels',
      );
      expect(
        resolveTmuxBarHandleLabel(
          'workspace',
          activeWindowTitle: resolveTmuxBarActiveWindowTitle(windows),
        ),
        'workspace · Fix tmux session labels',
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
          Duration(milliseconds: 2800),
          Duration(milliseconds: 5600),
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
          hadConfirmedTmuxState: true,
          confirmedTmuxActive: false,
          hadDetectionFailure: true,
        ),
        isTrue,
      );
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadConfirmedTmuxState: true,
          confirmedTmuxActive: false,
          hadDetectionFailure: false,
        ),
        isFalse,
      );
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadConfirmedTmuxState: false,
          confirmedTmuxActive: false,
          hadDetectionFailure: true,
        ),
        isFalse,
        reason:
            'a bar whose client ownership was never confirmed for this SSH '
            'connection must not survive a failed probe',
      );
    });

    test('preserves MonkeyMux chrome only for bounded attach churn', () {
      expect(
        shouldPreserveMonkeyMuxChromeAfterAttachProbe(
          backend: RemoteMuxBackend.monkeyMux,
          serverReplacementPending: true,
          nativeAgentActive: false,
          attachEstablished: false,
          consecutiveFalseProbes: 20,
        ),
        isTrue,
      );
      expect(
        shouldPreserveMonkeyMuxChromeAfterAttachProbe(
          backend: RemoteMuxBackend.monkeyMux,
          serverReplacementPending: false,
          nativeAgentActive: true,
          attachEstablished: true,
          consecutiveFalseProbes: 3,
        ),
        isTrue,
      );
      expect(
        shouldPreserveMonkeyMuxChromeAfterAttachProbe(
          backend: RemoteMuxBackend.monkeyMux,
          serverReplacementPending: false,
          nativeAgentActive: true,
          attachEstablished: true,
          consecutiveFalseProbes: 4,
        ),
        isFalse,
      );
      expect(
        shouldPreserveMonkeyMuxChromeAfterAttachProbe(
          backend: RemoteMuxBackend.tmux,
          serverReplacementPending: true,
          nativeAgentActive: true,
          attachEstablished: true,
          consecutiveFalseProbes: 1,
        ),
        isFalse,
      );
    });

    test(
      'terminal theme view-ready retries are bounded and skip native UI',
      () {
        expect(
          shouldRetryTerminalThemeWhenViewMounts(
            nativeAgentActive: false,
            routeIsCurrent: true,
            attempt: 2,
          ),
          isTrue,
        );
        expect(
          shouldRetryTerminalThemeWhenViewMounts(
            nativeAgentActive: false,
            routeIsCurrent: true,
            attempt: 3,
          ),
          isFalse,
        );
        expect(
          shouldRetryTerminalThemeWhenViewMounts(
            nativeAgentActive: true,
            routeIsCurrent: true,
            attempt: 0,
          ),
          isFalse,
        );
        expect(
          shouldRetryTerminalThemeWhenViewMounts(
            nativeAgentActive: false,
            routeIsCurrent: false,
            attempt: 0,
          ),
          isFalse,
        );
      },
    );

    test('preserves tmux state after tmux is confirmed active', () {
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadConfirmedTmuxState: false,
          confirmedTmuxActive: true,
          hadDetectionFailure: false,
        ),
        isTrue,
      );
    });

    test('primes configured tmux state while detection is pending', () {
      expect(
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: 'MonkeySSH',
          hasExistingVisibleTmuxState: false,
          mayPreserveExistingTmuxState: false,
          isReopeningExistingTerminal: true,
        ),
        isTrue,
      );
      expect(
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: 'MonkeySSH',
          hasExistingVisibleTmuxState: false,
          mayPreserveExistingTmuxState: false,
          isReopeningExistingTerminal: false,
        ),
        isFalse,
      );
      expect(
        shouldPreserveTerminalTmuxStateAfterDetectionFailure(
          preserveExistingTmuxState: false,
          hadConfirmedTmuxState: false,
          confirmedTmuxActive: false,
          hadDetectionFailure: true,
        ),
        isFalse,
        reason:
            'primed state has no confirmed client for this SSH connection yet, '
            'so a failed probe must hide the bar',
      );
      expect(
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: null,
          hasExistingVisibleTmuxState: false,
          mayPreserveExistingTmuxState: false,
          isReopeningExistingTerminal: true,
        ),
        isFalse,
      );
      expect(
        shouldPrimeTerminalTmuxStateWhileDetecting(
          candidateSessionName: 'MonkeySSH',
          hasExistingVisibleTmuxState: false,
          mayPreserveExistingTmuxState: false,
          isReopeningExistingTerminal: false,
        ),
        isFalse,
      );
    });

    test('keeps verifying the existing tmux session without a preference', () {
      expect(
        resolveTmuxDetectionCandidateSessionName(existingSessionName: ' work '),
        'work',
      );
      expect(
        resolveTmuxDetectionCandidateSessionName(
          preferredSessionName: ' configured ',
          existingSessionName: 'work',
        ),
        'configured',
      );
      expect(
        resolveTmuxDetectionCandidateSessionName(
          preferredSessionName: ' ',
          existingSessionName: '',
        ),
        isNull,
      );
    });

    test('ignores existing tmux sessions from other SSH connections', () {
      expect(
        resolveOwnedTmuxDetectionExistingSessionName(
          sessionConnectionId: 2,
          tmuxStateConnectionId: 1,
          existingSessionName: 'work',
        ),
        isNull,
      );
      expect(
        resolveOwnedTmuxDetectionExistingSessionName(
          sessionConnectionId: 2,
          tmuxStateConnectionId: 2,
          existingSessionName: ' work ',
        ),
        'work',
      );
    });

    test('preserves tmux bar snapshots during same-session recovery', () {
      expect(
        shouldPreserveTmuxBarSnapshotOnUpdate(
          sessionChanged: false,
          backendChanged: false,
          recoveryChanged: true,
        ),
        isTrue,
      );
      expect(
        shouldPreserveTmuxBarSnapshotOnUpdate(
          sessionChanged: true,
          backendChanged: false,
          recoveryChanged: true,
        ),
        isFalse,
      );
      expect(
        shouldPreserveTmuxBarSnapshotOnUpdate(
          sessionChanged: false,
          backendChanged: true,
          recoveryChanged: true,
        ),
        isFalse,
      );
      expect(
        shouldPreserveTmuxBarSnapshotOnUpdate(
          sessionChanged: false,
          backendChanged: false,
          recoveryChanged: false,
        ),
        isFalse,
      );
    });

    test('defaults missing remote mux backend to automatic startup', () {
      expect(resolveRemoteMuxStartupBackend(null), RemoteMuxBackend.auto);
      expect(resolveRemoteMuxStartupBackend(''), RemoteMuxBackend.auto);
      expect(
        resolveRemoteMuxStartupBackend(RemoteMuxBackend.tmux.storageValue),
        RemoteMuxBackend.tmux,
      );
      expect(
        resolveRemoteMuxStartupBackend(RemoteMuxBackend.monkeyMux.storageValue),
        RemoteMuxBackend.monkeyMux,
      );
      expect(
        resolveRemoteMuxStartupBackend(null, tmuxExtraFlags: '-S /tmp/tmux'),
        RemoteMuxBackend.tmux,
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

    test('prefers explicit and configured directories for new windows', () {
      expect(
        resolveTmuxWindowWorkingDirectory(
          explicitWorkingDirectory: '/tmp/explicit',
          configuredWorkingDirectory: '/tmp/configured',
          launchWorkingDirectory: '/tmp/launch',
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
        ),
        '/tmp/explicit',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(
          configuredWorkingDirectory: '/tmp/configured',
          launchWorkingDirectory: '/tmp/launch',
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
        ),
        '/tmp/configured',
      );
    });

    test('new native windows use the host connection directory', () {
      expect(
        resolveNativeAcpNewWindowWorkingDirectory(
          connectionWorkingDirectory: ' /host/connection ',
          launchWorkingDirectory: '/host/launch',
          hostWorkingDirectory: '/host/configured',
        ),
        '/host/connection',
      );
      expect(
        resolveNativeAcpNewWindowWorkingDirectory(
          launchWorkingDirectory: '/host/launch',
          hostWorkingDirectory: '/host/configured',
        ),
        '/host/launch',
      );
      expect(
        resolveNativeAcpNewWindowWorkingDirectory(
          hostWorkingDirectory: '/host/configured',
        ),
        '/host/configured',
      );
      expect(resolveNativeAcpNewWindowWorkingDirectory(), '~');
    });

    test('falls back through launch, active, and observed directories', () {
      expect(
        resolveTmuxWindowWorkingDirectory(
          launchWorkingDirectory: '/tmp/launch',
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
        ),
        '/tmp/launch',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(
          currentPaneWorkingDirectory: '/tmp/current',
          observedWorkingDirectory: '/tmp/observed',
        ),
        '/tmp/current',
      );
      expect(
        resolveTmuxWindowWorkingDirectory(
          observedWorkingDirectory: '/tmp/observed',
        ),
        '/tmp/observed',
      );
      expect(resolveTmuxWindowWorkingDirectory(), isNull);
    });

    test('uses a matching agent preset before the host mux directory', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.copilotCli,
        workingDirectory: '/tmp/agent',
        tmuxSessionName: 'agents',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
      );

      expect(
        resolveConfiguredMuxWorkingDirectory(
          agentPreset: preset,
          backend: RemoteMuxBackend.monkeyMux,
          sessionName: 'agents',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/agent',
      );
      expect(
        resolveConfiguredMuxWorkingDirectory(
          agentPreset: preset,
          backend: RemoteMuxBackend.monkeyMux,
          sessionName: 'other',
          hostWorkingDirectory: '/tmp/host',
        ),
        '/tmp/host',
      );
    });

    test('reopens only an established lost MonkeyMux attach', () {
      expect(
        shouldReopenLostMonkeyMuxAttach(
          backend: RemoteMuxBackend.monkeyMux,
          attachEstablished: true,
          hasForegroundClient: false,
        ),
        isTrue,
      );
      expect(
        shouldReopenLostMonkeyMuxAttach(
          backend: RemoteMuxBackend.monkeyMux,
          attachEstablished: false,
          hasForegroundClient: false,
        ),
        isFalse,
      );
      expect(
        shouldReopenLostMonkeyMuxAttach(
          backend: RemoteMuxBackend.tmux,
          attachEstablished: true,
          hasForegroundClient: false,
        ),
        isFalse,
      );
      expect(
        shouldReopenLostMonkeyMuxAttach(
          backend: RemoteMuxBackend.monkeyMux,
          attachEstablished: true,
          hasForegroundClient: true,
        ),
        isFalse,
      );
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
        isFalse,
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
        isFalse,
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

    test('identifies shell-like tmux foreground commands for completions', () {
      expect(isShellCompletionTmuxShellCommand('zsh'), isTrue);
      expect(isShellCompletionTmuxShellCommand('/bin/bash'), isTrue);
      expect(isShellCompletionTmuxShellCommand('-fish'), isTrue);
      expect(isShellCompletionTmuxShellCommand('cmd.exe'), isTrue);
      expect(
        isShellCompletionTmuxShellCommand(
          r'C:\Windows\System32\WindowsPowerShell\v1.0\PowerShell.EXE',
        ),
        isTrue,
      );
      expect(isShellCompletionTmuxShellCommand('vim'), isFalse);
      expect(isShellCompletionTmuxShellCommand(null), isFalse);
    });

    test('allows shell completion triggers inside active tmux alt buffer', () {
      expect(
        canTerminalOutputTriggerShellCompletion(
          output: 'g',
          isUsingAltBuffer: true,
          isTmuxActive: true,
          showsNativeSelectionOverlay: false,
        ),
        isTrue,
      );
      expect(
        canTerminalOutputTriggerShellCompletion(
          output: 'g',
          isUsingAltBuffer: true,
          isTmuxActive: false,
          showsNativeSelectionOverlay: false,
        ),
        isFalse,
      );
      expect(
        canTerminalOutputTriggerShellCompletion(
          output: '\r',
          isUsingAltBuffer: true,
          isTmuxActive: true,
          showsNativeSelectionOverlay: false,
        ),
        isFalse,
      );
    });

    test('allows completions only in shell prompt contexts', () {
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.prompt,
          isTmuxActive: false,
          tmuxCurrentCommand: null,
        ),
        isTrue,
      );
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.editingCommand,
          isTmuxActive: false,
          tmuxCurrentCommand: null,
        ),
        isTrue,
      );
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.runningCommand,
          isTmuxActive: false,
          tmuxCurrentCommand: null,
        ),
        isFalse,
      );
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.runningCommand,
          isTmuxActive: true,
          tmuxCurrentCommand: 'zsh',
        ),
        isTrue,
      );
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.prompt,
          isTmuxActive: true,
          tmuxCurrentCommand: 'codex',
        ),
        isFalse,
      );
      expect(
        isShellCompletionPromptContext(
          shellStatus: TerminalShellStatus.prompt,
          isTmuxActive: true,
          tmuxCurrentCommand: null,
        ),
        isFalse,
      );
    });

    test('applies printable completion input before remote echo arrives', () {
      final snapshot = applyShellCompletionOutputToSnapshot(
        snapshot: (text: 'depoll@host % git ', cursorOffset: 18),
        output: 'c',
      );

      expect(snapshot.text, 'depoll@host % git c');
      expect(snapshot.cursorOffset, 19);
    });

    test('applies completion backspace before remote echo arrives', () {
      final snapshot = applyShellCompletionOutputToSnapshot(
        snapshot: (text: 'depoll@host % git c', cursorOffset: 19),
        output: '\x7F',
      );

      expect(snapshot.text, 'depoll@host % git ');
      expect(snapshot.cursorOffset, 18);
    });

    test('uses compact terminal-sized shell completion rows', () {
      expect(resolveShellCompletionPopupRowHeight(14), 28);
      expect(resolveShellCompletionPopupRowHeight(20), 35);
    });

    test('places shell completion popup above a low cursor line', () {
      final layout = resolveShellCompletionPopupLayout(
        overlaySize: const Size(400, 600),
        anchor: const Rect.fromLTWH(100, 550, 10, 20),
        suggestionCount: 5,
        rowHeight: 28,
      );

      expect(layout.maxHeight, 146);
      expect(layout.top + layout.maxHeight, lessThanOrEqualTo(546));
    });

    test('places shell completion popup below a high cursor line', () {
      final layout = resolveShellCompletionPopupLayout(
        overlaySize: const Size(400, 600),
        anchor: const Rect.fromLTWH(100, 20, 10, 20),
        suggestionCount: 5,
        rowHeight: 28,
      );

      expect(layout.maxHeight, 146);
      expect(layout.top, greaterThanOrEqualTo(44));
    });

    test('shrinks shell completion popup rather than covering cursor line', () {
      final layout = resolveShellCompletionPopupLayout(
        overlaySize: const Size(400, 180),
        anchor: const Rect.fromLTWH(100, 70, 10, 20),
        suggestionCount: 5,
        rowHeight: 28,
      );

      expect(layout.top, 94);
      expect(layout.maxHeight, 78);
    });

    test(
      'rejects stale shell completion taps when token no longer matches',
      () {
        const originalInvocation = ShellCompletionInvocation(
          commandLine: 'git c',
          cursorOffset: 5,
          token: 'c',
          tokenStart: 4,
          mode: ShellCompletionMode.argument,
          commandName: 'git',
          workingDirectory: '/repo',
        );
        const suggestion = ShellCompletionSuggestion(
          label: 'checkout',
          replacement: 'checkout',
          replacementStart: 4,
          replacementEnd: 5,
          kind: ShellCompletionSuggestionKind.file,
        );

        expect(
          shouldAcceptShellCompletionSuggestion(
            originalInvocation: originalInvocation,
            currentInvocation: const ShellCompletionInvocation(
              commandLine: 'git ch',
              cursorOffset: 6,
              token: 'ch',
              tokenStart: 4,
              mode: ShellCompletionMode.argument,
              commandName: 'git',
              workingDirectory: '/repo',
            ),
            suggestion: suggestion,
          ),
          isTrue,
        );
        expect(
          shouldAcceptShellCompletionSuggestion(
            originalInvocation: originalInvocation,
            currentInvocation: const ShellCompletionInvocation(
              commandLine: 'git cx',
              cursorOffset: 6,
              token: 'cx',
              tokenStart: 4,
              mode: ShellCompletionMode.argument,
              commandName: 'git',
              workingDirectory: '/repo',
            ),
            suggestion: suggestion,
          ),
          isFalse,
        );
        expect(
          shouldAcceptShellCompletionSuggestion(
            originalInvocation: originalInvocation,
            currentInvocation: null,
            suggestion: suggestion,
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps visible command completions as typing reaches the suggestion',
      () {
        const originalInvocation = ShellCompletionInvocation(
          commandLine: 'br',
          cursorOffset: 2,
          token: 'br',
          tokenStart: 0,
          mode: ShellCompletionMode.command,
          workingDirectory: '/repo',
        );
        const brewSuggestion = ShellCompletionSuggestion(
          label: 'brew',
          replacement: 'brew',
          replacementStart: 0,
          replacementEnd: 2,
          kind: ShellCompletionSuggestionKind.command,
          commitSuffix: ' ',
        );
        const brootSuggestion = ShellCompletionSuggestion(
          label: 'broot',
          replacement: 'broot',
          replacementStart: 0,
          replacementEnd: 2,
          kind: ShellCompletionSuggestionKind.command,
          commitSuffix: ' ',
        );

        final filtered = filterShellCompletionSuggestionsForCurrentInput(
          originalInvocation: originalInvocation,
          currentInvocation: const ShellCompletionInvocation(
            commandLine: 'brew',
            cursorOffset: 4,
            token: 'brew',
            tokenStart: 0,
            mode: ShellCompletionMode.command,
            workingDirectory: '/repo',
          ),
          suggestions: const <ShellCompletionSuggestion>[
            brewSuggestion,
            brootSuggestion,
          ],
        );

        expect(filtered, [brewSuggestion]);
      },
    );

    test('accepts and filters empty-token argument suggestions', () {
      const originalInvocation = ShellCompletionInvocation(
        commandLine: 'tmux ',
        cursorOffset: 5,
        token: '',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        workingDirectory: '/repo',
      );
      const attachSuggestion = ShellCompletionSuggestion(
        label: 'tmux attach',
        replacement: 'attach',
        replacementStart: 5,
        replacementEnd: 5,
        kind: ShellCompletionSuggestionKind.command,
        commitSuffix: ' ',
      );
      const newSuggestion = ShellCompletionSuggestion(
        label: 'tmux new',
        replacement: 'new',
        replacementStart: 5,
        replacementEnd: 5,
        kind: ShellCompletionSuggestionKind.command,
        commitSuffix: ' ',
      );

      expect(
        shouldAcceptShellCompletionSuggestion(
          originalInvocation: originalInvocation,
          currentInvocation: originalInvocation,
          suggestion: attachSuggestion,
        ),
        isTrue,
      );

      final filtered = filterShellCompletionSuggestionsForCurrentInput(
        originalInvocation: originalInvocation,
        currentInvocation: const ShellCompletionInvocation(
          commandLine: 'tmux a',
          cursorOffset: 6,
          token: 'a',
          tokenStart: 5,
          mode: ShellCompletionMode.argument,
          commandName: 'tmux',
          workingDirectory: '/repo',
        ),
        suggestions: const <ShellCompletionSuggestion>[
          attachSuggestion,
          newSuggestion,
        ],
      );

      expect(filtered, [attachSuggestion]);
    });

    test('filters history suggestions across later command tokens', () {
      const originalInvocation = ShellCompletionInvocation(
        commandLine: 'git c',
        cursorOffset: 5,
        token: 'c',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        workingDirectory: '/repo',
      );
      const checkoutSuggestion = ShellCompletionSuggestion(
        label: 'git checkout feature/login',
        replacement: 'git checkout feature/login',
        replacementStart: 0,
        replacementEnd: 5,
        kind: ShellCompletionSuggestionKind.history,
      );
      const commitSuggestion = ShellCompletionSuggestion(
        label: 'commit',
        replacement: 'commit',
        replacementStart: 4,
        replacementEnd: 5,
        kind: ShellCompletionSuggestionKind.history,
        commitSuffix: ' ',
      );

      final filtered = filterShellCompletionSuggestionsForCurrentInput(
        originalInvocation: originalInvocation,
        currentInvocation: const ShellCompletionInvocation(
          commandLine: 'git checkout f',
          cursorOffset: 14,
          token: 'f',
          tokenStart: 13,
          mode: ShellCompletionMode.argument,
          commandName: 'git',
          workingDirectory: '/repo',
        ),
        suggestions: const <ShellCompletionSuggestion>[
          checkoutSuggestion,
          commitSuggestion,
        ],
      );

      expect(filtered, [checkoutSuggestion]);
      expect(
        shouldAcceptShellCompletionSuggestion(
          originalInvocation: originalInvocation,
          currentInvocation: const ShellCompletionInvocation(
            commandLine: 'git switch',
            cursorOffset: 10,
            token: 'switch',
            tokenStart: 4,
            mode: ShellCompletionMode.argument,
            commandName: 'git',
            workingDirectory: '/repo',
          ),
          suggestion: checkoutSuggestion,
        ),
        isFalse,
      );
    });

    test('keeps history pattern tokens after ignored arguments', () {
      const originalInvocation = ShellCompletionInvocation(
        commandLine: 'codex --prompt ',
        cursorOffset: 15,
        token: '',
        tokenStart: 15,
        mode: ShellCompletionMode.argument,
        commandName: 'codex',
        workingDirectory: '/repo',
      );
      const sandboxSuggestion = ShellCompletionSuggestion(
        label: '--sandbox',
        replacement: '--sandbox',
        replacementStart: 15,
        replacementEnd: 15,
        kind: ShellCompletionSuggestionKind.history,
        commitSuffix: ' ',
      );

      expect(
        shouldAcceptShellCompletionSuggestion(
          originalInvocation: originalInvocation,
          currentInvocation: const ShellCompletionInvocation(
            commandLine: 'codex --prompt "try history" --s',
            cursorOffset: 32,
            token: '--s',
            tokenStart: 29,
            mode: ShellCompletionMode.argument,
            commandName: 'codex',
            workingDirectory: '/repo',
          ),
          suggestion: sandboxSuggestion,
        ),
        isTrue,
      );
    });

    testWidgets('terminal dismiss region ignores popup taps', (tester) async {
      var dismissCount = 0;
      var popupTapCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: wrapShellCompletionDismissibleTerminal(
                    onDismiss: () => dismissCount += 1,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => popupTapCount += 1,
                    child: const SizedBox(
                      key: ValueKey('completion-popup'),
                      width: 100,
                      height: 100,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tapAt(const Offset(200, 200));
      expect(dismissCount, 1);
      expect(popupTapCount, 0);

      await tester.tapAt(const Offset(50, 50));
      expect(dismissCount, 1);
      expect(popupTapCount, 1);
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
