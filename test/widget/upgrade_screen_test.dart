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
  testWidgets('plan cards stay legible in dark mode', (tester) async {
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
      activeOfferId: 'monthly',
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
    final annualSavingsBanner = tester.widget<Text>(
      find.text(
        'Annual is the best value - save about 17% compared with paying monthly.',
      ),
    );
    await tester.scrollUntilVisible(find.text('Monthly'), 300);
    await tester.pumpAndSettle();

    final monthlyCardFinder = find.ancestor(
      of: find.text('Monthly'),
      matching: find.byType(Card),
    );
    final monthlyCard = tester.widget<Card>(monthlyCardFinder);
    final monthlyTitle = tester.widget<Text>(find.text('Monthly').first);
    final monthlyShape = monthlyCard.shape! as RoundedRectangleBorder;
    final currentPill = tester.widget<Text>(find.text('Current'));
    final currentAction = tester.widget<Text>(find.text('Manage current plan'));
    final bestValuePill = tester.widget<Text>(
      find.text('Best value - Save 17%'),
    );
    final annualAction = tester.widget<Text>(find.text('Subscribe annual'));

    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(
      find.descendant(
        of: monthlyCardFinder,
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
    expect(monthlyTitle.style?.color, equals(darkTheme.colorScheme.onSurface));
    expect(monthlyShape.side.color, equals(darkTheme.colorScheme.primary));
    expect(monthlyShape.side.width, 3);
    expect(find.text('Current'), findsOneWidget);
    expect(
      currentPill.style?.color,
      equals(darkTheme.colorScheme.onPrimaryContainer),
    );
    expect(
      currentAction.style?.color,
      equals(darkTheme.colorScheme.onPrimaryContainer),
    );
    expect(
      annualSavingsBanner.style?.color,
      equals(darkTheme.colorScheme.onSecondaryContainer),
    );
    expect(
      bestValuePill.style?.color,
      equals(darkTheme.colorScheme.onSecondaryContainer),
    );
    expect(
      annualAction.style?.color,
      equals(darkTheme.colorScheme.onSecondaryContainer),
    );
  });

  testWidgets('shows switch action for a different plan when subscribed', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.pro(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
      ],
      debugUnlockAvailable: false,
      debugUnlocked: false,
      activeProductId: 'monkeyssh_pro',
      activeOfferId: 'monthly',
    );

    when(() => service.currentState).thenReturn(state);
    when(
      () => service.purchaseOffer(any()),
    ).thenAnswer(_cancelledPurchaseResult);
    when(service.restorePurchases).thenAnswer(_restoredPurchaseResult);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Manage current plan'), 300);
    await tester.pumpAndSettle();

    expect(find.text('Manage current plan'), findsOneWidget);
    expect(find.text('Switch to Annual'), findsOneWidget);
  });

  testWidgets('highlights annual savings and best value copy', (tester) async {
    final service = _MockMonetizationService();
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    final annualSavingsBanner = tester.widget<Text>(
      find.text(
        'Annual is the best value - save about 17% compared with paying monthly.',
      ),
    );
    await tester.scrollUntilVisible(find.text('Best value - Save 17%'), 300);
    await tester.pumpAndSettle();

    expect(find.text('Best value - Save 17%'), findsOneWidget);
    final bestValuePill = tester.widget<Text>(
      find.text('Best value - Save 17%'),
    );
    final theme = ThemeData.light(useMaterial3: true);
    expect(
      annualSavingsBanner.style?.color,
      equals(theme.colorScheme.onSecondaryContainer),
    );
    expect(
      bestValuePill.style?.color,
      equals(theme.colorScheme.onSecondaryContainer),
    );
  });

  testWidgets('shared trial copy mentions monthly and annual plans', (
    tester,
  ) async {
    final service = _MockMonetizationService();
    const trialLabel = '2 weeks free trial for eligible new customers';
    const state = MonetizationState(
      billingAvailability: MonetizationBillingAvailability.available,
      entitlements: MonetizationEntitlements.free(),
      offers: [
        MonetizationOffer(
          id: 'monthly',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.monthly,
          planLabel: 'Monthly',
          priceLabel: r'$4.99',
          displayPriceLabel: r'$4.99 / month',
          rawPrice: 4.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
          introductoryOfferLabel: trialLabel,
        ),
        MonetizationOffer(
          id: 'annual',
          productId: 'monkeyssh_pro',
          billingPeriod: MonetizationBillingPeriod.annual,
          planLabel: 'Annual',
          priceLabel: r'$49.99',
          displayPriceLabel: r'$49.99 / year',
          rawPrice: 49.99,
          currencyCode: 'USD',
          currencySymbol: r'$',
          introductoryOfferLabel: trialLabel,
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monetizationServiceProvider.overrideWithValue(service),
          monetizationStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: const MaterialApp(home: UpgradeScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('shared-intro-offer-label')),
      300,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(trialLabel), findsWidgets);
    final sharedIntroText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('shared-intro-offer-label')),
        matching: find.textContaining(trialLabel),
      ),
    );
    expect(sharedIntroText.data, contains('monthly and annual'));
  });
}
