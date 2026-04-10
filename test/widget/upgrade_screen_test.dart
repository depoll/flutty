// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/presentation/screens/upgrade_screen.dart';

class _MockMonetizationService extends Mock implements MonetizationService {}

Future<MonetizationActionResult> _cancelledPurchaseResult(Invocation _) =>
    Future.value(
      const MonetizationActionResult.cancelled('Purchase cancelled.'),
    );

Future<MonetizationActionResult> _restoredPurchaseResult(Invocation _) =>
    Future.value(const MonetizationActionResult.success('Restored purchases.'));

void main() {
  testWidgets('selected plan stays legible in dark mode', (tester) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro_monthly',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$5.00',
          displayPriceLabel: r'$5.00 / month',
          rawPrice: 5,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro_annual',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$50.00',
          displayPriceLabel: r'$50.00 / year',
          rawPrice: 50,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    when(service.restorePurchases).thenAnswer(_restoredPurchaseResult);

    final darkTheme = ThemeData.dark(useMaterial3: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          darkTheme: darkTheme,
          themeMode: ThemeMode.dark,
          home: const UpgradeScreen(),
        ),
      ),
    );
    await tester.pump();

    final monthlyCard = tester.widget<Card>(
      find.ancestor(of: find.text('Monthly'), matching: find.byType(Card)),
    );
    final monthlyTitle = tester.widget<Text>(find.text('Monthly'));
    final monthlyShape = monthlyCard.shape! as RoundedRectangleBorder;
    final monthlyTile = tester.widget<RadioListTile<String>>(
      find.byType(RadioListTile<String>).first,
    );

    expect(
      monthlyCard.color,
      isNot(equals(darkTheme.colorScheme.secondaryContainer)),
    );
    expect(monthlyTitle.style?.color, equals(darkTheme.colorScheme.onSurface));
    expect(monthlyShape.side.color, equals(darkTheme.colorScheme.primary));
    expect(monthlyShape.side.width, 2);
    expect(monthlyTile.selected, isFalse);
  });
}
