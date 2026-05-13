// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('terminal scroll policy helpers', () {
    test(
      'simulates alt-buffer scroll on mobile when wheel reporting is off',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: false,
          ),
          isTrue,
        );
      },
    );

    test('never simulates scroll outside the alt buffer', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isUsingAltBuffer: false,
          preferExplicitMouseReporting: false,
          terminalReportsMouseWheel: false,
        ),
        isFalse,
      );
    });

    test(
      'prefers explicit mouse reporting when the terminal reports wheel input',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'falls back when explicit reporting is preferred but not active yet',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: false,
          ),
          isTrue,
        );
      },
    );

    test(
      'does not synthesize arrows for attach-owned alt buffers without wheel reporting',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: false,
            isAttachOwnedAltBuffer: true,
          ),
          isFalse,
        );
      },
    );

    test('can still opt into the synthetic fallback when desired', () {
      expect(
        shouldUseSyntheticAltBufferScrollFallback(
          isUsingAltBuffer: true,
          preferExplicitMouseReporting: false,
          terminalReportsMouseWheel: true,
        ),
        isTrue,
      );
    });
  });

  group('terminal touch scroll routing helper', () {
    test(
      'resolves active foreground agent tool from window snapshot metadata',
      () {
        expect(
          resolveTmuxBarActiveWindowTool(const [
            TmuxWindow(index: 0, name: 'shell', isActive: false),
            TmuxWindow(
              index: 1,
              name: 'flutty',
              isActive: true,
              paneTitle: 'flutty',
              agentTool: AgentLaunchTool.codex,
            ),
          ]),
          AgentLaunchTool.codex,
        );
      },
    );

    test('routes mobile alt-buffer drags into terminal scroll input', () {
      expect(
        shouldRouteTouchScrollToTerminal(
          isMobile: true,
          isUsingAltBuffer: true,
          terminalReportsMouseWheel: false,
        ),
        isTrue,
      );
    });

    test(
      'routes mobile attach-owned fullscreen alt buffers into terminal scroll input',
      () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: false,
            isAttachOwnedAltBuffer: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps mobile attach-owned inline buffers viewport-scrollable with wheel reporting',
      () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: false,
            terminalReportsMouseWheel: true,
            isAttachOwnedAltBuffer: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'routes mobile attach-owned alt buffers when the app reports mouse wheel',
      () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: true,
            isAttachOwnedAltBuffer: true,
          ),
          isTrue,
        );
      },
    );

    test('routes mobile mouse-reporting apps into terminal scroll input', () {
      expect(
        shouldRouteTouchScrollToTerminal(
          isMobile: true,
          isUsingAltBuffer: false,
          terminalReportsMouseWheel: true,
        ),
        isTrue,
      );
    });

    test('keeps plain mobile shell output scrollable in the viewport', () {
      expect(
        shouldRouteTouchScrollToTerminal(
          isMobile: true,
          isUsingAltBuffer: false,
          terminalReportsMouseWheel: false,
        ),
        isFalse,
      );
    });
  });

  group('terminal output follow helpers', () {
    test('follows output when no scroll clients are attached yet', () {
      expect(
        shouldFollowTerminalOutput(
          hasScrollClients: false,
          currentOffset: 0,
          maxScrollExtent: 0,
        ),
        isTrue,
      );
    });

    test('keeps following when already at the bottom', () {
      expect(
        shouldFollowTerminalOutput(
          hasScrollClients: true,
          currentOffset: 99.5,
          maxScrollExtent: 100,
        ),
        isTrue,
      );
    });

    test(
      'stops following when the viewport is scrolled away from the bottom',
      () {
        expect(
          shouldFollowTerminalOutput(
            hasScrollClients: true,
            currentOffset: 72,
            maxScrollExtent: 100,
          ),
          isFalse,
        );
      },
    );

    test('auto-resumes attach-owned agent TUI scrollback', () {
      expect(
        shouldAutoResumeAttachOwnedTerminalOutputFollow(
          isAttachOwnedAltBuffer: true,
          hasForegroundAgentTool: true,
          tuiSignalingActive: false,
        ),
        isTrue,
      );
    });

    test('auto-resumes attach-owned TUI-signaling scrollback', () {
      expect(
        shouldAutoResumeAttachOwnedTerminalOutputFollow(
          isAttachOwnedAltBuffer: true,
          hasForegroundAgentTool: false,
          tuiSignalingActive: true,
        ),
        isTrue,
      );
    });

    test('does not auto-resume plain attach-owned shell scrollback', () {
      expect(
        shouldAutoResumeAttachOwnedTerminalOutputFollow(
          isAttachOwnedAltBuffer: true,
          hasForegroundAgentTool: false,
          tuiSignalingActive: false,
        ),
        isFalse,
      );
    });

    test('does not auto-resume non-MonkeyMux terminal scrollback', () {
      expect(
        shouldAutoResumeAttachOwnedTerminalOutputFollow(
          isAttachOwnedAltBuffer: false,
          hasForegroundAgentTool: true,
          tuiSignalingActive: true,
        ),
        isFalse,
      );
    });

    test('does not timer-resume attach-owned inline agent scrollback', () {
      expect(
        shouldAutoResumeAttachOwnedTerminalOutputFollow(
          isAttachOwnedAltBuffer: false,
          hasForegroundAgentTool: true,
          tuiSignalingActive: false,
        ),
        isFalse,
      );
    });

    test('live output resumes attach-owned TUI follow when paused', () {
      expect(
        shouldResumeAttachOwnedTerminalFollowOnLiveOutput(
          shouldFollowLiveOutput: false,
          isAttachOwnedTerminal: true,
          hasForegroundAgentTool: true,
          tuiSignalingActive: false,
          isTerminalOutputFollowPaused: false,
        ),
        isTrue,
      );
    });

    test('live output keeps an already-following viewport unchanged', () {
      expect(
        shouldResumeAttachOwnedTerminalFollowOnLiveOutput(
          shouldFollowLiveOutput: true,
          isAttachOwnedTerminal: true,
          hasForegroundAgentTool: true,
          tuiSignalingActive: false,
          isTerminalOutputFollowPaused: false,
        ),
        isFalse,
      );
    });

    test('live output does not resume ordinary terminal scrollback', () {
      expect(
        shouldResumeAttachOwnedTerminalFollowOnLiveOutput(
          shouldFollowLiveOutput: false,
          isAttachOwnedTerminal: false,
          hasForegroundAgentTool: true,
          tuiSignalingActive: true,
          isTerminalOutputFollowPaused: false,
        ),
        isFalse,
      );
    });

    test('live output waits while touch scrolling is paused', () {
      expect(
        shouldResumeAttachOwnedTerminalFollowOnLiveOutput(
          shouldFollowLiveOutput: false,
          isAttachOwnedTerminal: true,
          hasForegroundAgentTool: true,
          tuiSignalingActive: false,
          isTerminalOutputFollowPaused: true,
        ),
        isFalse,
      );
    });
  });

  group('terminal scroll policy change helper', () {
    test('rebuilds when alt-buffer usage changes', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: false,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: false,
          nextReportsMouseWheel: false,
        ),
        isTrue,
      );
    });

    test('rebuilds when mouse-wheel reporting changes', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: true,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: false,
          nextReportsMouseWheel: true,
        ),
        isTrue,
      );
    });

    test('does not rebuild when scroll policy inputs are unchanged', () {
      expect(
        didTerminalScrollPolicyChange(
          previousIsUsingAltBuffer: true,
          nextIsUsingAltBuffer: true,
          previousReportsMouseWheel: true,
          nextReportsMouseWheel: true,
        ),
        isFalse,
      );
    });
  });
}
