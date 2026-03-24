// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/domain/services/terminal_hyperlink_tracker.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

const _terminalLink = 'https://github.com/features/copilot';
const _hiddenTerminalLink = 'https://github.com/orgs/community/discussions/1';
const _hiddenTerminalLabel = 'Community CLI docs';

class _TerminalTouchInteractionsHarness extends StatefulWidget {
  const _TerminalTouchInteractionsHarness({super.key});

  @override
  State<_TerminalTouchInteractionsHarness> createState() =>
      _TerminalTouchInteractionsHarnessState();
}

class _TerminalTouchInteractionsHarnessState
    extends State<_TerminalTouchInteractionsHarness> {
  final _terminalViewKey = GlobalKey<MonkeyTerminalViewState>();
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  final _openedLinks = ValueNotifier<List<String>>(<String>[]);
  final _emittedOutput = <String>[];
  final _hyperlinkTracker = TerminalHyperlinkTracker();
  bool _showsSelectionOverlay = false;

  List<String> get openedLinks => _openedLinks.value;

  String get emittedOutput => _emittedOutput.join();

  Offset? get selectionTapOffset => _cellCenter(const CellOffset(2, 0));

  Offset? get linkTapOffset {
    const linkColumn = 8;
    return _cellCenter(const CellOffset(linkColumn, 0));
  }

  Offset? get hiddenLinkTapOffset {
    const linkColumn = 2;
    return _cellCenter(const CellOffset(linkColumn, 1));
  }

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 200)
      ..setMouseMode(MouseMode.upDownScroll)
      ..setMouseReportMode(MouseReportMode.sgr)
      ..onPrivateOSC = _hyperlinkTracker.handlePrivateOsc
      ..onOutput = _emittedOutput.add;
    _hyperlinkTracker.attach(_terminal);
    _terminal
      ..write('Copilot $_terminalLink\r\n')
      ..write(
        '\u001b]8;;$_hiddenTerminalLink\u0007'
        '$_hiddenTerminalLabel'
        '\u001b]8;;\u0007',
      );
    _terminalController = TerminalController()..addListener(_handleSelection);
  }

  @override
  void dispose() {
    _terminalController
      ..removeListener(_handleSelection)
      ..dispose();
    _openedLinks.dispose();
    super.dispose();
  }

  void _handleSelection() {
    final nextShowsSelectionOverlay = _terminalController.selection != null;
    if (_showsSelectionOverlay == nextShowsSelectionOverlay) {
      return;
    }
    setState(() {
      _showsSelectionOverlay = nextShowsSelectionOverlay;
    });
  }

  String? _resolveLinkTap(CellOffset offset) {
    final trackedHyperlink = _hyperlinkTracker.resolveLinkAt(offset);
    if (trackedHyperlink != null) {
      return trackedHyperlink;
    }

    if (offset.y != 0) {
      return null;
    }

    final lineText = trimTerminalLinePadding(
      _terminal.buffer.lines[0].getText(0, _terminal.buffer.viewWidth),
    );
    if (lineText.isEmpty) {
      return null;
    }

    final textOffset = offset.x.clamp(0, lineText.length);
    return detectTerminalLinkAtTextOffset(lineText, textOffset)?.uri.toString();
  }

  void _handleLinkTap(String link) {
    _openedLinks.value = [..._openedLinks.value, link];
  }

  Offset? _cellCenter(CellOffset cellOffset) {
    final terminalViewState = _terminalViewKey.currentState;
    if (terminalViewState == null) {
      return null;
    }

    final renderTerminal = terminalViewState.renderTerminal;
    final localOffset =
        renderTerminal.getOffset(cellOffset) +
        renderTerminal.cellSize.center(Offset.zero);
    return renderTerminal.localToGlobal(localOffset);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: SizedBox(
              width: 430,
              height: 280,
              child: MonkeyTerminalView(
                key: _terminalViewKey,
                _terminal,
                controller: _terminalController,
                hardwareKeyboardOnly: true,
                touchScrollToTerminal: true,
                resolveLinkTap: _resolveLinkTap,
                onLinkTap: _handleLinkTap,
              ),
            ),
          ),
          if (_showsSelectionOverlay)
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  key: ValueKey('selection-overlay'),
                  color: Color(0x11007AFF),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ValueListenableBuilder<List<String>>(
              valueListenable: _openedLinks,
              builder: (context, value, _) => Text(
                value.join(','),
                key: const ValueKey('opened-links'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _pumpHarness(
  WidgetTester tester,
  GlobalKey<_TerminalTouchInteractionsHarnessState> harnessKey,
) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_TerminalTouchInteractionsHarness(key: harnessKey));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('vertical drags still emit tmux-style wheel input', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_TerminalTouchInteractionsHarnessState>();
    await _pumpHarness(tester, harnessKey);

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(harnessKey.currentState!.emittedOutput, contains('\x1b[<65;'));
  });

  testWidgets('long press reveals the selection overlay in touch-scroll mode', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_TerminalTouchInteractionsHarnessState>();
    await _pumpHarness(tester, harnessKey);

    final selectionTapOffset = harnessKey.currentState!.selectionTapOffset;
    expect(selectionTapOffset, isNotNull);

    await tester.longPressAt(selectionTapOffset!);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('selection-overlay')), findsOneWidget);
  });

  testWidgets(
    'tapping a terminal link opens it instead of sending mouse input',
    (tester) async {
      final harnessKey = GlobalKey<_TerminalTouchInteractionsHarnessState>();
      await _pumpHarness(tester, harnessKey);

      final tapOffset = harnessKey.currentState!.linkTapOffset;
      expect(tapOffset, isNotNull);

      await tester.tapAt(tapOffset!);
      await tester.pumpAndSettle();

      expect(harnessKey.currentState!.openedLinks, [_terminalLink]);
      expect(harnessKey.currentState!.emittedOutput, isEmpty);
    },
  );

  testWidgets(
    'tapping a terminal hyperlink label opens its hidden destination',
    (tester) async {
      final harnessKey = GlobalKey<_TerminalTouchInteractionsHarnessState>();
      await _pumpHarness(tester, harnessKey);

      final tapOffset = harnessKey.currentState!.hiddenLinkTapOffset;
      expect(tapOffset, isNotNull);

      await tester.tapAt(tapOffset!);
      await tester.pumpAndSettle();

      expect(harnessKey.currentState!.openedLinks, [_hiddenTerminalLink]);
      expect(harnessKey.currentState!.emittedOutput, isEmpty);
    },
  );
}
