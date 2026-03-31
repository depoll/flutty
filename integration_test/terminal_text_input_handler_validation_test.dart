import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

Duration _validationSummaryHoldDuration(int seconds) =>
    Duration(seconds: seconds);

Duration? _holdValidationSummaryDuration() {
  const seconds = int.fromEnvironment('HOLD_VALIDATION_SUMMARY_SECONDS');
  if (seconds <= 0) {
    return null;
  }
  return _validationSummaryHoldDuration(seconds);
}

({String text, int cursorOffset}) _terminalStateFromEvents(
  Iterable<String> events,
) {
  final visibleCharacters = <String>[];
  var cursorOffset = 0;
  for (final event in events) {
    var offset = 0;
    while (offset < event.length) {
      if (event.startsWith('\u001b[D', offset)) {
        if (cursorOffset > 0) {
          cursorOffset--;
        }
        offset += 3;
        continue;
      }
      if (event.startsWith('\u001b[C', offset)) {
        if (cursorOffset < visibleCharacters.length) {
          cursorOffset++;
        }
        offset += 3;
        continue;
      }

      final character = event.substring(offset).characters.first;
      offset += character.length;
      if (character == '\x7f') {
        if (cursorOffset > 0) {
          visibleCharacters.removeAt(cursorOffset - 1);
          cursorOffset--;
        }
        continue;
      }
      visibleCharacters.insert(cursorOffset, character);
      cursorOffset++;
    }
  }
  return (text: visibleCharacters.join(), cursorOffset: cursorOffset);
}

Future<void> _commitSwipeText(WidgetTester tester, String text) async {
  final selection = TextSelection.collapsed(offset: text.length);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: selection,
      composing: TextRange(
        start: _deleteDetectionMarker.length,
        end: text.length,
      ),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    TextEditingValue(text: text, selection: selection),
  );
  await tester.pump();
}

class _ValidationCase {
  const _ValidationCase({
    required this.id,
    required this.title,
    required this.expectedVisibleText,
    required this.run,
    this.resolveTextBeforeCursor,
    this.expectedRawOutput,
    this.expectedEditingText,
    this.expectedSelectionOffset,
    this.expectedTerminalCursorOffset,
  });

  final String id;
  final String title;
  final String expectedVisibleText;
  final String? expectedRawOutput;
  final String? expectedEditingText;
  final int? expectedSelectionOffset;
  final int? expectedTerminalCursorOffset;
  final String? Function()? resolveTextBeforeCursor;
  final Future<void> Function(WidgetTester tester) run;
}

class _ValidationResult {
  const _ValidationResult({
    required this.testCase,
    required this.visibleText,
    required this.rawOutput,
    required this.editingText,
    required this.selectionOffset,
    required this.terminalCursorOffset,
  });

  final _ValidationCase testCase;
  final String visibleText;
  final String rawOutput;
  final String editingText;
  final int? selectionOffset;
  final int terminalCursorOffset;

  bool get passed =>
      visibleText == testCase.expectedVisibleText &&
      (testCase.expectedRawOutput == null ||
          rawOutput == testCase.expectedRawOutput) &&
      (testCase.expectedEditingText == null ||
          editingText == testCase.expectedEditingText) &&
      (testCase.expectedSelectionOffset == null ||
          selectionOffset == testCase.expectedSelectionOffset) &&
      (testCase.expectedTerminalCursorOffset == null ||
          terminalCursorOffset == testCase.expectedTerminalCursorOffset);
}

class _ResultScreen extends StatelessWidget {
  const _ResultScreen({required this.result});

