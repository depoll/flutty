import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

String _terminalTextFromEvents(Iterable<String> events) {
  final visibleCharacters = <String>[];
  for (final event in events) {
    for (final character in event.characters) {
      if (character == '\x7f') {
        if (visibleCharacters.isNotEmpty) {
          visibleCharacters.removeLast();
        }
        continue;
      }
      visibleCharacters.add(character);
    }
  }
  return visibleCharacters.join();
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
  });

  final String id;
  final String title;
  final String expectedVisibleText;
  final String? expectedRawOutput;
  final String? expectedEditingText;
  final int? expectedSelectionOffset;
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
  });

  final _ValidationCase testCase;
  final String visibleText;
  final String rawOutput;
  final String editingText;
  final int? selectionOffset;

  bool get passed =>
      visibleText == testCase.expectedVisibleText &&
      (testCase.expectedRawOutput == null ||
          rawOutput == testCase.expectedRawOutput) &&
      (testCase.expectedEditingText == null ||
          editingText == testCase.expectedEditingText) &&
      (testCase.expectedSelectionOffset == null ||
          selectionOffset == testCase.expectedSelectionOffset);
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
  final result = _ValidationResult(
    testCase: testCase,
    visibleText: _terminalTextFromEvents(terminalOutput),
    rawOutput: terminalOutput.join(),
    editingText: editingValue?.text ?? '',
    selectionOffset: editingValue?.selection.extentOffset,
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
                            '${result.passed ? "PASS" : "FAIL"} ${result.testCase.id}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(result.testCase.title),
                          Text(
                            'Expected raw: ${result.testCase.expectedRawOutput ?? "(n/a)"}',
                          ),
                          Text('Actual raw: ${result.rawOutput}'),
                          Text(
                            'Expected visible: ${result.testCase.expectedVisibleText}',
                          ),
                          Text('Actual visible: ${result.visibleText}'),
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
      expectedRawOutput: 'teh world \x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7fhe ',
      expectedEditingText:
          '$_deleteDetectionMarker'
          'the ',
      expectedSelectionOffset: 6,
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
  ];

  testWidgets('runs the terminal text input validation matrix', (tester) async {
    final results = <_ValidationResult>[];
    for (final testCase in cases) {
      results.add(await _runCase(tester, testCase));
    }

    await tester.pumpWidget(_SummaryScreen(results: results));
    await tester.pumpAndSettle();

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
                '${result.visibleText}',
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
