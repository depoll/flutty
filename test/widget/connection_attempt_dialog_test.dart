// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_attempt_dialog.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockMonetizationService extends Mock implements MonetizationService {}

const _freeMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

/// Stalls until the caller cancels, mirroring an unresponsive SSH endpoint.
class _StalledSshService extends SshService {
  final Completer<void> connectStarted = Completer<void>();

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    if (!connectStarted.isCompleted) {
      connectStarted.complete();
    }
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Opening network connection…',
      ),
    );
    await cancellationToken!.cancelled;
    return const SshConnectionResult.userCancelled();
  }
}

Host _host() => Host(
  id: 42,
  label: 'stalled box',
  hostname: 'stalled.example.com',
  port: 22,
  username: 'tester',
  isFavorite: false,
  autoConnectRequiresConfirmation: false,
  autoForwardPorts: false,
  sortOrder: 0,
  createdAt: DateTime(2024),
  updatedAt: DateTime(2024),
);

void main() {
  group('connectToHostWithProgressDialog', () {
    testWidgets('cancels a stalled connection from the dialog', (tester) async {
      final sshService = _StalledSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final monetizationService = _MockMonetizationService();
      when(
        () => monetizationService.currentState,
      ).thenReturn(_freeMonetizationState);

      SshConnectionResult? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshServiceProvider.overrideWithValue(sshService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_freeMonetizationState),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    result = await connectToHostWithProgressDialog(
                      context,
                      ref,
                      _host(),
                    );
                  },
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await sshService.connectStarted.future;
      await tester.pump();

      expect(find.text('Connecting to stalled box'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.cancelled, isTrue);
      expect(result!.success, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('cancels a stalled connection from a back gesture', (
      tester,
    ) async {
      final sshService = _StalledSshService();
      final hostRepository = _MockHostRepository();
      when(() => hostRepository.getById(any())).thenAnswer((_) async => null);
      final monetizationService = _MockMonetizationService();
      when(
        () => monetizationService.currentState,
      ).thenReturn(_freeMonetizationState);

      SshConnectionResult? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sshServiceProvider.overrideWithValue(sshService),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_freeMonetizationState),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () async {
                    result = await connectToHostWithProgressDialog(
                      context,
                      ref,
                      _host(),
                    );
                  },
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Connect'));
      await tester.pump();
      await sshService.connectStarted.future;
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.cancelled, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