  final _ValidationResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = result.passed ? Colors.green : Colors.red;
    final rows = <Widget>[
      Text(result.testCase.title, style: theme.textTheme.headlineSmall),
      const SizedBox(height: 16),
      Text(
        result.passed ? 'PASS' : 'FAIL',
        style: theme.textTheme.headlineMedium?.copyWith(color: statusColor),
      ),
      const SizedBox(height: 24),
      _ResultRow(
        label: 'Expected visible',
        value: result.testCase.expectedVisibleText,
      ),
      _ResultRow(label: 'Actual visible', value: result.visibleText),
      _ResultRow(
        label: 'Expected raw',
        value: result.testCase.expectedRawOutput ?? '(not asserted)',
      ),
      _ResultRow(label: 'Actual raw', value: result.rawOutput),
      _ResultRow(
        label: 'Expected editing text',
        value: result.testCase.expectedEditingText ?? '(not asserted)',
      ),
      _ResultRow(label: 'Actual editing text', value: result.editingText),
      _ResultRow(
        label: 'Expected cursor',
        value:
            result.testCase.expectedSelectionOffset?.toString() ??
            '(not asserted)',
      ),
      _ResultRow(
        label: 'Actual cursor',
        value: result.selectionOffset?.toString() ?? 'null',
      ),
      _ResultRow(
        label: 'Expected terminal cursor',
        value:
            result.testCase.expectedTerminalCursorOffset?.toString() ??
            '(not asserted)',
      ),
      _ResultRow(
        label: 'Actual terminal cursor',
        value: result.terminalCursorOffset.toString(),
      ),
    ];

    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: DefaultTextStyle(
                style:
                    theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}

Future<_ValidationResult> _runCase(
  WidgetTester tester,
  _ValidationCase testCase,
) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(onOutput: terminalOutput.add);
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          resolveTextBeforeCursor: testCase.resolveTextBeforeCursor,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  await testCase.run(tester);

  final client =
      tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
  final editingValue = client.currentTextEditingValue;
  final terminalState = _terminalStateFromEvents(terminalOutput);
  final result = _ValidationResult(
    testCase: testCase,
    visibleText: terminalState.text,
    rawOutput: terminalOutput.join(),
    editingText: editingValue?.text ?? '',
    selectionOffset: editingValue?.selection.extentOffset,
    terminalCursorOffset: terminalState.cursorOffset,
  );

  await tester.pumpWidget(_ResultScreen(result: result));
  await tester.pumpAndSettle();

  focusNode.dispose();
  return result;
}

class _SummaryScreen extends StatelessWidget {
  const _SummaryScreen({required this.results});

  final List<_ValidationResult> results;

