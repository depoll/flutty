// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

typedef _LoggedEditingState = ({
  String text,
  int selectionBase,
  int selectionExtent,
  int composingBase,
  int composingExtent,
});

typedef _ComparisonResult = ({
  _LoggedEditingState finalState,
  List<_LoggedEditingState> echoedStates,
});

typedef _MatrixScenario = ({
  String name,
  List<TextEditingValue> sequence,
  int? textFieldEchoes,
  int? terminalEchoes,
});

typedef _SegmentSeed = ({
  String name,
  String before,
  String middle,
  String after,
});

typedef _TerminalHarness = ({
  List<String> terminalOutput,
  Terminal terminal,
  FocusNode focusNode,
  TerminalTextInputHandlerController controller,
});

typedef _ResetSeed = ({
  String name,
  String resolveTextBeforeCursor,
  bool trimsAfterSuggestionReset,
});

typedef _ResetScenario = ({
  String name,
  _ResetTrigger trigger,
  String resolveTextBeforeCursor,
  bool shouldTrim,
});

enum _ResetTrigger {
  trailingBackspace,
  newlineAction,
  newlineText,
  controllerClear,
  markerLoss,
}

int _graphemeLength(String text) => text.characters.length;

TextEditingValue _userValue(
  String text, {
  required int selectionBase,
  int? selectionExtent,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: text,
  selection: selectionExtent == null
      ? TextSelection.collapsed(offset: selectionBase)
      : TextSelection(baseOffset: selectionBase, extentOffset: selectionExtent),
  composing: composing,
);

String _dropLastGrapheme(String text) {
  final graphemes = text.characters.toList(growable: false);
  if (graphemes.isEmpty) {
    return text;
  }
  return graphemes.sublist(0, graphemes.length - 1).join();
}

_MatrixScenario _insertBeforeMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final insertionOffset = _graphemeLength(seed.before);
  final updated = '${seed.before}X${seed.middle}${seed.after}';
  return (
    name: '${seed.name}: inserts before the edited segment',
    sequence: [
      _userValue(initial, selectionBase: _graphemeLength(initial)),
      _userValue(initial, selectionBase: insertionOffset),
      _userValue(updated, selectionBase: insertionOffset + 1),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _insertAfterMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final insertionOffset = _graphemeLength('${seed.before}${seed.middle}');
  final updated = '${seed.before}${seed.middle};${seed.after}';
  return (
    name: '${seed.name}: inserts after the edited segment',
    sequence: [
      _userValue(initial, selectionBase: _graphemeLength(initial)),
      _userValue(initial, selectionBase: insertionOffset),
      _userValue(updated, selectionBase: insertionOffset + 1),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _replaceMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final selectionBase = _graphemeLength(seed.before);
  final selectionExtent = selectionBase + _graphemeLength(seed.middle);
  final updated = '${seed.before}ZX${seed.after}';
  return (
    name: '${seed.name}: replaces the edited segment',
    sequence: [
      _userValue(initial, selectionBase: _graphemeLength(initial)),
      _userValue(
        initial,
        selectionBase: selectionBase,
        selectionExtent: selectionExtent,
      ),
      _userValue(updated, selectionBase: selectionBase + 2),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _backspaceWithinMiddleScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final shortenedMiddle = _dropLastGrapheme(seed.middle);
  final caretOffset = _graphemeLength('${seed.before}${seed.middle}');
  final updated = '${seed.before}$shortenedMiddle${seed.after}';
  return (
    name: '${seed.name}: backspaces within the edited segment',
    sequence: [
      _userValue(initial, selectionBase: _graphemeLength(initial)),
      _userValue(initial, selectionBase: caretOffset),
      _userValue(
        updated,
        selectionBase: _graphemeLength('${seed.before}$shortenedMiddle'),
      ),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

_MatrixScenario _deleteMiddleSelectionScenario(_SegmentSeed seed) {
  final initial = '${seed.before}${seed.middle}${seed.after}';
  final selectionBase = _graphemeLength(seed.before);
  final selectionExtent = selectionBase + _graphemeLength(seed.middle);
  final updated = '${seed.before}${seed.after}';
  return (
    name: '${seed.name}: deletes the edited segment selection',
    sequence: [
      _userValue(initial, selectionBase: _graphemeLength(initial)),
      _userValue(
        initial,
        selectionBase: selectionBase,
        selectionExtent: selectionExtent,
      ),
      _userValue(updated, selectionBase: selectionBase),
    ],
    textFieldEchoes: null,
    terminalEchoes: null,
  );
}

List<_MatrixScenario> _buildGeneratedComparisonScenarios() {
  const seeds = <_SegmentSeed>[
    (name: 'plain-word', before: 'he', middle: 'll', after: 'o there'),
    (name: 'space-separated', before: 'foo ', middle: 'ba', after: 'r baz'),
    (name: 'punctuation', before: 'hello, ', middle: 'wo', after: 'rld!'),
    (name: 'repeated-token', before: 'aa', middle: 'aa', after: ' aa'),
    (name: 'emoji-boundary', before: 'go ', middle: '👩🏽‍💻', after: ' now'),
    (name: 'path-fragment', before: '/usr/', middle: 'lo', after: 'cal/bin'),
    (name: 'number-fragment', before: '12', middle: '34', after: '56-78'),
    (name: 'hyphenated', before: 'shell-', middle: 'hi', after: 'story.txt'),
    (name: 'apostrophe', before: 'did', middle: 'n\'t', after: ' panic'),
    (name: 'command-subst', before: 'echo ', middle: r'$(pwd)', after: ' done'),
    (name: 'tab-separated', before: 'foo\t', middle: 'bar', after: '\tbaz'),
    (name: 'snake-case', before: 'snake_', middle: 'ca', after: 'se_value'),
    (name: 'bracketed', before: '[', middle: 'item', after: '] list'),
    (name: 'quoted', before: '"', middle: 'hello', after: '" world'),
    (name: 'pipe-chain', before: 'ls | ', middle: 'gr', after: 'ep ssh'),
    (name: 'git-ref', before: 'feature/', middle: 'ime', after: '-fix'),
    (name: 'ipv6-ish', before: 'fe80::', middle: '1', after: 'ff:fe23'),
    (name: 'env-var', before: r'$HO', middle: 'ME', after: '/bin'),
    (name: 'semicolon', before: 'echo ', middle: 'hi', after: '; pwd'),
    (name: 'mixed-symbols', before: 'x=', middle: '42', after: '; y=7'),
  ];

  return [
    for (final seed in seeds) ...[
      _insertBeforeMiddleScenario(seed),
      _insertAfterMiddleScenario(seed),
      _replaceMiddleScenario(seed),
      _backspaceWithinMiddleScenario(seed),
      _deleteMiddleSelectionScenario(seed),
    ],
  ];
}

List<_MatrixScenario> _buildGptComparisonScenarios() {
  const seeds = <_SegmentSeed>[
    (name: 'leading-indent', before: '  ', middle: 'he', after: 'llo world'),
    (name: 'double-space', before: 'foo  ', middle: 'ba', after: 'r baz'),
    (name: 'cjk-plain', before: '你', middle: '好', after: '世界'),
    (name: 'accented-latin', before: 'na', middle: 'ï', after: 've test'),
    (name: 'quoted-arg', before: 'echo "', middle: 'hi', after: '" now'),
    (name: 'brace-expansion', before: '{a,', middle: 'b', after: ',c}'),
    (name: 'windows-path', before: r'C:\', middle: 'Us', after: r'ers\me'),
    (name: 'env-braces', before: r'${', middle: 'HO', after: 'ME}'),
    (name: 'and-chain', before: 'cmd && ', middle: 'ec', after: 'ho'),
    (name: 'comment-fragment', before: '# ', middle: 'to', after: 'do item'),
    (name: 'ssh-config', before: 'Host ', middle: 'my', after: '-box'),
    (name: 'url-like', before: 'https://', middle: 'ex', after: '.am/path'),
    (name: 'csv-fragment', before: 'a,', middle: 'b', after: ',c,d'),
    (name: 'leading-tab', before: '\t', middle: 'cm', after: 'd --help'),
    (name: 'mid-spaces', before: 'cmd', middle: '  ', after: 'arg'),
    (name: 'spanish-tilde', before: 'mañ', middle: 'an', after: 'a mode'),
    (name: 'pipe-reader', before: 'cat ', middle: 'fi', after: 'le | less'),
    (name: 'env-equals', before: 'KEY=', middle: 'va', after: 'lue'),
    (name: 'paren-spaced', before: '( ', middle: 'ab', after: ' ) tail'),
    (name: 'digits-dots', before: '1.', middle: '2', after: '.3.4'),
  ];

  return [
    for (final seed in seeds) ...[
      (
        name: 'gpt-derived ${_insertBeforeMiddleScenario(seed).name}',
        sequence: _insertBeforeMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_insertAfterMiddleScenario(seed).name}',
        sequence: _insertAfterMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_replaceMiddleScenario(seed).name}',
        sequence: _replaceMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_backspaceWithinMiddleScenario(seed).name}',
        sequence: _backspaceWithinMiddleScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      (
        name: 'gpt-derived ${_deleteMiddleSelectionScenario(seed).name}',
        sequence: _deleteMiddleSelectionScenario(seed).sequence,
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
    ],
  ];
}

List<_MatrixScenario> _buildFlutterReplacedParityScenarios() {
  const testText = 'From a false proposition, anything follows.';
  final cases =
      <
        ({
          String name,
          TextEditingValue initialValue,
          TextRange replacementRange,
          String replacementText,
        })
      >[
        (
          name: 'selection deletion',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 5, extentOffset: 13),
          ),
          replacementRange: const TextSelection(
            baseOffset: 5,
            extentOffset: 13,
          ),
          replacementText: '',
        ),
        (
          name: 'reversed selection deletion',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextSelection(
            baseOffset: 13,
            extentOffset: 5,
          ),
          replacementText: '',
        ),
        (
          name: 'insert',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection.collapsed(offset: 5),
          ),
          replacementRange: const TextSelection.collapsed(offset: 5),
          replacementText: 'AA',
        ),
        (
          name: 'replace before selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 4, end: 5),
          replacementText: 'AA',
        ),
        (
          name: 'replace after selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 13, end: 14),
          replacementText: 'AA',
        ),
        (
          name: 'replace inside selection - start boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 5, end: 6),
          replacementText: 'AA',
        ),
        (
          name: 'replace inside selection - end boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 12, end: 13),
          replacementText: 'AA',
        ),
        (
          name: 'delete after selection',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 13, end: 14),
          replacementText: '',
        ),
        (
          name: 'delete inside selection - start boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 5, end: 6),
          replacementText: '',
        ),
        (
          name: 'delete inside selection - end boundary',
          initialValue: const TextEditingValue(
            text: testText,
            selection: TextSelection(baseOffset: 13, extentOffset: 5),
          ),
          replacementRange: const TextRange(start: 12, end: 13),
          replacementText: '',
        ),
      ];

  return [
    for (final scenario in cases)
      (
        name: 'flutter TextEditingValue.replaced ${scenario.name}',
        sequence: [
          scenario.initialValue,
          scenario.initialValue.replaced(
            scenario.replacementRange,
            scenario.replacementText,
          ),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
  ];
}

List<_MatrixScenario> _buildFlutterDeltaParityScenarios() {
  final cases =
      <({String name, TextEditingValue initialValue, TextEditingDelta delta})>[
        (
          name: 'insertion at a collapsed selection',
          initialValue: TextEditingValue.empty,
          delta: const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: 'let there be text',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 17),
            composing: TextRange.empty,
          ),
        ),
        (
          name: 'insertion at end of composing region',
          initialValue: const TextEditingValue(
            text: 'hello worl',
            selection: TextSelection.collapsed(offset: 10),
          ),
          delta: const TextEditingDeltaInsertion(
            oldText: 'hello worl',
            textInserted: 'd',
            insertionOffset: 10,
            selection: TextSelection.collapsed(offset: 11),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
        (
          name: 'deletion at end of composing region',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaDeletion(
            oldText: 'hello world',
            deletedRange: TextRange(start: 10, end: 11),
            selection: TextSelection.collapsed(offset: 10),
            composing: TextRange(start: 6, end: 10),
          ),
        ),
        (
          name: 'replacement with longer text',
          initialValue: const TextEditingValue(
            text: 'hello worfi',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello worfi',
            replacementText: 'working',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 13),
            composing: TextRange(start: 6, end: 13),
          ),
        ),
        (
          name: 'replacement with shorter text',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello world',
            replacementText: 'h',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 6, end: 7),
          ),
        ),
        (
          name: 'replacement with same-length text',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaReplacement(
            oldText: 'hello world',
            replacementText: 'words',
            replacedRange: TextRange(start: 6, end: 11),
            selection: TextSelection.collapsed(offset: 11),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
        (
          name: 'non-text selection/composing update',
          initialValue: const TextEditingValue(
            text: 'hello world',
            selection: TextSelection.collapsed(offset: 11),
          ),
          delta: const TextEditingDeltaNonTextUpdate(
            oldText: 'hello world',
            selection: TextSelection.collapsed(offset: 10),
            composing: TextRange(start: 6, end: 11),
          ),
        ),
      ];

  return [
    for (final scenario in cases)
      (
        name: 'flutter TextEditingDelta ${scenario.name}',
        sequence: [
          scenario.initialValue,
          scenario.delta.apply(scenario.initialValue),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
  ];
}

List<_MatrixScenario> _buildFlutterComposingParityScenarios() {
  const baseValue = TextEditingValue(
    text: 'foo composing bar',
    selection: TextSelection.collapsed(offset: 4),
    composing: TextRange(start: 4, end: 12),
  );

  return [
    (
      name:
          'flutter EditableText preserves composing range when a collapsed caret moves within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a collapsed caret moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a collapsed caret moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection.collapsed(offset: 14),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a selection moves before it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 1, extentOffset: 2),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText preserves composing range when a selection stays within it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 5, extentOffset: 7),
          composing: TextRange(start: 4, end: 12),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
    (
      name:
          'flutter EditableText clears composing range when a selection moves after it',
      sequence: const [
        baseValue,
        TextEditingValue(
          text: 'foo composing bar',
          selection: TextSelection(baseOffset: 13, extentOffset: 15),
        ),
      ],
      textFieldEchoes: null,
      terminalEchoes: null,
    ),
  ];
}

List<_ResetScenario> _buildOpusResetScenarios() {
  const seeds = <_ResetSeed>[
    (
      name: 'empty-context',
      resolveTextBeforeCursor: '',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'single-space-context',
      resolveTextBeforeCursor: ' ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'tab-context',
      resolveTextBeforeCursor: '\t',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'newline-context',
      resolveTextBeforeCursor: '\n',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'carriage-context',
      resolveTextBeforeCursor: '\r',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'prompt-space-context',
      resolveTextBeforeCursor: r'$ ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'prompt-marker-context',
      resolveTextBeforeCursor: '>',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-space-context',
      resolveTextBeforeCursor: 'echo ready ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-tab-context',
      resolveTextBeforeCursor: 'echo ready\t',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'command-newline-context',
      resolveTextBeforeCursor: 'echo ready\n',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'double-space-context',
      resolveTextBeforeCursor: 'echo ready  ',
      trimsAfterSuggestionReset: true,
    ),
    (
      name: 'plain-command-context',
      resolveTextBeforeCursor: 'echo',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'paren-context',
      resolveTextBeforeCursor: 'echo(',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'emoji-context',
      resolveTextBeforeCursor: 'say 😀',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'quoted-context',
      resolveTextBeforeCursor: '"quoted',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'path-context',
      resolveTextBeforeCursor: '/usr/local',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'assignment-context',
      resolveTextBeforeCursor: 'KEY=value',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'semicolon-context',
      resolveTextBeforeCursor: 'echo;',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'bracket-context',
      resolveTextBeforeCursor: 'list]',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'hyphen-context',
      resolveTextBeforeCursor: 'git-status',
      trimsAfterSuggestionReset: false,
    ),
    (
      name: 'ipv6-context',
      resolveTextBeforeCursor: 'fe80::1',
      trimsAfterSuggestionReset: false,
    ),
  ];

  return [
    for (final seed in seeds)
      for (final trigger in _ResetTrigger.values)
        (
          name:
              'opus-derived ${trigger.name} ${trigger == _ResetTrigger.markerLoss || seed.trimsAfterSuggestionReset ? 'trims' : 'preserves'} leading suggestion spacing for ${seed.name}',
          trigger: trigger,
          resolveTextBeforeCursor: seed.resolveTextBeforeCursor,
          shouldTrim:
              trigger == _ResetTrigger.markerLoss ||
              seed.trimsAfterSuggestionReset,
        ),
  ];
}

Future<_TerminalHarness> _pumpTerminalHarness(
  WidgetTester tester, {
  bool readOnly = false,
  bool deleteDetection = true,
  bool tapToShowKeyboard = true,
  String Function()? resolveTextBeforeCursor,
  TerminalKeyModifierResolver? resolveTerminalKeyModifiers,
  VoidCallback? consumeTerminalKeyModifiers,
  ValueGetter<bool>? hasActiveToolbarModifier,
  TerminalTextInputHandlerController? controller,
}) async {
  final terminalOutput = <String>[];
  final terminal = Terminal(onOutput: terminalOutput.add);
  final focusNode = FocusNode();
  final effectiveController =
      controller ?? TerminalTextInputHandlerController();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          controller: effectiveController,
          deleteDetection: deleteDetection,
          readOnly: readOnly,
          tapToShowKeyboard: tapToShowKeyboard,
          resolveTextBeforeCursor: resolveTextBeforeCursor,
          resolveTerminalKeyModifiers: resolveTerminalKeyModifiers,
          consumeTerminalKeyModifiers: consumeTerminalKeyModifiers,
          hasActiveToolbarModifier: hasActiveToolbarModifier,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();

  return (
    terminalOutput: terminalOutput,
    terminal: terminal,
    focusNode: focusNode,
    controller: effectiveController,
  );
}

Future<void> _disposeTerminalHarness(
  WidgetTester tester,
  _TerminalHarness harness,
) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  harness.focusNode.dispose();
}

Future<void> _applyResetTrigger(
  WidgetTester tester,
  _TerminalHarness harness,
  _ResetTrigger trigger, {
  required String initialText,
}) async {
  switch (trigger) {
    case _ResetTrigger.trailingBackspace:
      final shortenedText = _dropLastGrapheme(initialText);
      tester.testTextInput.updateEditingValue(
        _editingValue(shortenedText, selectionOffset: shortenedText.length),
      );
      await tester.pump();
      break;
    case _ResetTrigger.newlineAction:
      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();
      break;
    case _ResetTrigger.newlineText:
      final textWithNewline = '$initialText\n';
      tester.testTextInput.updateEditingValue(
        _editingValue(textWithNewline, selectionOffset: textWithNewline.length),
      );
      await tester.pump();
      break;
    case _ResetTrigger.controllerClear:
      harness.controller.clearImeBuffer();
      await tester.pump();
      break;
    case _ResetTrigger.markerLoss:
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      break;
  }
}

Future<void> _expectResetContinuationScenario(
  WidgetTester tester,
  _ResetScenario scenario,
) async {
  const initialText = 'alpha';
  const followUpText = ' beta';
  final harness = await _pumpTerminalHarness(
    tester,
    resolveTextBeforeCursor: () => scenario.resolveTextBeforeCursor,
  );

  tester.testTextInput.updateEditingValue(
    _editingValue(initialText, selectionOffset: initialText.length),
  );
  await tester.pump();

  harness.terminalOutput.clear();
  tester.testTextInput.log.clear();

  await _applyResetTrigger(
    tester,
    harness,
    scenario.trigger,
    initialText: initialText,
  );

  harness.terminalOutput.clear();
  tester.testTextInput.log.clear();

  tester.testTextInput.updateEditingValue(
    _editingValue(followUpText, selectionOffset: followUpText.length),
  );
  await tester.pump();

  expect(
    _terminalTextFromEvents(harness.terminalOutput),
    scenario.shouldTrim ? 'beta' : ' beta',
  );

  await _disposeTerminalHarness(tester, harness);
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

String _terminalTextFromEvents(Iterable<String> events) {
  final state = _terminalStateFromEvents(events);
  return state.text;
}

({String text, int cursorOffset}) _terminalStateFromEvents(
  Iterable<String> events, {
  String initialText = '',
  int? initialCursorOffset,
}) {
  final visibleCharacters = initialText.characters.toList(growable: true);
  var cursorOffset = initialCursorOffset ?? visibleCharacters.length;
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

TextEditingValue _editingValue(
  String userText, {
  required int selectionOffset,
  TextRange composing = TextRange.empty,
}) => TextEditingValue(
  text: '$_deleteDetectionMarker$userText',
  selection: TextSelection.collapsed(
    offset: _deleteDetectionMarker.length + selectionOffset,
  ),
  composing: composing == TextRange.empty
      ? TextRange.empty
      : TextRange(
          start: _deleteDetectionMarker.length + composing.start,
          end: _deleteDetectionMarker.length + composing.end,
        ),
);

String _terminalKeyOutput(
  TerminalKey key, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
}) {
  final output = <String>[];
  Terminal(
    onOutput: output.add,
  ).keyInput(key, shift: shift, alt: alt, ctrl: ctrl);
  return output.join();
}

int _normalizeOffsetToUserSpace(int offset, int prefixLength, int maxLength) {
  if (offset < 0) {
    return offset;
  }
  final normalized = offset - prefixLength;
  if (normalized < 0) {
    return 0;
  }
  if (normalized > maxLength) {
    return maxLength;
  }
  return normalized;
}

_LoggedEditingState _loggedStateFromTextEditingValue(TextEditingValue value) =>
    (
      text: value.text,
      selectionBase: value.selection.baseOffset,
      selectionExtent: value.selection.extentOffset,
      composingBase: value.composing.start,
      composingExtent: value.composing.end,
    );

TextEditingValue _terminalEditingValueFromUserValue(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final selection = value.selection.isValid
      ? TextSelection(
          baseOffset: prefixLength + value.selection.baseOffset,
          extentOffset: prefixLength + value.selection.extentOffset,
          affinity: value.selection.affinity,
          isDirectional: value.selection.isDirectional,
        )
      : value.selection;
  final composing = value.composing.isValid && !value.composing.isCollapsed
      ? TextRange(
          start: prefixLength + value.composing.start,
          end: prefixLength + value.composing.end,
        )
      : value.composing;
  return TextEditingValue(
    text: '$_deleteDetectionMarker${value.text}',
    selection: selection,
    composing: composing,
  );
}

_LoggedEditingState _loggedStateFromSetEditingStateCall(
  MethodCall call, {
  bool stripTerminalMarker = false,
}) {
  final arguments = call.arguments as Map<dynamic, dynamic>;
  var text = arguments['text'] as String? ?? '';
  var selectionBase = arguments['selectionBase'] as int? ?? -1;
  var selectionExtent = arguments['selectionExtent'] as int? ?? -1;
  var composingBase = arguments['composingBase'] as int? ?? -1;
  var composingExtent = arguments['composingExtent'] as int? ?? -1;

  if (stripTerminalMarker && text.startsWith(_deleteDetectionMarker)) {
    const prefixLength = _deleteDetectionMarker.length;
    text = text.substring(prefixLength);
    selectionBase = _normalizeOffsetToUserSpace(
      selectionBase,
      prefixLength,
      text.length,
    );
    selectionExtent = _normalizeOffsetToUserSpace(
      selectionExtent,
      prefixLength,
      text.length,
    );
    if (composingBase >= 0) {
      composingBase = _normalizeOffsetToUserSpace(
        composingBase,
        prefixLength,
        text.length,
      );
      composingExtent = _normalizeOffsetToUserSpace(
        composingExtent,
        prefixLength,
        text.length,
      );
    }
  }

  return (
    text: text,
    selectionBase: selectionBase,
    selectionExtent: selectionExtent,
    composingBase: composingBase,
    composingExtent: composingExtent,
  );
}

List<_LoggedEditingState> _setEditingStateStates(
  Iterable<MethodCall> log, {
  bool stripTerminalMarker = false,
}) => log
    .where((call) => call.method == 'TextInput.setEditingState')
    .map(
      (call) => _loggedStateFromSetEditingStateCall(
        call,
        stripTerminalMarker: stripTerminalMarker,
      ),
    )
    .toList(growable: false);

_LoggedEditingState _loggedTerminalClientState(TextEditingValue value) {
  const prefixLength = _deleteDetectionMarker.length;
  final text = value.text.startsWith(_deleteDetectionMarker)
      ? value.text.substring(prefixLength)
      : value.text;
  return (
    text: text,
    selectionBase: _normalizeOffsetToUserSpace(
      value.selection.baseOffset,
      prefixLength,
      text.length,
    ),
    selectionExtent: _normalizeOffsetToUserSpace(
      value.selection.extentOffset,
      prefixLength,
      text.length,
    ),
    composingBase: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.start,
            prefixLength,
            text.length,
          )
        : -1,
    composingExtent: value.composing.isValid && !value.composing.isCollapsed
        ? _normalizeOffsetToUserSpace(
            value.composing.end,
            prefixLength,
            text.length,
          )
        : -1,
  );
}

Future<_ComparisonResult> _runTextFieldSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextField(controller: controller, focusNode: focusNode),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
  }

  final result = (
    finalState: _loggedStateFromTextEditingValue(controller.value),
    echoedStates: _setEditingStateStates(tester.testTextInput.log),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  controller.dispose();
  focusNode.dispose();
  return result;
}

Future<_ComparisonResult> _runTerminalSequence(
  WidgetTester tester,
  List<TextEditingValue> userValues,
) async {
  final terminal = Terminal();
  final focusNode = FocusNode();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalTextInputHandler(
          terminal: terminal,
          focusNode: focusNode,
          deleteDetection: true,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  focusNode.requestFocus();
  await tester.pump();
  tester.testTextInput.log.clear();

  for (final value in userValues) {
    tester.testTextInput.updateEditingValue(
      _terminalEditingValueFromUserValue(value),
    );
    await tester.pump();
  }

  final client =
      tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;
  final result = (
    finalState: _loggedTerminalClientState(client.currentTextEditingValue!),
    echoedStates: _setEditingStateStates(
      tester.testTextInput.log,
      stripTerminalMarker: true,
    ),
  );

  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pump();
  focusNode.dispose();
  return result;
}

Future<void> _expectTextFieldComparisonScenario(
  WidgetTester tester, {
  required List<TextEditingValue> sequence,
  int? expectedTextFieldEchoCount = 0,
  int? expectedTerminalEchoCount,
}) async {
  final textFieldResult = await _runTextFieldSequence(tester, sequence);
  final terminalResult = await _runTerminalSequence(tester, sequence);

  expect(terminalResult.finalState, textFieldResult.finalState);
  if (expectedTextFieldEchoCount != null) {
    expect(textFieldResult.echoedStates, hasLength(expectedTextFieldEchoCount));
  }
  if (expectedTerminalEchoCount != null) {
    expect(terminalResult.echoedStates, hasLength(expectedTerminalEchoCount));
  }
}

TextInputClient _terminalTextInputClient(WidgetTester tester) =>
    tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient;

void main() {
  group('TerminalTextInputHandler', () {
    testWidgets('preserves swipe typing context across short pauses', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello ',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 400));

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });

    testWidgets('drops a spurious leading newline before first swipe text', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker\nhello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('drops a leading space before first swipe text', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker hello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('drops a leading swipe space after a committed newline', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker next');

      expect(terminalOutput.join(), 'echo hi\nnext');

      focusNode.dispose();
    });

    testWidgets(
      'preserves the swipe separator after an input reset when text already exists',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'echo ready',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), ' world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a swipe separator after an input reset when the current line is only a prompt marker',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                resolveTextBeforeCursor: () => '>',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        controller.clearImeBuffer();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'external prompt output does not reconnect the IME client before keyboard input',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                resolveTextBeforeCursor: () => '>',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'external prompt output resets IME context for the next fresh swipe '
      'after keyboard input',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                resolveTextBeforeCursor: () => '>',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo ready', selectionOffset: 'echo ready'.length),
        );
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          hasLength(1),
        );

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a duplicate swipe separator after an input reset when text already ends with whitespace',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'echo ready ',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets('preserves leading spaces for first non-swipe commit', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200B  hello',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), '  hello');

      focusNode.dispose();
    });

    testWidgets('drops a swipe newline followed by a stray leading space', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker\n hello');

      expect(terminalOutput.join(), 'hello');

      focusNode.dispose();
    });

    testWidgets('preserves later swipe spaces after trimming first input', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      await _commitSwipeText(tester, '$_deleteDetectionMarker hello ');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello world ',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'hello world ');

      focusNode.dispose();
    });

    testWidgets(
      'preserves a separator after typed input is fully backspaced away',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'echo ready',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('tmp', selectionOffset: 'tmp'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker hello');

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo ready',
            initialCursorOffset: 'echo ready'.length,
          ),
          (text: 'echo ready hello', cursorOffset: 'echo ready hello'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading swipe space after swipe input is fully backspaced away',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker hello');

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        terminalOutput.clear();

        await _commitSwipeText(tester, '$_deleteDetectionMarker world');

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading suggestion space after input is fully backspaced away',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker hello');

        tester.testTextInput.updateEditingValue(
          _editingValue('', selectionOffset: 0),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                ' world',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'world');

        focusNode.dispose();
      },
    );

    testWidgets('resyncs delete-detection marker after backspacing past it', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bok',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bre',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump();

      expect(terminalOutput.join(), 'ok\x7f\x7fre');
      expect(_terminalStateFromEvents(terminalOutput), (
        text: 're',
        cursorOffset: 2,
      ));

      focusNode.dispose();
    });

    testWidgets(
      'forwards a terminal backspace when delete detection loses the marker with no buffered text',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          _terminalKeyOutput(TerminalKey.backspace),
        );
        expect(
          (tester.state(find.byType(TerminalTextInputHandler))
                  as TextInputClient)
              .currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets('clears all buffered text when the IME loses the marker', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 'hello'.length),
      );
      await tester.pump();

      terminalOutput.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      await tester.pump();

      expect(
        terminalOutput.join(),
        List.filled(
          'hello'.length,
          _terminalKeyOutput(TerminalKey.backspace),
        ).join(),
      );
      expect(
        _terminalStateFromEvents(
          terminalOutput,
          initialText: 'hello',
          initialCursorOffset: 'hello'.length,
        ),
        (text: '', cursorOffset: 0),
      );
      expect(
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      focusNode.dispose();
    });

    testWidgets('keeps IME replacement selections intact', (tester) async {
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bteh ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      expect(_terminalTextFromEvents(terminalOutput), 'teh ');

      tester.testTextInput.log.clear();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection(baseOffset: 2, extentOffset: 5),
        ),
      );
      await tester.pump();

      expect(_terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bthe ',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();

      expect(_terminalTextFromEvents(terminalOutput), 'the ');
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.setEditingState',
        ),
        isEmpty,
      );

      focusNode.dispose();
    });

    testWidgets(
      'keeps the tracked cursor aligned after a hardware left arrow before IME insertion',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 'hello'.length),
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 'hell'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hellXo', selectionOffset: 'hellX'.length),
        );
        await tester.pump();

        expect(terminalOutput.join(), 'X');
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello',
            initialCursorOffset: 'hell'.length,
          ),
          (text: 'hellXo', cursorOffset: 'hellX'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'moves the terminal cursor when the IME caret moves without text changes',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(5, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo teh world', cursorOffset: 'echo teh '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'resyncs the IME state when the caret moves within existing text',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(1),
        );

        focusNode.dispose();
      },
    );

    testWidgets('touch-driven caret moves clear the IME buffer', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue(
          'echo teh world',
          selectionOffset: 'echo teh world'.length,
        ),
      );
      await tester.pump();

      terminalOutput.clear();

      await tester.tap(find.byType(TerminalTextInputHandler));
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
      );
      await tester.pump();

      expect(
        _terminalStateFromEvents(
          terminalOutput,
          initialText: 'echo teh world',
          initialCursorOffset: 'echo teh world'.length,
        ),
        (text: 'echo teh world', cursorOffset: 'echo teh '.length),
      );
      expect(
        _terminalTextInputClient(tester).currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      focusNode.dispose();
    });

    testWidgets(
      'typing after a touch-driven caret move inserts from a fresh IME buffer',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('X', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo Xteh world', cursorOffset: 'echo X'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'resyncs the IME state when a replacement selection collapses to a different caret position',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join(),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(1),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'touch-driven caret moves clear the IME buffer after a replacement selection collapses elsewhere',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}echo the world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        await tester.tap(find.byType(TerminalTextInputHandler));
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo '.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo the world',
            initialCursorOffset: 'echo the'.length,
          ),
          (text: 'echo the world', cursorOffset: 'echo '.length),
        );
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when a replacement is followed by a later move and backspace elsewhere',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo the world',
            selectionOffset: 'echo the world'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo the worl',
            selectionOffset: 'echo the worl'.length,
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo the worl', cursorOffset: 'echo the worl'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when a replacement is followed by a later replacement elsewhere',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo teh world', selectionOffset: 'echo teh '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
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
          _editingValue(
            'echo the earth',
            selectionOffset: 'echo the earth'.length,
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo the earth', cursorOffset: 'echo the earth'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacement selection is followed by immediate backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo th world', cursorOffset: 'echo th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when a replacement selection includes a trailing space before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo theworld', selectionOffset: 'echo the'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo theworld', cursorOffset: 'echo the'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when deleting and then reinserting a replacement separator',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo theworld', selectionOffset: 'echo the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo the world', selectionOffset: 'echo the '.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo the world', cursorOffset: 'echo the '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when whitespace-cluster replacement collapses two spaces before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo  bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'foo  bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo baz', selectionOffset: 'foo baz'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo ba', selectionOffset: 'foo ba'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo  bar',
            initialCursorOffset: 'foo  bar'.length,
          ),
          (text: 'foo ba', cursorOffset: 'foo ba'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned across repeated non-collapsed replacements before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('echo th world', selectionOffset: 'echo th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo th world', cursorOffset: 'echo th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned across repeated-word non-collapsed replacements before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar bar bar', selectionOffset: 'bar bar bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bar bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar baz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bazz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar baz bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar ba bar', selectionOffset: 'bar ba'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'bar bar bar',
            initialCursorOffset: 'bar bar bar'.length,
          ),
          (text: 'bar ba bar', cursorOffset: 'bar ba'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when editing inside a triple-space cluster after an internal move',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo   bar', selectionOffset: 'foo   bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo   bar', selectionOffset: 5),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  X bar', selectionOffset: 6),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  X bar', selectionOffset: 5),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo X bar', selectionOffset: 4),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo   bar',
            initialCursorOffset: 'foo   bar'.length,
          ),
          (text: 'foo X bar', cursorOffset: 4),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned after replacing a repeated word and then backspacing a later repeated match',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar bar bar', selectionOffset: 'bar bar bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'bar bar bar',
            selection: TextSelection(baseOffset: 6, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar baz bar', selectionOffset: 'bar baz'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar baz bar', selectionOffset: 'bar baz bar'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('bar baz ba', selectionOffset: 'bar baz ba'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'bar bar bar',
            initialCursorOffset: 'bar bar bar'.length,
          ),
          (text: 'bar baz ba', cursorOffset: 'bar baz ba'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the terminal cursor aligned at a space boundary before insertion',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo Xbar', cursorOffset: 'foo X'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'inserts at a moved caret without rewriting the unchanged suffix',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo Xbar', cursorOffset: 'foo X'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'inserts at the beginning of the line without rewriting the existing text',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 'hello'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 0),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('Xhello', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(5, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello',
            initialCursorOffset: 'hello'.length,
          ),
          (text: 'Xhello', cursorOffset: 1),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'deletes at a moved caret without rewriting the unchanged suffix',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo Xbar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join() +
              _terminalKeyOutput(TerminalKey.backspace),
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo Xbar',
            initialCursorOffset: 'foo Xbar'.length,
          ),
          (text: 'foo bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'inserts an identical character at a moved caret without rewriting the unchanged suffix',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaa', selectionOffset: 'aaaa'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaa', selectionOffset: 1),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaaa', selectionOffset: 2),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}a',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'aaaa',
            initialCursorOffset: 'aaaa'.length,
          ),
          (text: 'aaaaa', cursorOffset: 2),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'moves and inserts around an emoji using grapheme-aware cursor offsets',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('a🎉b', selectionOffset: 'a🎉b'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('a🎉b', selectionOffset: 1),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aX🎉b', selectionOffset: 2),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(2, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}X',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'a🎉b',
            initialCursorOffset: 3,
          ),
          (text: 'aX🎉b', cursorOffset: 2),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'deletes an identical character at a moved caret without rewriting the unchanged suffix',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaaa', selectionOffset: 'aaaaa'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaaa', selectionOffset: 2),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('aaaa', selectionOffset: 1),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          '${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'aaaaa',
            initialCursorOffset: 'aaaaa'.length,
          ),
          (text: 'aaaa', cursorOffset: 1),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when inserting and then backspacing at a space boundary',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo Xbar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'X${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo bar',
            initialCursorOffset: 'foo bar'.length,
          ),
          (text: 'foo bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when inserting and then backspacing between repeated spaces',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo  bar'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo X bar', selectionOffset: 'foo X'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('foo  bar', selectionOffset: 'foo '.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(4, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'X${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'foo  bar',
            initialCursorOffset: 'foo  bar'.length,
          ),
          (text: 'foo  bar', cursorOffset: 'foo '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'replaces punctuation at a moved caret without rewriting the trailing word',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello, world', selectionOffset: 'hello, world'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello, world', selectionOffset: 'hello,'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello; world', selectionOffset: 'hello;'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(6, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          '${_terminalKeyOutput(TerminalKey.backspace)};',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello, world',
            initialCursorOffset: 'hello, world'.length,
          ),
          (text: 'hello; world', cursorOffset: 'hello;'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing punctuation and double-space clusters before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'hello,  world',
            selectionOffset: 'hello,  world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'hello,  world',
            selection: TextSelection(baseOffset: 7, extentOffset: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello; world', selectionOffset: 'hello; '.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello;world', selectionOffset: 'hello;'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hello,  world',
            initialCursorOffset: 'hello,  world'.length,
          ),
          (text: 'hello;world', cursorOffset: 'hello;'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'replaces the middle repeated word without touching the trailing match',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go go go', selectionOffset: 'go go go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go go go',
            initialCursorOffset: 'go go go'.length,
          ),
          (text: 'go gone go', cursorOffset: 'go gone'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned after replacing a repeated word and then backspacing',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go go go', selectionOffset: 'go go go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

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
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gon go', selectionOffset: 'go gon'.length),
        );
        await tester.pump();

        expect(
          terminalOutput.join(),
          '${List.filled(3, _terminalKeyOutput(TerminalKey.arrowLeft)).join()}'
          'ne${_terminalKeyOutput(TerminalKey.backspace)}',
        );
        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go go go',
            initialCursorOffset: 'go go go'.length,
          ),
          (text: 'go gon go', cursorOffset: 'go gon'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when a repeated-word replacement commits from composition before backspace',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go go go', selectionOffset: 'go go go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

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
            composing: TextRange(start: 5, end: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gone go', selectionOffset: 'go gone'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go gon go', selectionOffset: 'go gon'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go go go',
            initialCursorOffset: 'go go go'.length,
          ),
          (text: 'go gon go', cursorOffset: 'go gon'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when composition moves away before collapsing and a later backspace follows',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo teh world',
            selectionOffset: 'echo teh world'.length,
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection.collapsed(offset: 9),
            composing: TextRange(start: 7, end: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'echo the world',
            selection: TextSelection.collapsed(offset: 16),
            composing: TextRange(start: 7, end: 10),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo the world',
            selectionOffset: 'echo the world'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'echo the worl',
            selectionOffset: 'echo the worl'.length,
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'echo teh world',
            initialCursorOffset: 'echo teh world'.length,
          ),
          (text: 'echo the worl', cursorOffset: 'echo the worl'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves replacement text after a later word delete drops part of the marker',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh world ',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200Bteh ',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection(baseOffset: 2, extentOffset: 5),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'the ');

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when an autocorrected word is punctuated and then backspaced',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hi teh world', selectionOffset: 'hi teh world'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'hi teh world',
            selection: TextSelection(baseOffset: 5, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hi the world', selectionOffset: 'hi the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hi the. world', selectionOffset: 'hi the.'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hi the world', selectionOffset: 'hi the'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'hi teh world',
            initialCursorOffset: 'hi teh world'.length,
          ),
          (text: 'hi the world', cursorOffset: 'hi the'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing across an emoji boundary and trailing space',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        const initialText = 'go 👩🏽‍💻 now';
        const selectionStart = _deleteDetectionMarker.length + 'go '.length;
        const selectionEnd =
            _deleteDetectionMarker.length + 'go 👩🏽‍💻 '.length;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: selectionStart,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go later now', selectionOffset: 'go later'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go late now', selectionOffset: 'go late'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.characters.length,
          ),
          (text: 'go late now', cursorOffset: 'go late'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing the first word and trailing space at the buffer start',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        const initialText = 'teh world';
        const selectionEnd = _deleteDetectionMarker.length + 'teh '.length;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: _deleteDetectionMarker.length,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('the world', selectionOffset: 'the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('th world', selectionOffset: 'th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.length,
          ),
          (text: 'th world', cursorOffset: 'th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned when replacing the last word and leading space at the buffer end',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        const initialText = 'hello teh';
        const selectionStart = _deleteDetectionMarker.length + 'hello'.length;
        const selectionEnd = _deleteDetectionMarker.length + initialText.length;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(initialText, selectionOffset: initialText.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$initialText',
            selection: TextSelection(
              baseOffset: selectionStart,
              extentOffset: selectionEnd,
            ),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello the', selectionOffset: 'hello the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello th', selectionOffset: 'hello th'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: initialText,
            initialCursorOffset: initialText.length,
          ),
          (text: 'hello th', cursorOffset: 'hello th'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the cursor aligned across repeated backspaces after an autocorrected repeated token',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go teh go', selectionOffset: 'go teh go'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text:
                '$_deleteDetectionMarker'
                'go teh go',
            selection: TextSelection(baseOffset: 5, extentOffset: 9),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go the go', selectionOffset: 'go the'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go th go', selectionOffset: 'go th'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('go t go', selectionOffset: 'go t'.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'go teh go',
            initialCursorOffset: 'go teh go'.length,
          ),
          (text: 'go t go', cursorOffset: 'go t'.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'suppresses the first follow-up newline action after a committed newline update',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('echo\n', selectionOffset: 'echo\n'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        Future<void> performNewlineAction() async {
          client.performAction(TextInputAction.newline);
          await tester.pump();
        }

        await performNewlineAction();

        expect(terminalOutput, isEmpty);

        await performNewlineAction();

        expect(terminalOutput.join(), _terminalKeyOutput(TerminalKey.enter));

        focusNode.dispose();
      },
    );

    testWidgets('newline actions consume one-shot toolbar modifiers', (
      tester,
    ) async {
      var shiftActive = true;
      final harness = await _pumpTerminalHarness(
        tester,
        resolveTerminalKeyModifiers: () =>
            (ctrl: false, alt: false, shift: shiftActive),
        consumeTerminalKeyModifiers: () => shiftActive = false,
      );

      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();
      _terminalTextInputClient(tester).performAction(TextInputAction.newline);
      await tester.pump();

      expect(
        harness.terminalOutput.join(),
        _terminalKeyOutput(TerminalKey.enter, shift: true) +
            _terminalKeyOutput(TerminalKey.enter),
      );

      await _disposeTerminalHarness(tester, harness);
    });

    testWidgets('keeps ctrl combos working while IME composition is active', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Ba',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 2, end: 3),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(terminalOutput.join(), '\u0003');

      focusNode.dispose();
    });

    testWidgets('notifies when soft-keyboard input is sent to the terminal', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      var callbackCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onUserInput: () => callbackCount++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Bhello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      expect(callbackCount, 1);

      focusNode.dispose();
    });

    testWidgets(
      'ignores a stale newline edit when the IME action arrives first',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        var reviewCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (_) async {
                  reviewCount++;
                  return true;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\n',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await tester.pump();

        expect(terminalOutput.join(), '\r');
        expect(reviewCount, 0);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: '\u200B\u200B',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'accepts new text after swallowing an action-first newline commit',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        var reviewCount = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (_) async {
                  reviewCount++;
                  return true;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        _terminalTextInputClient(tester).performAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho hi\nn',
            selection: TextSelection.collapsed(offset: 11),
          ),
        );
        await tester.pump();

        expect(terminalOutput.join(), '\rn');
        expect(reviewCount, 0);
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: '\u200B\u200Bn',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets('opens the keyboard after a touch tap', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      focusNode.dispose();
    });

    testWidgets(
      'does not reopen the keyboard when the platform closes it while focused',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.log.clear();
        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .connectionClosed();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
      },
    );

    testWidgets('does not open the keyboard after a touch drag', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
    });

    testWidgets('does not open the keyboard after a touch tap when read only', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              readOnly: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
    });

    testWidgets(
      'does not open the keyboard after a touch tap when tapToShowKeyboard '
      'is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        // The handler uses autofocus: true, which triggers _onFocusChange.
        // With tapToShowKeyboard off, the connection is attached but not shown.
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        final target =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        await tester.tapAt(target);
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('does not reopen the keyboard on focus restoration when '
        'tapToShowKeyboard is false', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final outerFocusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outerFocusNode,
                  child: const SizedBox(
                    width: 50,
                    height: 50,
                    key: ValueKey('other'),
                  ),
                ),
                Expanded(
                  child: TerminalTextInputHandler(
                    terminal: terminal,
                    focusNode: focusNode,
                    deleteDetection: true,
                    tapToShowKeyboard: false,
                    child: const SizedBox.expand(
                      key: ValueKey('terminal-child'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      // Move focus away from the terminal.
      outerFocusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Restore focus to the terminal (simulates popup menu close or
      // programmatic focus restore).  Keyboard must stay hidden.
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      focusNode.dispose();
      outerFocusNode.dispose();
    });

    testWidgets(
      'requestKeyboard still shows keyboard when tapToShowKeyboard is false',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                tapToShowKeyboard: false,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        await tester.pump();
        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        // Explicit requestKeyboard (the toolbar button path) must always work.
        controller.requestKeyboard();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isTrue);

        focusNode.dispose();
      },
    );

    testWidgets('does not open the keyboard after a suppressed touch tap', (
      tester,
    ) async {
      final terminal = Terminal();
      final focusNode = FocusNode();
      final controller = TerminalTextInputHandlerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              controller: controller,
              deleteDetection: true,
              child: const SizedBox.expand(key: ValueKey('terminal-child')),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.hide();
      await tester.pump();

      expect(tester.testTextInput.isVisible, isFalse);

      controller.suppressNextTouchKeyboardRequest();
      final target =
          tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
          const Offset(40, 40);
      await tester.tapAt(target);
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tapAt(target);
      await tester.pump();

      expect(tester.testTextInput.isVisible, isTrue);

      focusNode.dispose();
    });

    testWidgets(
      'does not open the keyboard after a multitouch gesture when the last finger stays still',
      (tester) async {
        final terminal = Terminal();
        final focusNode = FocusNode();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                child: const SizedBox.expand(key: ValueKey('terminal-child')),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        tester.testTextInput.hide();
        await tester.pump();

        expect(tester.testTextInput.isVisible, isFalse);

        final origin =
            tester.getTopLeft(find.byType(TerminalTextInputHandler)) +
            const Offset(40, 40);
        final firstGesture = await tester.createGesture(pointer: 1);
        await firstGesture.down(origin);
        await tester.pump();

        final secondGesture = await tester.createGesture(pointer: 2);
        await secondGesture.down(origin + const Offset(20, 0));
        await tester.pump();
        await secondGesture.moveBy(const Offset(0, 80));
        await tester.pump();
        await secondGesture.up();
        await tester.pump();
        await firstGesture.up();
        await tester.pump();

        expect(focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isFalse);

        focusNode.dispose();
      },
    );

    testWidgets('reviews suspicious multi-character IME insertion', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onReviewInsertedText: (review) {
                reviews.add(review);
                return decision.future;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready; rm -rf /',
          selection: TextSelection.collapsed(offset: 21),
        ),
      );
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, 'echo ready; rm -rf /');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(_terminalStateFromEvents(terminalOutput), (
        text: 'echo ready; rm -rf /',
        cursorOffset: 'echo ready; rm -rf '.length,
      ));

      focusNode.dispose();
    });

    testWidgets(
      'reviews a suspicious committed IME payload after composition ends',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
            composing: TextRange(start: 2, end: 21),
          ),
        );
        await tester.pump();

        expect(reviews, isEmpty);
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, 'echo ready; rm -rf /');
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(_terminalStateFromEvents(terminalOutput), (
          text: 'echo ready; rm -rf /',
          cursorOffset: 'echo ready; rm -rf '.length,
        ));

        focusNode.dispose();
      },
    );

    testWidgets('reviews a committed IME payload with a standalone ampersand', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      final decision = Completer<bool>();
      final reviews = <TerminalCommandReview>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              onReviewInsertedText: (review) {
                reviews.add(review);
                return decision.future;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready & echo done',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      await tester.pump();

      expect(reviews, hasLength(1));
      expect(reviews.single.command, 'echo ready & echo done');
      expect(
        reviews.single.reasons,
        contains(TerminalCommandReviewReason.shellChaining),
      );
      expect(terminalOutput, isEmpty);

      decision.complete(true);
      await tester.pump();
      await tester.pump();

      expect(terminalOutput.join(), 'echo ready & echo done');

      focusNode.dispose();
    });

    testWidgets(
      'reviews a suspicious committed IME payload while keeping its selection',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        const suspiciousUserText = 'echo ready; rm -rf /';
        const suspiciousText = '\u200B\u200Becho ready; rm -rf /';
        const suspiciousSelection = TextSelection(
          baseOffset: _deleteDetectionMarker.length,
          extentOffset: suspiciousText.length,
        );

        tester.testTextInput.log.clear();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, suspiciousUserText);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
        expect(terminalOutput, isEmpty);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), suspiciousUserText);

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: suspiciousText,
            selection: suspiciousSelection,
          ),
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );

    testWidgets('rejects suspicious IME insertion until the user approves', (
      tester,
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
              onReviewInsertedText: (_) async => false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho ready\necho deploy',
          selection: TextSelection.collapsed(offset: 24),
        ),
      );
      await tester.pump();
      await tester.pump();

      final client =
          tester.state(find.byType(TerminalTextInputHandler))
              as TextInputClient;
      expect(terminalOutput, isEmpty);
      expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

      focusNode.dispose();
    });

    testWidgets(
      'reviews IME insertions against the full terminal line context',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) async {
                  reviews.add(review);
                  return false;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        const existingCommand = 'echo ready &';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await tester.pump();
        }

        reviews.clear();

        const combinedCommand = '$existingCommand echo done';
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker$combinedCommand',
            selection: TextSelection.collapsed(
              offset: _deleteDetectionMarker.length + combinedCommand.length,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), existingCommand);
        expect(reviews, hasLength(1));
        expect(reviews.single.command, combinedCommand);
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'ignores stale review approvals when a newer editing value arrives',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bls',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalOutput.join(), 'ls');

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue?.text,
          '${_deleteDetectionMarker}ls',
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'ignores stale review approvals after an external IME buffer clear',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();
        final decision = Completer<bool>();
        final reviews = <TerminalCommandReview>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                onReviewInsertedText: (review) {
                  reviews.add(review);
                  return decision.future;
                },
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(terminalOutput, isEmpty);

        controller.clearImeBuffer();
        await tester.pump();

        final client = _terminalTextInputClient(tester);
        expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(terminalOutput, isEmpty);
        expect(client.currentTextEditingValue?.text, _deleteDetectionMarker);

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a swipe-leading space even when a composing update is overwritten in the review queue',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final decision = Completer<bool>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                onReviewInsertedText: (_) => decision.future,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Becho ready; rm -rf /',
            selection: TextSelection.collapsed(offset: 21),
          ),
        );
        await tester.pump();

        expect(terminalOutput, isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B hello',
            selection: TextSelection.collapsed(offset: 8),
            composing: TextRange(start: 2, end: 8),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B hello',
            selection: TextSelection.collapsed(offset: 8),
          ),
        );
        await tester.pump();

        decision.complete(true);
        await tester.pump();
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'hello');
        expect(_terminalStateFromEvents(terminalOutput), (
          text: 'hello',
          cursorOffset: 'hello'.length,
        ));

        focusNode.dispose();
      },
    );

    testWidgets(
      'reviews IME insertions against terminal state after input resets',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final reviews = <TerminalCommandReview>[];
        var readOnly = false;

        Widget buildHandler() => MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              readOnly: readOnly,
              buildReviewTextForInsertedText: (delta, currentText) =>
                  applyTerminalInputDelta(
                    currentText: _terminalTextFromEvents(terminalOutput),
                    cursorOffset: _terminalTextFromEvents(
                      terminalOutput,
                    ).length,
                    deletedCount: delta.deletedCount,
                    appendedText: delta.appendedText,
                  ),
              onReviewInsertedText: (review) async {
                reviews.add(review);
                return false;
              },
              child: const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(buildHandler());

        focusNode.requestFocus();
        await tester.pump();

        const existingCommand = 'echo ready &';
        for (var index = 1; index <= existingCommand.length; index++) {
          final currentCommand = existingCommand.substring(0, index);
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: '$_deleteDetectionMarker$currentCommand',
              selection: TextSelection.collapsed(
                offset: _deleteDetectionMarker.length + currentCommand.length,
              ),
            ),
          );
          await tester.pump();
        }

        readOnly = true;
        await tester.pumpWidget(buildHandler());
        await tester.pump();

        readOnly = false;
        await tester.pumpWidget(buildHandler());
        await tester.pump();

        reviews.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker echo done',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(reviews, hasLength(1));
        expect(reviews.single.command, 'echo ready & echo done');
        expect(
          reviews.single.reasons,
          contains(TerminalCommandReviewReason.shellChaining),
        );
        expect(_terminalTextFromEvents(terminalOutput), existingCommand);

        focusNode.dispose();
      },
    );
  });

  group('shouldRequestKeyboardForTerminalPointerUp', () {
    test('requests the keyboard for a tap-like first touch pointer', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('suppresses the keyboard after touch movement beyond tap slop', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: true,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard for additional touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 2,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('suppresses the keyboard after a multitouch gesture sequence', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: true,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isFalse,
      );
    });

    test('still requests the keyboard for non-touch pointers', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.mouse,
          activeTouchPointers: 0,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: false,
        ),
        isTrue,
      );
    });

    test('never requests the keyboard when input is read only', () {
      expect(
        shouldRequestKeyboardForTerminalPointerUp(
          pointerKind: PointerDeviceKind.touch,
          activeTouchPointers: 1,
          hadMultipleTouchPointers: false,
          movedBeyondTapSlop: false,
          readOnly: true,
        ),
        isFalse,
      );
    });
  });

  group('TerminalTextInputHandler compared with TextField', () {
    testWidgets(
      'matches TextField user state for collapsed caret moves while issuing one terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state when a replacement selection collapses elsewhere',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'echo teh world',
            selection: TextSelection.collapsed(offset: 14),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection(baseOffset: 5, extentOffset: 8),
          ),
          const TextEditingValue(
            text: 'echo the world',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, [textFieldResult.finalState]);
      },
    );

    testWidgets(
      'matches TextField user state after deleting newer text, replacing earlier text, and moving again',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        // The deletion-triggered buffer reset in step 2 first echoes the
        // cleared IME state, then the later collapsed-caret move resyncs the
        // current user state.
        expect(terminalResult.echoedStates, [
          (
            text: '',
            selectionBase: 0,
            selectionExtent: 0,
            composingBase: -1,
            composingExtent: -1,
          ),
          textFieldResult.finalState,
        ]);
      },
    );

    testWidgets(
      'matches TextField replacement finalization without an extra terminal resync',
      (tester) async {
        final sequence = <TextEditingValue>[
          const TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          const TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ];

        final textFieldResult = await _runTextFieldSequence(tester, sequence);
        final terminalResult = await _runTerminalSequence(tester, sequence);

        expect(terminalResult.finalState, textFieldResult.finalState);
        expect(textFieldResult.echoedStates, isEmpty);
        expect(terminalResult.echoedStates, isEmpty);
      },
    );

    final matrixScenarios = <_MatrixScenario>[
      (
        name: 'matches insertion at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'foo bar',
            selection: TextSelection.collapsed(offset: 7),
          ),
          TextEditingValue(
            text: 'foo bar',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'foo Xbar',
            selection: TextSelection.collapsed(offset: 5),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches beginning-of-line insertion',
        sequence: const [
          TextEditingValue(
            text: 'hello',
            selection: TextSelection.collapsed(offset: 5),
          ),
          TextEditingValue(
            text: 'hello',
            selection: TextSelection.collapsed(offset: 0),
          ),
          TextEditingValue(
            text: 'Xhello',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches identical-character insertion at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'aaaa',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'aaaa',
            selection: TextSelection.collapsed(offset: 1),
          ),
          TextEditingValue(
            text: 'aaaaa',
            selection: TextSelection.collapsed(offset: 2),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches punctuation replacement at a moved caret',
        sequence: const [
          TextEditingValue(
            text: 'hello, world',
            selection: TextSelection.collapsed(offset: 12),
          ),
          TextEditingValue(
            text: 'hello, world',
            selection: TextSelection.collapsed(offset: 6),
          ),
          TextEditingValue(
            text: 'hello; world',
            selection: TextSelection.collapsed(offset: 6),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches emoji insertion after a caret move',
        sequence: const [
          TextEditingValue(
            text: 'a🎉b',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'a🎉b',
            selection: TextSelection.collapsed(offset: 1),
          ),
          TextEditingValue(
            text: 'aX🎉b',
            selection: TextSelection.collapsed(offset: 2),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name: 'matches earlier-word replacement after deleting newer text',
        sequence: const [
          TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          TextEditingValue(
            text: 'teh ',
            selection: TextSelection.collapsed(offset: 4),
          ),
          TextEditingValue(
            text: 'the ',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          TextEditingValue(
            text: 'the ',
            selection: TextSelection.collapsed(offset: 4),
          ),
        ],
        textFieldEchoes: 0,
        terminalEchoes: 1,
      ),
      (
        name:
            'matches earlier-word replacement after partially deleting newer text',
        sequence: const [
          TextEditingValue(
            text: 'teh world ',
            selection: TextSelection.collapsed(offset: 10),
          ),
          TextEditingValue(
            text: 'teh wo',
            selection: TextSelection.collapsed(offset: 6),
          ),
          TextEditingValue(
            text: 'the wo',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
          TextEditingValue(
            text: 'the wo',
            selection: TextSelection.collapsed(offset: 6),
          ),
        ],
        textFieldEchoes: null,
        terminalEchoes: null,
      ),
      ..._buildFlutterReplacedParityScenarios(),
      ..._buildFlutterDeltaParityScenarios(),
      ..._buildFlutterComposingParityScenarios(),
      ..._buildGeneratedComparisonScenarios(),
      ..._buildGptComparisonScenarios(),
    ];

    for (final scenario in matrixScenarios) {
      testWidgets(scenario.name, (tester) async {
        await _expectTextFieldComparisonScenario(
          tester,
          sequence: scenario.sequence,
          expectedTextFieldEchoCount: scenario.textFieldEchoes,
          expectedTerminalEchoCount: scenario.terminalEchoes,
        );
      });
    }

    final opusResetScenarios = _buildOpusResetScenarios();

    for (final scenario in opusResetScenarios) {
      testWidgets(scenario.name, (tester) async {
        await _expectResetContinuationScenario(tester, scenario);
      });
    }

    testWidgets('clears the IME buffer after trailing backspace', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();
      tester.testTextInput.log.clear();

      // Type "hello".
      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 5),
      );
      await tester.pump();

      tester.testTextInput.log.clear();

      // Backspace to "hell".
      tester.testTextInput.updateEditingValue(
        _editingValue('hell', selectionOffset: 4),
      );
      await tester.pump();

      // The terminal should show "hell".
      expect(_terminalTextFromEvents(terminalOutput), 'hell');

      // The IME buffer should be cleared after the backspace.
      expect(
        tester.testTextInput.log
            .where((call) => call.method == 'TextInput.setEditingState')
            .length,
        1,
      );

      // The editing state is reset to the marker only so suggestions start
      // fresh from the next typed character.
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      focusNode.dispose();
    });

    testWidgets('typing after trailing backspace inserts from a fresh buffer', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      // Type "hello".
      tester.testTextInput.updateEditingValue(
        _editingValue('hello', selectionOffset: 5),
      );
      await tester.pump();

      // Backspace to "hell".
      tester.testTextInput.updateEditingValue(
        _editingValue('hell', selectionOffset: 4),
      );
      await tester.pump();

      // Type "o" from the freshly cleared IME buffer.
      tester.testTextInput.updateEditingValue(
        _editingValue('o', selectionOffset: 1),
      );
      await tester.pump();

      // The terminal should show "hello".
      expect(_terminalTextFromEvents(terminalOutput), 'hello');

      focusNode.dispose();
    });

    testWidgets(
      'clears the IME buffer after deleting a corrected contraction tail',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue("didn't", selectionOffset: "didn't".length),
        );
        await tester.pump();

        tester.testTextInput.log.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'didn');

        final client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading swipe space after backspace-triggered IME buffer clear',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        // Type "hello".
        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        // Backspace to "hell".
        tester.testTextInput.updateEditingValue(
          _editingValue('hell', selectionOffset: 4),
        );
        await tester.pump();

        // Swipe-type " world" from the cleared IME buffer.
        await _commitSwipeText(tester, '$_deleteDetectionMarker world');
        await tester.pump();

        // The cleared IME buffer should not keep suggesting continuations from
        // the deleted word. Because the terminal text before the cursor does
        // not end in whitespace, the leading swipe space is trimmed.
        expect(_terminalStateFromEvents(terminalOutput).text, 'hellworld');

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading suggestion space after backspace-triggered IME buffer clear',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didnt', selectionOffset: 'didnt'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'didntest');

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves the shortened prefix when a delete-reset continuation resumes the same word with the live terminal prefix',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'didn',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didnt', selectionOffset: 'didnt'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('didn', selectionOffset: 'didn'.length),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '$_deleteDetectionMarker test',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'didntest');

        focusNode.dispose();
      },
    );

    testWidgets(
      'replaces a shortened first word after backspace without duplicating the prefix',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bte',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B the ',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'teh ',
            initialCursorOffset: 'teh '.length,
          ),
          (text: 'the ', cursorOffset: 'the '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves a new separator when a trailing-backspace reset is followed by a same-initial unrelated committed word',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'shel',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('shell', selectionOffset: 5),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('shel', selectionOffset: 4),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue(' story ', selectionOffset: 7),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'shel',
            initialCursorOffset: 'shel'.length,
          ),
          (text: 'shel story ', cursorOffset: 'shel story '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves the deleted suffix when a trailing-backspace reset resumes the same word and continues into the next word',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'thin',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('things', selectionOffset: 6),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('thin', selectionOffset: 4),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue(' gs are ', selectionOffset: 8),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'thin',
            initialCursorOffset: 'thin'.length,
          ),
          (text: 'things are ', cursorOffset: 'things are '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'keeps the shortened prefix when later delete-reset words only share letters with the deleted suggestion',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'what do we t',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'what do we thinking',
            selectionOffset: 'what do we thinking'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('what do we t', selectionOffset: 'what do we t'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            ' whatever considering ',
            selectionOffset: ' whatever considering '.length,
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'what do we t',
            initialCursorOffset: 'what do we t'.length,
          ),
          (
            text: 'what do we t whatever considering ',
            cursorOffset: 'what do we t whatever considering '.length,
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'drops a stale one-letter delete-reset fragment before the next word',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'what do we t',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue(
            'what do we thinking',
            selectionOffset: 'what do we thinking'.length,
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('what do we t', selectionOffset: 'what do we t'.length),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          _editingValue('s whatever ', selectionOffset: 's whatever '.length),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'what do we t',
            initialCursorOffset: 'what do we t'.length,
          ),
          (
            text: 'what do we t whatever ',
            cursorOffset: 'what do we t whatever '.length,
          ),
        );
        expect(
          _terminalTextInputClient(tester).currentTextEditingValue,
          const TextEditingValue(
            text: '$_deleteDetectionMarker whatever ',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'trims a leading IME separator during delete-reset replacement when the live terminal prefix is visible',
      (tester) async {
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
                resolveTextBeforeCursor: () => 'te',
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bte',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200B the ',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'teh ',
            initialCursorOffset: 'teh '.length,
          ),
          (text: 'the ', cursorOffset: 'the '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves a manual separator when replacing a swiped word after backspacing into it',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '$_deleteDetectionMarker teh');

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}teh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}te',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}the ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'teh ',
            initialCursorOffset: 'teh '.length,
          ),
          (text: 'the ', cursorOffset: 'the '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'preserves an IME separator when replacing a swiped word after backspacing into it',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        await _commitSwipeText(tester, '${_deleteDetectionMarker}teh ');

        terminalOutput.clear();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}te',
            selection: TextSelection.collapsed(offset: 4),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '${_deleteDetectionMarker}the ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(
          _terminalStateFromEvents(
            terminalOutput,
            initialText: 'teh ',
            initialCursorOffset: 'teh '.length,
          ),
          (text: 'the ', cursorOffset: 'the '.length),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not force-resync the IME during replacement after deleting a later word',
      (tester) async {
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
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh world ',
            selection: TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bteh ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        tester.testTextInput.log.clear();

        (tester.state(find.byType(TerminalTextInputHandler)) as TextInputClient)
            .updateEditingValue(
              const TextEditingValue(
                text: '\u200B\u200Bthe ',
                selection: TextSelection(baseOffset: -1, extentOffset: 0),
              ),
            );
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200B\u200Bthe ',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'the ');
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );

        focusNode.dispose();
      },
    );

    testWidgets('trims a leading suggestion space after a committed newline', (
      tester,
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
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200B\u200Becho hi\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '$_deleteDetectionMarker next',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();

      expect(_terminalTextFromEvents(terminalOutput), 'echo hi\nnext');

      focusNode.dispose();
    });

    testWidgets('resets IME editing state after modifier chord character', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final focusNode = FocusNode();
      var modifierActive = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalTextInputHandler(
              terminal: terminal,
              focusNode: focusNode,
              deleteDetection: true,
              hasActiveToolbarModifier: () => modifierActive,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      // Type "ls" normally.
      tester.testTextInput.updateEditingValue(
        _editingValue('ls', selectionOffset: 2),
      );
      await tester.pump();
      expect(_terminalTextFromEvents(terminalOutput), 'ls');

      // Activate Ctrl modifier (simulating toolbar toggle).
      modifierActive = true;

      // Type 'c' with modifier active (would produce Ctrl+C in practice).
      tester.testTextInput.updateEditingValue(
        _editingValue('lsc', selectionOffset: 3),
      );
      await tester.pump();

      // The IME editing state should be fully reset after the modified
      // character (control codes make the terminal state unpredictable).
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: _deleteDetectionMarker,
          selection: TextSelection.collapsed(offset: 2),
        ),
      );

      focusNode.dispose();
    });

    testWidgets(
      'controller clears the IME buffer after external terminal actions',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        controller.clearImeBuffer();
        await tester.pump();

        final client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'resets IME after second character of a two-part chord (tmux Ctrl+b, c)',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                hasActiveToolbarModifier: () => modifierActive,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        // Step 1: Ctrl+b (modifier active, type 'b').
        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();

        // Modifier consumed (one-shot).
        modifierActive = false;

        // After Ctrl+b the buffer should be fully reset.
        var client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 2: 'c' within the chord window (< 500 ms).
        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();

        // The follow-up character should also trigger a full reset.
        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Step 3: Type normally — 'l' should accumulate (no more chord).
        tester.testTextInput.updateEditingValue(
          _editingValue('l', selectionOffset: 1),
        );
        await tester.pump();

        // Normal typing accumulates in the buffer.
        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}l',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets(
      'typing copilot after tmux Ctrl+b, c keeps the leading c when space is pressed',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        final controller = TerminalTextInputHandlerController();
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                controller: controller,
                deleteDetection: true,
                resolveTextBeforeCursor: () => '>',
                hasActiveToolbarModifier: () => modifierActive,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();
        modifierActive = false;

        fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();

        terminalOutput.clear();
        tester.testTextInput.log.clear();
        controller.handleExternalTerminalOutput();
        await tester.pump();

        for (var index = 1; index <= 'copilot'.length; index++) {
          final text = 'copilot'.substring(0, index);
          tester.testTextInput.updateEditingValue(
            _editingValue(text, selectionOffset: index),
          );
          await tester.pump();
        }

        tester.testTextInput.updateEditingValue(
          _editingValue('c opilot ', selectionOffset: 'c opilot '.length),
        );
        await tester.pump();

        expect(_terminalTextFromEvents(terminalOutput), 'copilot ');

        focusNode.dispose();
      },
    );

    testWidgets(
      'does not reset after modifier chord when follow-up arrives after timeout',
      (tester) async {
        final terminalOutput = <String>[];
        final terminal = Terminal(onOutput: terminalOutput.add);
        final focusNode = FocusNode();
        var modifierActive = false;
        var fakeNow = DateTime(2026);
        debugSetModifierChordClock(() => fakeNow);
        addTearDown(() => debugSetModifierChordClock(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalTextInputHandler(
                terminal: terminal,
                focusNode: focusNode,
                deleteDetection: true,
                hasActiveToolbarModifier: () => modifierActive,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );

        focusNode.requestFocus();
        await tester.pump();

        // Ctrl+C (standalone modifier chord).
        modifierActive = true;
        tester.testTextInput.updateEditingValue(
          _editingValue('c', selectionOffset: 1),
        );
        await tester.pump();
        modifierActive = false;

        // Buffer is reset after Ctrl+C.
        var client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );

        // Advance past the chord window (> 500 ms).
        fakeNow = fakeNow.add(const Duration(milliseconds: 600));

        // Type 'l' — this should accumulate normally because the chord
        // window has expired.
        tester.testTextInput.updateEditingValue(
          _editingValue('l', selectionOffset: 1),
        );
        await tester.pump();

        client = _terminalTextInputClient(tester);
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: '${_deleteDetectionMarker}l',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );

        focusNode.dispose();
      },
    );

    testWidgets('regular typing accumulates in IME buffer without reset', (
      tester,
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
              hasActiveToolbarModifier: () => false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      // Type "hello" one character at a time.
      for (var i = 1; i <= 5; i++) {
        tester.testTextInput.updateEditingValue(
          _editingValue('hello'.substring(0, i), selectionOffset: i),
        );
        await tester.pump();
      }

      // The terminal should have "hello".
      expect(_terminalTextFromEvents(terminalOutput), 'hello');

      // The IME editing state should still have the full accumulated text.
      final client = _terminalTextInputClient(tester);
      expect(
        client.currentTextEditingValue,
        const TextEditingValue(
          text: '${_deleteDetectionMarker}hello',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );

      focusNode.dispose();
    });
  });
}
