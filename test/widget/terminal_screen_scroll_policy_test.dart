// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

TmuxWindow _window({
  required int index,
  required bool isActive,
  bool? reportsMouseWheel,
  bool? mouseReportSgr,
}) => TmuxWindow(
  index: index,
  name: 'w$index',
  isActive: isActive,
  terminalReportsMouseWheel: reportsMouseWheel,
  terminalMouseReportSgr: mouseReportSgr,
);

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
      'does not synthesize arrows for agent tools without wheel reporting',
      () {
        expect(
          shouldUseSyntheticAltBufferScrollFallback(
            isUsingAltBuffer: true,
            preferExplicitMouseReporting: true,
            terminalReportsMouseWheel: false,
            isAgentToolActive: true,
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
      'keeps mobile agent drags in the viewport when wheel reporting is off',
      () {
        expect(
          shouldRouteTouchScrollToTerminal(
            isMobile: true,
            isUsingAltBuffer: true,
            terminalReportsMouseWheel: false,
            isAgentToolActive: true,
          ),
          isFalse,
        );
      },
    );

    test('routes mobile agent drags when wheel reporting is active', () {
      expect(
        shouldRouteTouchScrollToTerminal(
          isMobile: true,
          isUsingAltBuffer: true,
          terminalReportsMouseWheel: true,
          isAgentToolActive: true,
        ),
        isTrue,
      );
    });

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

  group('terminal agent scroll context helper', () {
    test('uses startup tool before window metadata is loaded', () {
      expect(
        isAgentToolActiveForTerminalScroll(
          activeWindowTool: null,
          startupTool: AgentLaunchTool.copilotCli,
          hasWindowSnapshot: false,
        ),
        isTrue,
      );
    });

    test('prefers loaded window metadata over stale startup tool', () {
      expect(
        isAgentToolActiveForTerminalScroll(
          activeWindowTool: null,
          startupTool: AgentLaunchTool.copilotCli,
          hasWindowSnapshot: true,
        ),
        isFalse,
      );
    });

    test('detects current command while metadata catches up', () {
      expect(
        isAgentToolActiveForTerminalScroll(
          activeWindowTool: null,
          startupTool: null,
          hasWindowSnapshot: true,
          currentCommand: 'codex',
        ),
        isTrue,
      );
    });
  });

  group('terminal mux mouse mode scroll helpers', () {
    test('uses mux window mouse reporting when local mode is stale', () {
      expect(
        terminalReportsMouseWheelForScroll(
          localTerminalReportsMouseWheel: false,
          activeWindowReportsMouseWheel: true,
        ),
        isTrue,
      );
    });

    test('does not force SGR without mux SGR mode metadata', () {
      expect(
        shouldForceSgrTouchScroll(
          activeWindowReportsMouseWheel: true,
          activeWindowMouseReportSgr: false,
        ),
        isFalse,
      );
    });

    test('forces SGR when mux reports wheel and SGR modes', () {
      expect(
        shouldForceSgrTouchScroll(
          activeWindowReportsMouseWheel: true,
          activeWindowMouseReportSgr: true,
        ),
        isTrue,
      );
    });
  });

  group('active window scroll-mode signature', () {
    test('is null when no window is active', () {
      expect(
        activeTmuxWindowScrollModeSignature([
          _window(index: 0, isActive: false, reportsMouseWheel: true),
        ]),
        isNull,
      );
    });

    test('captures the active window mouse-reporting state', () {
      final signature = activeTmuxWindowScrollModeSignature([
        _window(index: 0, isActive: true, reportsMouseWheel: true),
        _window(index: 1, isActive: false, reportsMouseWheel: false),
      ]);
      expect(signature?.reportsMouseWheel, isTrue);
      expect(signature?.mouseReportSgr, isNull);
    });

    test('changes when the active window toggles mouse mode', () {
      final before = activeTmuxWindowScrollModeSignature([
        _window(index: 0, isActive: true, reportsMouseWheel: false),
      ]);
      final after = activeTmuxWindowScrollModeSignature([
        _window(index: 0, isActive: true, reportsMouseWheel: true),
      ]);
      expect(before == after, isFalse);
    });

    test('changes when the active window toggles SGR reporting', () {
      final before = activeTmuxWindowScrollModeSignature([
        _window(
          index: 0,
          isActive: true,
          reportsMouseWheel: true,
          mouseReportSgr: false,
        ),
      ]);
      final after = activeTmuxWindowScrollModeSignature([
        _window(
          index: 0,
          isActive: true,
          reportsMouseWheel: true,
          mouseReportSgr: true,
        ),
      ]);
      expect(before == after, isFalse);
    });

    test('ignores mouse-mode changes on non-active windows', () {
      final before = activeTmuxWindowScrollModeSignature([
        _window(index: 0, isActive: true, reportsMouseWheel: false),
        _window(index: 1, isActive: false, reportsMouseWheel: false),
      ]);
      final after = activeTmuxWindowScrollModeSignature([
        _window(index: 0, isActive: true, reportsMouseWheel: false),
        _window(index: 1, isActive: false, reportsMouseWheel: true),
      ]);
      expect(before == after, isTrue);
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