  @override
  Widget build(BuildContext context) {
    final failureCount = results.where((result) => !result.passed).length;
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Terminal text input validation summary',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    failureCount == 0
                        ? 'All cases passed'
                        : '$failureCount failing case(s)',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: failureCount == 0 ? Colors.green : Colors.red,
                    ),
                  ),
                  const SizedBox(height: 24),
                  for (final result in results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${result.passed ? 'PASS' : 'FAIL'} ${result.testCase.id}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(result.testCase.title),
                          Text(
                            'Expected raw: ${result.testCase.expectedRawOutput ?? '(n/a)'}',
                          ),
                          Text('Actual raw: ${result.rawOutput}'),
                          Text(
                            'Expected visible: ${result.testCase.expectedVisibleText}',
                          ),
                          Text('Actual visible: ${result.visibleText}'),
                          Text(
                            'Expected terminal cursor: '
                            '${result.testCase.expectedTerminalCursorOffset?.toString() ?? '(n/a)'}',
                          ),
                          Text(
                            'Actual terminal cursor: ${result.terminalCursorOffset}',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cases = <_ValidationCase>[
    _ValidationCase(
      id: '01-first-swipe-word',
      title: 'First swipe word has no leading whitespace artifact',
      expectedVisibleText: 'hello',
      expectedRawOutput: 'hello',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'hello',
      expectedSelectionOffset: 7,
      run: _runFirstSwipeWordCase,
    ),
    _ValidationCase(
      id: '02-resume-swipe-separator',
      title: 'Swipe resume preserves separator after input reset',
      expectedVisibleText: ' world',
      expectedRawOutput: ' world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          ' world',
      expectedSelectionOffset: 8,
      resolveTextBeforeCursor: _resolveTerminalTextWithoutTrailingSpace,
      run: _runResumeSwipeSeparatorCase,
    ),
    _ValidationCase(
      id: '03-no-duplicate-separator',
      title: 'Swipe resume does not duplicate separator after trailing space',
      expectedVisibleText: 'world',
      expectedRawOutput: 'world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'world',
      expectedSelectionOffset: 7,
      resolveTextBeforeCursor: _resolveTerminalTextWithTrailingSpace,
      run: _runNoDuplicateSeparatorCase,
    ),
    _ValidationCase(
      id: '04-replacement-after-delete',
      title: 'Replacement after deleting a later swiped word stays intact',
      expectedVisibleText: 'the ',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'the ',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'the '.length,
      run: _runReplacementAfterDeleteCase,
    ),
    _ValidationCase(
      id: '05-single-emoji-backspace',
      title: 'Deleting one emoji should emit one backspace',
      expectedVisibleText: '',
      expectedRawOutput: '👍\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      run: _runSingleEmojiDeleteCase,
    ),
    _ValidationCase(
      id: '06-combining-grapheme-backspace',
      title:
          'Deleting one combining-character grapheme should emit one backspace',
      expectedVisibleText: '',
      expectedRawOutput: 'e\u0301\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      run: _runCombiningGraphemeDeleteCase,
    ),
    _ValidationCase(
      id: '07-cursor-move-only',
      title: 'Collapsed IME caret moves also move the terminal cursor',
      expectedVisibleText: 'echo teh world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo teh world',
      expectedSelectionOffset: 11,
      expectedTerminalCursorOffset: 'echo teh '.length,
      run: _runCursorMoveOnlyCase,
    ),
    _ValidationCase(
      id: '08-midline-replace-backspace',
      title:
          'Mid-line replace then backspace keeps the terminal cursor aligned',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      run: _runMidlineReplaceThenBackspaceCase,
    ),
    _ValidationCase(
      id: '09-space-boundary-insert',
      title:
          'Inserting at a moved space boundary does not overwrite the next word',
      expectedVisibleText: 'foo Xbar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo Xbar',
      expectedSelectionOffset: 7,
      expectedTerminalCursorOffset: 'foo X'.length,
      run: _runSpaceBoundaryInsertCase,
    ),
    _ValidationCase(
      id: '10-punctuation-boundary-replace',
      title: 'Replacing punctuation mid-line keeps the trailing word intact',
      expectedVisibleText: 'hello; world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'hello; world',
      expectedSelectionOffset: 8,
      expectedTerminalCursorOffset: 'hello;'.length,
      run: _runPunctuationBoundaryReplaceCase,
    ),
    _ValidationCase(
      id: '11-repeated-word-replace',
      title:
          'Replacing the middle repeated word leaves the trailing match untouched',
      expectedVisibleText: 'go gone go',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'go gone go',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'go gone'.length,
      run: _runRepeatedWordReplaceCase,
    ),
    _ValidationCase(
      id: '12-space-boundary-insert-backspace',
      title:
          'Insert then backspace at a moved space boundary restores the original spacing',
      expectedVisibleText: 'foo bar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo bar',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'foo '.length,
      run: _runSpaceBoundaryInsertThenBackspaceCase,
    ),
    _ValidationCase(
      id: '13-double-space-insert-backspace',
      title:
          'Insert then backspace between repeated spaces does not drift the cursor',
      expectedVisibleText: 'foo  bar',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'foo  bar',
      expectedSelectionOffset: 6,
      expectedTerminalCursorOffset: 'foo '.length,
      run: _runDoubleSpaceInsertThenBackspaceCase,
    ),
    _ValidationCase(
      id: '14-repeated-word-replace-backspace',
      title:
          'Replacing a repeated middle word still leaves backspace targeting that word',
      expectedVisibleText: 'go gon go',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'go gon go',
      expectedSelectionOffset: 8,
      expectedTerminalCursorOffset: 'go gon'.length,
      run: _runRepeatedWordReplaceThenBackspaceCase,
    ),
    _ValidationCase(
      id: '15-marker-loss-clear',
      title:
          'Losing the delete-detection marker clears all buffered text instead of one character',
      expectedVisibleText: '',
      expectedRawOutput: 'hello\x7f\x7f\x7f\x7f\x7f',
      expectedEditingText: _deleteDetectionMarker,
      expectedSelectionOffset: 2,
      expectedTerminalCursorOffset: 0,
      run: _runMarkerLossClearCase,
    ),
    _ValidationCase(
      id: '16-replacement-selection-backspace',
      title:
          'Replacement selection followed by immediate backspace keeps the cursor on the replaced word',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      run: _runReplacementSelectionThenBackspaceCase,
    ),
    _ValidationCase(
      id: '17-identical-char-insert',
      title:
          'Inserting an identical character at a moved caret stays anchored to that caret',
      expectedVisibleText: 'aaaaa',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'aaaaa',
      expectedSelectionOffset: 4,
      expectedTerminalCursorOffset: 2,
      run: _runIdenticalCharacterInsertCase,
    ),
    _ValidationCase(
      id: '18-identical-char-delete',
      title:
          'Deleting an identical character at a moved caret backspaces at that caret',
      expectedVisibleText: 'aaaa',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'aaaa',
      expectedSelectionOffset: 3,
      expectedTerminalCursorOffset: 1,
      run: _runIdenticalCharacterDeleteCase,
    ),
    _ValidationCase(
      id: '19-repeated-selection-replace-backspace',
      title:
          'Repeated non-collapsed replacement updates still leave backspace on the intended word',
      expectedVisibleText: 'echo th world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo th world',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'echo th'.length,
      run: _runRepeatedSelectionReplaceThenBackspaceCase,
    ),
    _ValidationCase(
      id: '20-replace-move-later-backspace',
      title:
          'Replacing one word then backspacing later elsewhere keeps the later caret anchored',
      expectedVisibleText: 'echo the worl',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the worl',
      expectedSelectionOffset: 15,
      expectedTerminalCursorOffset: 'echo the worl'.length,
      run: _runReplaceThenLaterBackspaceCase,
    ),
    _ValidationCase(
      id: '21-replacement-separator-reinsert',
      title:
          'Deleting and reinserting the replacement separator restores the intended spacing without drift',
      expectedVisibleText: 'echo the world',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the world',
      expectedSelectionOffset: 11,
      expectedTerminalCursorOffset: 'echo the '.length,
      run: _runReplacementSeparatorReinsertCase,
    ),
    _ValidationCase(
      id: '22-replace-elsewhere',
      title:
          'Replacing one word and then replacing a later word keeps both edits anchored',
      expectedVisibleText: 'echo the earth',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'echo the earth',
      expectedSelectionOffset: 16,
      expectedTerminalCursorOffset: 'echo the earth'.length,
      run: _runReplaceThenLaterReplacementCase,
    ),
    _ValidationCase(
      id: '23-shorter-prefix-replacement',
      title:
          'Backspacing to a shorter prefix before choosing a replacement keeps the replacement text ordered correctly',
      expectedVisibleText: 'I stink',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'I stink',
      expectedSelectionOffset: 9,
      expectedTerminalCursorOffset: 'I stink'.length,
      run: _runShorterPrefixReplacementCase,
    ),
  ];

  testWidgets('runs the terminal text input validation matrix', (tester) async {
    final results = <_ValidationResult>[];
    for (final testCase in cases) {
      results.add(await _runCase(tester, testCase));
    }

    await tester.pumpWidget(_SummaryScreen(results: results));
    await tester.pumpAndSettle();
    final holdValidationSummaryDuration = _holdValidationSummaryDuration();
    if (holdValidationSummaryDuration != null) {
      await Future.delayed(holdValidationSummaryDuration);
    }

    final failures = results.where((result) => !result.passed).toList();
    expect(
      failures,
      isEmpty,
      reason: failures
          .map(
            (result) =>
                '${result.testCase.id}: expected raw '
                '${result.testCase.expectedRawOutput ?? '(n/a)'}, '
                'actual raw ${result.rawOutput}, expected visible '
                '${result.testCase.expectedVisibleText}, actual visible '
                '${result.visibleText}, expected terminal cursor '
                '${result.testCase.expectedTerminalCursorOffset?.toString() ?? '(n/a)'}, '
                'actual terminal cursor ${result.terminalCursorOffset}',
          )
          .join('\n'),
    );
  });
}

Future<void> _runFirstSwipeWordCase(WidgetTester tester) async {
  await _commitSwipeText(tester, '$_deleteDetectionMarker\nhello');
}

String _resolveTerminalTextWithoutTrailingSpace() => 'echo ready';

Future<void> _runResumeSwipeSeparatorCase(WidgetTester tester) async {
  await _commitSwipeText(tester, '$_deleteDetectionMarker world');
}

String _resolveTerminalTextWithTrailingSpace() => 'echo ready ';

Future<void> _runNoDuplicateSeparatorCase(WidgetTester tester) async {
  await _commitSwipeText(tester, '$_deleteDetectionMarker world');
}

Future<void> _runReplacementAfterDeleteCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'teh world ',
      selection: TextSelection.collapsed(offset: 12),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'teh ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'the ',
      selection: TextSelection(baseOffset: 2, extentOffset: 5),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'the ',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();
}

Future<void> _runSingleEmojiDeleteCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: '$_deleteDetectionMarker👍',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: _deleteDetectionMarker,
      selection: TextSelection.collapsed(offset: 2),
    ),
  );
  await tester.pump();
}

Future<void> _runCombiningGraphemeDeleteCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'e\u0301',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text: _deleteDetectionMarker,
      selection: TextSelection.collapsed(offset: 2),
    ),
  );
  await tester.pump();
}

Future<void> _runCursorMoveOnlyCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();
}

Future<void> _runMidlineReplaceThenBackspaceCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo th world',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();
}

Future<void> _runSpaceBoundaryInsertCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo bar',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo bar',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo Xbar',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();
}

Future<void> _runPunctuationBoundaryReplaceCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'hello, world',
      selection: TextSelection.collapsed(offset: 14),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'hello, world',
      selection: TextSelection.collapsed(offset: 8),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'hello; world',
      selection: TextSelection.collapsed(offset: 8),
    ),
  );
  await tester.pump();
}

Future<void> _runRepeatedWordReplaceCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go go go',
      selection: TextSelection.collapsed(offset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go go go',
      selection: TextSelection(baseOffset: 5, extentOffset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go gone go',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();
}

Future<void> _runSpaceBoundaryInsertThenBackspaceCase(
  WidgetTester tester,
) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo bar',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo bar',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo Xbar',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo bar',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();
}

