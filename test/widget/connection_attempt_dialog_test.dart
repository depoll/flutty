import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_attempt_dialog.dart';

const _proState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

final _host = Host(
  id: 1,
  label: 'Build Server',
  hostname: 'build.example.com',
  port: 22,
  username: 'developer',
  isFavorite: false,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
  autoConnectRequiresConfirmation: false,
  sortOrder: 0,
);

class _MockMonetizationService extends Mock implements MonetizationService {}

MonetizationService _buildMonetizationService() {
  final service = _MockMonetizationService();
  when(() => service.currentState).thenReturn(_proState);
  return service;
}

class _RetryActiveSessionsNotifier extends ActiveSessionsNotifier {
  _RetryActiveSessionsNotifier({
    required this.succeedsOnRetry,
    this.retryCompleter,
    this.retryStartGate,
  });

  final bool succeedsOnRetry;
  final Completer<SshConnectionResult>? retryCompleter;
  final Completer<void>? retryStartGate;
  final List<bool> forceNewValues = [];
  ConnectionAttemptStatus? attempt;
  bool cleared = false;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{};

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => attempt;

  @override
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    forceNewValues.add(forceNew);
    if (succeedsOnRetry && forceNewValues.length > 1) {
      await retryStartGate?.future;
      final completer = retryCompleter;
      if (completer != null) {
        attempt = const ConnectionAttemptStatus(
          hostId: 1,
          state: SshConnectionState.connecting,
          latestMessage: 'Retrying connection',
          logLines: ['Preparing connection...', 'Retrying connection'],
        );
        state = {...state};
        return completer.future;
      }
      attempt = const ConnectionAttemptStatus(
        hostId: 1,
        state: SshConnectionState.connected,
        latestMessage: 'Connected',
        logLines: ['Preparing connection...', 'Connected'],
      );
      state = {42: SshConnectionState.connected};
      return const SshConnectionResult(success: true, connectionId: 42);
    }

    attempt = const ConnectionAttemptStatus(
      hostId: 1,
      state: SshConnectionState.error,
      latestMessage: 'Authentication failed',
      logLines: ['Preparing connection...', 'Authentication failed'],
    );
    state = {...state};
    return const SshConnectionResult(
      success: false,
      error: 'Authentication failed',
    );
  }

  @override
  void clearConnectionAttempt(int hostId) {
    cleared = true;
    attempt = null;
    state = {...state};
  }
}

class _ConnectButton extends ConsumerWidget {
  const _ConnectButton({required this.onResult});

  final ValueChanged<SshConnectionResult> onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton(
    onPressed: () => unawaited(
      connectToHostWithProgressDialog(
        context,
        ref,
        _host,
        forceNew: false,
      ).then(onResult),
    ),
    child: const Text('Connect'),
  );
}

void main() {
  test('returns stage-specific connection recovery guidance', () {
    expect(
      connectionFailureRecoveryHint('Host key changed'),
      'Review the host key details before retrying.',
    );
    expect(
      connectionFailureRecoveryHint('Authentication failed'),
      'Check the username, password, and SSH key, then retry.',
    );
    expect(
      connectionFailureRecoveryHint('Connection refused'),
      'Check the hostname, port, and network, then retry.',
    );
  });

  testWidgets('retry returns the successful connection result', (tester) async {
    final notifier = _RetryActiveSessionsNotifier(succeedsOnRetry: true);
    final monetizationService = _buildMonetizationService();
    SshConnectionResult? result;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionsProvider.overrideWith(() => notifier),
          monetizationServiceProvider.overrideWithValue(monetizationService),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proState),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: _ConnectButton(onResult: (value) => result = value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Edit Host'), findsOneWidget);
    expect(
      find.text('Check the username, password, and SSH key, then retry.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(result?.success, isTrue);
    expect(result?.connectionId, 42);
    expect(notifier.forceNewValues, [false, true]);
    expect(notifier.cleared, isTrue);
    expect(find.text('Connection failed'), findsNothing);
  });

  testWidgets('retry synchronously disables dismissal actions', (tester) async {
    final retryCompleter = Completer<SshConnectionResult>();
    final retryStartGate = Completer<void>();
    final notifier = _RetryActiveSessionsNotifier(
      succeedsOnRetry: true,
      retryCompleter: retryCompleter,
      retryStartGate: retryStartGate,
    );
    final monetizationService = _buildMonetizationService();
    SshConnectionResult? result;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionsProvider.overrideWith(() => notifier),
          monetizationServiceProvider.overrideWithValue(monetizationService),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proState),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: _ConnectButton(onResult: (value) => result = value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(find.text('Retrying…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Edit Host'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Retrying…'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<PopScope<Object?>>(find.byType(PopScope)).canPop,
      isFalse,
    );

    retryStartGate.complete();
    await tester.pump();
    retryCompleter.complete(
      const SshConnectionResult(success: true, connectionId: 42),
    );
    await tester.pumpAndSettle();

    expect(result?.success, isTrue);
  });

  testWidgets('Edit Host opens the failed host without losing the result', (
    tester,
  ) async {
    final notifier = _RetryActiveSessionsNotifier(succeedsOnRetry: false);
    final monetizationService = _buildMonetizationService();
    SshConnectionResult? result;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: _ConnectButton(onResult: (value) => result = value),
          ),
        ),
        GoRoute(
          path: '/hosts/edit/:hostId',
          builder: (context, state) => Scaffold(
            body: Text('Editing host ${state.pathParameters['hostId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeSessionsProvider.overrideWith(() => notifier),
          monetizationServiceProvider.overrideWithValue(monetizationService),
          monetizationStateProvider.overrideWith(
            (ref) => Stream.value(_proState),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Host'));
    await tester.pumpAndSettle();

    expect(find.text('Editing host 1'), findsOneWidget);
    expect(notifier.cleared, isTrue);
    expect(result, isNull);

    router.pop();
    await tester.pumpAndSettle();

    expect(result?.success, isFalse);
    expect(result?.error, 'Authentication failed');
  });
}
