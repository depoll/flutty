// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/presentation/widgets/acp_config_option_controls.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  testWidgets(
    'renders select + boolean and applies changes via generic setter',
    (tester) async {
      final calls = <(String, Object)>[];
      await _pump(
        tester,
        AcpConfigOptionControls(
          options: const [
            AcpSelectConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              currentValue: 'fast',
              options: [
                AcpConfigValue(value: 'fast', name: 'Fast'),
                AcpConfigValue(value: 'smart', name: 'Smart'),
              ],
            ),
            AcpBooleanConfigOption(
              id: 'yolo',
              name: 'Auto-approve',
              category: 'permissions',
              currentValue: false,
            ),
          ],
          onSetConfigOption: (id, value) async => calls.add((id, value)),
        ),
      );

      expect(find.widgetWithText(ListTile, 'Model'), findsOneWidget);
      expect(find.text('Auto-approve'), findsOneWidget);

      // Toggle the boolean.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(calls, contains(('yolo', true)));

      // Change the select via the value picker.
      await tester.tap(find.widgetWithText(ListTile, 'Model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smart'));
      await tester.pumpAndSettle();
      expect(calls, contains(('model', 'smart')));
    },
  );

  testWidgets('falls back to legacy mode only when no generic option exists', (
    tester,
  ) async {
    final modeCalls = <String>[];
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [],
        onSetConfigOption: (_, _) async {},
        modeState: const AcpSessionModeState(
          currentModeId: 'ask',
          availableModes: [
            AcpSessionMode(id: 'ask', name: 'Ask'),
            AcpSessionMode(id: 'auto', name: 'Auto'),
          ],
        ),
        onSetMode: (modeId) async => modeCalls.add(modeId),
      ),
    );

    expect(find.widgetWithText(ListTile, 'Mode'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto'));
    await tester.pumpAndSettle();
    expect(modeCalls, ['auto']);
  });

  testWidgets('surfaces an error when a setter fails', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpBooleanConfigOption(id: 'flag', name: 'Flag', currentValue: false),
        ],
        onSetConfigOption: (_, _) async => throw StateError('nope'),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Could not apply this setting.'), findsOneWidget);
  });

  testWidgets('disables controls when not enabled', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpBooleanConfigOption(id: 'flag', name: 'Flag', currentValue: true),
        ],
        onSetConfigOption: (_, _) async {},
        enabled: false,
      ),
    );

    final switchWidget = tester.widget<Switch>(find.byType(Switch));
    expect(switchWidget.onChanged, isNull);
  });

  testWidgets('renders unknown option types as a disabled row', (tester) async {
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpUnknownConfigOption(
            id: 'future',
            name: 'Future Setting',
            type: 'slider',
            raw: {},
          ),
        ],
        onSetConfigOption: (_, _) async {},
      ),
    );
    expect(find.text('Unsupported setting'), findsOneWidget);
  });

  testWidgets('dismissing the value picker applies no change', (tester) async {
    final calls = <(String, Object)>[];
    await _pump(
      tester,
      AcpConfigOptionControls(
        options: const [
          AcpSelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            currentValue: 'fast',
            options: [
              AcpConfigValue(value: 'fast', name: 'Fast'),
              AcpConfigValue(value: 'smart', name: 'Smart'),
            ],
          ),
        ],
        onSetConfigOption: (id, value) async => calls.add((id, value)),
      ),
    );

    await tester.tap(find.widgetWithText(ListTile, 'Model'));
    await tester.pumpAndSettle();
    // Dismiss the value sheet without choosing (tap the scrim).
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