Future<void> _runDoubleSpaceInsertThenBackspaceCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo  bar',
      selection: TextSelection.collapsed(offset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo  bar',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo X bar',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'foo  bar',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();
}

Future<void> _runRepeatedWordReplaceThenBackspaceCase(
  WidgetTester tester,
) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go go go',
      selection: TextSelection.collapsed(offset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go go go',
      selection: TextSelection(baseOffset: 5, extentOffset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go gone go',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'go gon go',
      selection: TextSelection.collapsed(offset: 8),
    ),
  );
  await tester.pump();
}

Future<void> _runMarkerLossClearCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'hello',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
  );
  await tester.pump();
}

Future<void> _runReplacementSelectionThenBackspaceCase(
  WidgetTester tester,
) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection(baseOffset: 7, extentOffset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection(baseOffset: 7, extentOffset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo th world',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();
}

Future<void> _runIdenticalCharacterInsertCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaa',
      selection: TextSelection.collapsed(offset: 6),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaa',
      selection: TextSelection.collapsed(offset: 3),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaaa',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();
}

Future<void> _runIdenticalCharacterDeleteCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaaa',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaaa',
      selection: TextSelection.collapsed(offset: 4),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'aaaa',
      selection: TextSelection.collapsed(offset: 3),
    ),
  );
  await tester.pump();
}

Future<void> _runRepeatedSelectionReplaceThenBackspaceCase(
  WidgetTester tester,
) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection(baseOffset: 7, extentOffset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection(baseOffset: 7, extentOffset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo then world',
      selection: TextSelection(baseOffset: 7, extentOffset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection(baseOffset: 7, extentOffset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo th world',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();
}

Future<void> _runReplaceThenLaterBackspaceCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the worl',
      selection: TextSelection.collapsed(offset: 15),
    ),
  );
  await tester.pump();
}

Future<void> _runReplacementSeparatorReinsertCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection(baseOffset: 7, extentOffset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo theworld',
      selection: TextSelection.collapsed(offset: 10),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();
}

Future<void> _runReplaceThenLaterReplacementCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo teh world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection.collapsed(offset: 11),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the world',
      selection: TextSelection(baseOffset: 11, extentOffset: 16),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'echo the earth',
      selection: TextSelection.collapsed(offset: 16),
    ),
  );
  await tester.pump();
}

Future<void> _runShorterPrefixReplacementCase(WidgetTester tester) async {
  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'I still have',
      selection: TextSelection.collapsed(offset: 14),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'I sti',
      selection: TextSelection.collapsed(offset: 7),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'I stink',
      selection: TextSelection(baseOffset: 4, extentOffset: 9),
    ),
  );
  await tester.pump();

  tester.testTextInput.updateEditingValue(
    const TextEditingValue(
      text:
          '$_deleteDetectionMarker'
          'I stink',
      selection: TextSelection.collapsed(offset: 9),
    ),
  );
  await tester.pump();
}
