// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/presentation/widgets/acp_custom_provider_editor.dart';

class _RecordingProviderService extends Fake implements AcpProviderService {
  final List<AcpCustomProviderDefinition> saved =
      <AcpCustomProviderDefinition>[];
  final List<String> removed = <String>[];

  @override
  Future<void> saveCustomProvider(
    AcpCustomProviderDefinition definition,
  ) async {
    saved.add(definition);
  }

  @override
  Future<void> removeCustomProvider(String id) async {
    removed.add(id);
  }
}

void main() {
  testWidgets('requires an explicit command review before saving', (
    tester,
  ) async {
    final service = _RecordingProviderService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAcpCustomProviderEditor(
                context,
                providerService: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'e.g. My agent'),
      'My Agent',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'e.g. my-agent'),
      'my-agent',
    );

    // Add one literal argument so shell flattening is impossible.
    await tester.tap(find.text('Add argument'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'arg 1'), 'acp');

    await tester.tap(find.widgetWithText(FilledButton, 'Review and add'));
    await tester.pumpAndSettle();

    // The exact command is shown for review before it is saved.
    expect(find.text('Review the exact command'), findsOneWidget);
    expect(find.text('my-agent'), findsWidgets);
    expect(find.text('  acp'), findsOneWidget);
    expect(service.saved, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve and add'));
    await tester.pumpAndSettle();

    expect(service.saved, hasLength(1));
    final definition = service.saved.single;
    expect(definition.label, 'My Agent');
    expect(definition.launchCommand.executable, 'my-agent');
    expect(definition.launchCommand.arguments, ['acp']);
    expect(definition.isCommandApproved, isTrue);
  });

  testWidgets('validates a blank name before showing the review', (
    tester,
  ) async {
    final service = _RecordingProviderService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAcpCustomProviderEditor(
                context,
                providerService: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'e.g. my-agent'),
      'my-agent',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Review and add'));
    await tester.pumpAndSettle();

    expect(find.text('Give this provider a name.'), findsOneWidget);
    expect(find.text('Review the exact command'), findsNothing);
    expect(service.saved, isEmpty);
  });
}
