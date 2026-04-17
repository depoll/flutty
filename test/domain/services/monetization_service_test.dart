// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

class MockInAppPurchase extends Mock implements InAppPurchase {}

class MockPurchaseDetails extends Mock implements PurchaseDetails {}

class MockGooglePlayProductDetails extends Mock
    implements GooglePlayProductDetails {}

class MockInAppPurchaseAndroidPlatformAddition extends Mock
    implements InAppPurchaseAndroidPlatformAddition {}

class _FakePurchaseParam extends Fake implements PurchaseParam {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakePurchaseParam());
  });

  test(
    'queries both preview and prod App Store product IDs on Apple platforms',
    () {
      expect(
        MonetizationProductIds.forPlatform(TargetPlatform.iOS),
        unorderedEquals([
          MonetizationProductIds.iosMonthly,
          MonetizationProductIds.iosAnnual,
          MonetizationProductIds.iosMonthlyProd,
          MonetizationProductIds.iosAnnualProd,
          MonetizationProductIds.iosProLifetime,
          MonetizationProductIds.iosProLifetimeProd,
        ]),
      );
      expect(
        MonetizationProductIds.forPlatform(TargetPlatform.macOS),
        unorderedEquals([
          MonetizationProductIds.iosMonthly,
          MonetizationProductIds.iosAnnual,
          MonetizationProductIds.iosMonthlyProd,
          MonetizationProductIds.iosAnnualProd,
          MonetizationProductIds.iosProLifetime,
          MonetizationProductIds.iosProLifetimeProd,
        ]),
      );
      expect(
        MonetizationProductIds.forPlatform(TargetPlatform.android),
        unorderedEquals([
          MonetizationProductIds.androidPro,
          MonetizationProductIds.androidProLifetime,
        ]),
      );
      expect(
        MonetizationProductIds.allKnown,
        containsAll({
          MonetizationProductIds.iosMonthlyProd,
          MonetizationProductIds.iosAnnualProd,
          MonetizationProductIds.iosProLifetimeProd,
          MonetizationProductIds.androidProLifetime,
        }),
      );
      expect(
        MonetizationProductIds.isLifetime(
          MonetizationProductIds.androidProLifetime,
        ),
        isTrue,
      );
      expect(
        MonetizationProductIds.isLifetime(
          MonetizationProductIds.iosProLifetimeProd,
        ),
        isTrue,
      );
      expect(
        MonetizationProductIds.isLifetime(MonetizationProductIds.androidPro),
        isFalse,
      );
      expect(MonetizationProductIds.isLifetime(null), isFalse);
    },
  );

  group('buildMonetizationOffers', () {
    test('deduplicates Google Play base plans and keeps trial offers', () {
      final productDetails = GooglePlayProductDetails.fromProductDetails(
        ProductDetailsWrapper(
          description: 'MonkeySSH Pro subscription',
          name: 'MonkeySSH Pro',
          productId: MonetizationProductIds.androidPro,
          productType: ProductType.subs,
          title: 'MonkeySSH Pro',
          subscriptionOfferDetails: [
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerIdToken: 'monthly-base-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: r'$5.00',
                  priceAmountMicros: 5000000,
                  billingPeriod: 'P1M',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerId: 'free-trial',
              offerIdToken: 'monthly-trial-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: 'Free',
                  priceAmountMicros: 0,
                  billingPeriod: 'P2W',
                  recurrenceMode: RecurrenceMode.nonRecurring,
                ),
                _pricingPhase(
                  formattedPrice: r'$5.00',
                  priceAmountMicros: 5000000,
                  billingPeriod: 'P1M',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
            _subscriptionOfferDetails(
              basePlanId: 'annual',
              offerId: 'free-trial',
              offerIdToken: 'annual-trial-token',
              pricingPhases: [
                _pricingPhase(
                  formattedPrice: 'Free',
                  priceAmountMicros: 0,
                  billingPeriod: 'P2W',
                  recurrenceMode: RecurrenceMode.nonRecurring,
                ),
                _pricingPhase(
                  formattedPrice: r'$50.00',
                  priceAmountMicros: 50000000,
                  billingPeriod: 'P1Y',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
          ],
        ),
      );

      final offers = buildMonetizationOffers(productDetails);

      expect(offers, hasLength(2));
      expect(offers.map((offer) => offer.billingPeriod), [
        MonetizationBillingPeriod.monthly,
        MonetizationBillingPeriod.annual,
      ]);
      expect(offers[0].displayPriceLabel, r'$5.00 / month');
      expect(
        offers[0].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
      expect(offers[1].displayPriceLabel, r'$50.00 / year');
      expect(
        offers[1].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
    });

    test('keeps separate App Store monthly and annual products', () {
      final offers = buildMonetizationOffers([
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosMonthly,
            localizedTitle: 'MonkeySSH Pro Monthly',
            localizedDescription: 'Monthly MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '5.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.month,
            ),
            introductoryPrice: SKProductDiscountWrapper(
              price: '0.00',
              priceLocale: _usdPriceLocale,
              numberOfPeriods: 2,
              paymentMode: SKProductDiscountPaymentMode.freeTrail,
              subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
                numberOfUnits: 1,
                unit: SKSubscriptionPeriodUnit.week,
              ),
              identifier: 'intro',
              type: SKProductDiscountType.introductory,
            ),
          ),
        ),
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosAnnual,
            localizedTitle: 'MonkeySSH Pro Annual',
            localizedDescription: 'Annual MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '50.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.year,
            ),
          ),
        ),
      ]);

      expect(offers, hasLength(2));
      expect(offers.map((offer) => offer.productId), [
        MonetizationProductIds.iosMonthly,
        MonetizationProductIds.iosAnnual,
      ]);
      expect(offers[0].displayPriceLabel, r'$5.00 / month');
      expect(
        offers[0].introductoryOfferLabel,
        '2 weeks free trial for eligible new customers',
      );
      expect(offers[1].displayPriceLabel, r'$50.00 / year');
      expect(offers[1].introductoryOfferLabel, isNull);
    });

    test('skips Google Play offers with no pricing phases', () {
      final productDetails = MockGooglePlayProductDetails();
      when(() => productDetails.subscriptionIndex).thenReturn(0);
      when(
        () => productDetails.id,
      ).thenReturn(MonetizationProductIds.androidPro);
      when(() => productDetails.offerToken).thenReturn('monthly-base-token');
      when(() => productDetails.productDetails).thenReturn(
        ProductDetailsWrapper(
          description: 'MonkeySSH Pro subscription',
          name: 'MonkeySSH Pro',
          productId: MonetizationProductIds.androidPro,
          productType: ProductType.subs,
          title: 'MonkeySSH Pro',
          subscriptionOfferDetails: [
            _subscriptionOfferDetails(
              basePlanId: 'monthly',
              offerIdToken: 'monthly-base-token',
              pricingPhases: const [],
            ),
          ],
        ),
      );

      final offers = buildMonetizationOffers([productDetails]);

      expect(offers, isEmpty);
    });

    test('keeps a trailing currency code when no symbol is prefixed', () {
      final offers = buildMonetizationOffers(
        GooglePlayProductDetails.fromProductDetails(
          ProductDetailsWrapper(
            description: 'MonkeySSH Pro subscription',
            name: 'MonkeySSH Pro',
            productId: MonetizationProductIds.androidPro,
            productType: ProductType.subs,
            title: 'MonkeySSH Pro',
            subscriptionOfferDetails: [
              _subscriptionOfferDetails(
                basePlanId: 'monthly',
                offerIdToken: 'monthly-base-token',
                pricingPhases: [
                  _pricingPhase(
                    formattedPrice: '5.00 USD',
                    priceAmountMicros: 5000000,
                    billingPeriod: 'P1M',
                    recurrenceMode: RecurrenceMode.infiniteRecurring,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      expect(offers.single.currencySymbol, 'USD');
    });

    test('excludes lifetime products from the paywall offers list', () {
      final offers = buildMonetizationOffers([
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosMonthly,
            localizedTitle: 'MonkeySSH Pro Monthly',
            localizedDescription: 'Monthly MonkeySSH Pro subscription',
            priceLocale: _usdPriceLocale,
            price: '5.00',
            subscriptionPeriod: SKProductSubscriptionPeriodWrapper(
              numberOfUnits: 1,
              unit: SKSubscriptionPeriodUnit.month,
            ),
          ),
        ),
        // A non-consumable lifetime App Store product has no
        // subscriptionPeriod. It must never appear in the paywall.
        AppStoreProductDetails.fromSKProduct(
          SKProductWrapper(
            productIdentifier: MonetizationProductIds.iosProLifetimeProd,
            localizedTitle: 'MonkeySSH Pro Lifetime',
            localizedDescription: 'Lifetime MonkeySSH Pro purchase',
            priceLocale: _usdPriceLocale,
            price: '99.00',
          ),
        ),
      ]);

      expect(offers, hasLength(1));
      expect(offers.single.productId, MonetizationProductIds.iosMonthly);
    });

    test(
      'excludes lifetime Google Play one-time products from the paywall',
      () {
        final offers = buildMonetizationOffers(
          GooglePlayProductDetails.fromProductDetails(
            const ProductDetailsWrapper(
              description: 'MonkeySSH Pro Lifetime',
              name: 'MonkeySSH Pro Lifetime',
              productId: MonetizationProductIds.androidProLifetime,
              productType: ProductType.inapp,
              title: 'MonkeySSH Pro Lifetime',
              oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetailsWrapper(
                priceAmountMicros: 99000000,
                priceCurrencyCode: 'USD',
                formattedPrice: r'$99.00',
              ),
            ),
          ),
        );

        expect(offers, isEmpty);
      },
    );
  });

  group('MonetizationService', () {
    late AppDatabase database;
    late SettingsService settings;
    late MockInAppPurchase inAppPurchase;
    late MockInAppPurchaseAndroidPlatformAddition androidPlatformAddition;
    late StreamController<List<PurchaseDetails>> purchaseController;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      settings = SettingsService(database);
      inAppPurchase = MockInAppPurchase();
      androidPlatformAddition = MockInAppPurchaseAndroidPlatformAddition();
      purchaseController = StreamController<List<PurchaseDetails>>.broadcast();

      when(
        () => inAppPurchase.purchaseStream,
      ).thenAnswer((_) => purchaseController.stream);
      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => false);
    });

    tearDown(() async {
      await purchaseController.close();
      await database.close();
    });

    test('initializes cached entitlements from settings', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final updatedAt = DateTime.utc(2026, 4, 10, 7);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.iosAnnual,
      );
      await settings.setString(
        SettingKeys.monetizationActiveOfferId,
        MonetizationProductIds.iosAnnual,
      );
      await settings.setString(
        SettingKeys.monetizationEntitlementUpdatedAt,
        updatedAt.toIso8601String(),
      );

      final service = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.currentState.isProUnlocked, isTrue);
      expect(
        service.currentState.activeProductId,
        MonetizationProductIds.iosAnnual,
      );
      expect(
        service.currentState.activeOfferId,
        MonetizationProductIds.iosAnnual,
      );
      expect(service.currentState.entitlementUpdatedAt, updatedAt.toLocal());
      expect(
        service.currentState.billingAvailability,
        MonetizationBillingAvailability.unavailable,
      );
    });

    test('canUseFeature reflects the cached Pro entitlement state', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final freeService = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
      );
      addTearDown(freeService.dispose);

      await freeService.initialize();
      expect(
        await freeService.canUseFeature(MonetizationFeature.agentLaunchPresets),
        isFalse,
      );

      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);

      final unlockedService = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
      );
      addTearDown(unlockedService.dispose);

      await unlockedService.initialize();
      expect(
        await unlockedService.canUseFeature(
          MonetizationFeature.autoConnectAutomation,
        ),
        isTrue,
      );
    });

    test(
      'macOS uses the Apple storefront path for billing availability',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();

        expect(
          service.currentState.billingAvailability,
          MonetizationBillingAvailability.unavailable,
        );
      },
    );

    test(
      'concurrent initialize calls wait for the same in-flight work',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final availabilityCompleter = Completer<bool>();
        when(
          () => inAppPurchase.isAvailable(),
        ).thenAnswer((_) => availabilityCompleter.future);

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        var secondInitializeCompleted = false;
        final firstInitialize = service.initialize();
        final secondInitialize = service.initialize().then((_) {
          secondInitializeCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(secondInitializeCompleted, isFalse);

        availabilityCompleter.complete(false);
        await Future.wait([firstInitialize, secondInitialize]);

        expect(secondInitializeCompleted, isTrue);
        verify(() => inAppPurchase.isAvailable()).called(1);
      },
    );

    test(
      'purchase stream activates lifetime entitlement when a redeemed lifetime product arrives',
      () async {
        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.iosProLifetimeProd);
        when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await service.initialize();
        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.iosProLifetimeProd,
        );
        verify(() => inAppPurchase.completePurchase(purchase)).called(1);
      },
    );

    test(
      'lifetime purchase clears any stale activeOfferId carried over from a prior subscription',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // Simulate a user who previously had a subscription: pre-seed
        // the cached entitlement settings with an active subscription
        // product and offer.
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.iosMonthly,
        );
        await settings.setString(
          SettingKeys.monetizationActiveOfferId,
          'monthly-base-offer',
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.iosProLifetimeProd);
        when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await service.initialize();
        // Sanity check: the prior subscription offer was loaded from settings.
        expect(service.currentState.activeOfferId, 'monthly-base-offer');

        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        // The stale subscription offer must be cleared from both the
        // in-memory state and the persisted settings.
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveOfferId),
          isNull,
        );
      },
    );

    test(
      'lifetime entitlement is preserved when a stale subscription transaction is replayed by the purchase stream',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        final lifetime = MockPurchaseDetails();
        when(
          () => lifetime.productID,
        ).thenReturn(MonetizationProductIds.iosProLifetimeProd);
        when(() => lifetime.status).thenReturn(PurchaseStatus.restored);
        when(() => lifetime.pendingCompletePurchase).thenReturn(true);
        when(() => lifetime.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(lifetime),
        ).thenAnswer((_) async {});

        final staleSub = MockPurchaseDetails();
        when(
          () => staleSub.productID,
        ).thenReturn(MonetizationProductIds.iosMonthly);
        when(() => staleSub.status).thenReturn(PurchaseStatus.restored);
        when(() => staleSub.pendingCompletePurchase).thenReturn(true);
        when(() => staleSub.transactionDate).thenReturn('1712732401000');
        when(
          () => inAppPurchase.completePurchase(staleSub),
        ).thenAnswer((_) async {});

        await service.initialize();
        // Deliver both transactions in the same batch, mimicking what
        // StoreKit does during a restore.
        purchaseController.add([lifetime, staleSub]);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Lifetime must win regardless of replay order.
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.iosProLifetimeProd,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.iosProLifetimeProd,
        );
      },
    );

    test(
      'Android reconcile promotes lifetime when a previously cached subscription has lapsed',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        // Pre-seed cached entitlement as the now-defunct subscription.
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidPro,
        );
        await settings.setString(
          SettingKeys.monetizationActiveOfferId,
          'monthly-base',
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: const [],
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();

        expect(service.currentState.isProUnlocked, isTrue);
        expect(service.currentState.isLifetimeUnlocked, isTrue);
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.androidProLifetime,
        );
        expect(service.currentState.activeOfferId, isNull);
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.androidProLifetime,
        );
        expect(
          await settings.getString(SettingKeys.monetizationActiveOfferId),
          isNull,
        );
      },
    );

    test('restored lifetime purchase from Google Play unlocks pro', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
      when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
        (_) async => ProductDetailsResponse(
          productDetails: const [],
          notFoundIDs: const [],
        ),
      );
      when(androidPlatformAddition.queryPastPurchases).thenAnswer(
        (_) async => QueryPurchaseDetailsResponse(
          pastPurchases: [
            _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
          ],
        ),
      );

      final service = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        androidPlatformAddition: androidPlatformAddition,
        allowDebugUnlock: false,
      );
      addTearDown(service.dispose);

      final result = await service.restorePurchases();

      expect(result.success, isTrue);
      expect(result.message, contains('Lifetime'));
      expect(service.currentState.isProUnlocked, isTrue);
      expect(service.currentState.isLifetimeUnlocked, isTrue);
      expect(
        service.currentState.activeProductId,
        MonetizationProductIds.androidProLifetime,
      );
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isTrue,
      );
    });

    test(
      'purchase stream updates cached entitlements after a purchase',
      () async {
        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.androidPro);
        when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        await service.initialize();
        purchaseController.add([purchase]);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(service.currentState.isProUnlocked, isTrue);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
        expect(
          await settings.getString(SettingKeys.monetizationActiveProductId),
          MonetizationProductIds.androidPro,
        );
        expect(
          service.currentState.activeProductId,
          MonetizationProductIds.androidPro,
        );
        expect(service.currentState.activeOfferId, isNull);
        verify(() => inAppPurchase.completePurchase(purchase)).called(1);
      },
    );

    test('purchaseOffer persists the selected Android plan', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
      when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
        (_) async => ProductDetailsResponse(
          productDetails: _androidCatalogDetails(),
          notFoundIDs: const [],
        ),
      );
      when(
        () => inAppPurchase.buyNonConsumable(
          purchaseParam: any(named: 'purchaseParam'),
        ),
      ).thenAnswer((_) async => true);

      final purchase = MockPurchaseDetails();
      when(
        () => purchase.productID,
      ).thenReturn(MonetizationProductIds.androidPro);
      when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
      when(() => purchase.pendingCompletePurchase).thenReturn(true);
      when(() => purchase.transactionDate).thenReturn('1712732400000');
      when(
        () => inAppPurchase.completePurchase(purchase),
      ).thenAnswer((_) async {});

      final service = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        androidPlatformAddition: androidPlatformAddition,
        allowDebugUnlock: false,
      );
      addTearDown(service.dispose);

      await service.initialize();
      final annualOfferId = service.currentState.offers
          .firstWhere(
            (offer) => offer.billingPeriod == MonetizationBillingPeriod.annual,
          )
          .id;
      final resultFuture = service.purchaseOffer(annualOfferId);
      await Future<void>.delayed(Duration.zero);
      purchaseController.add([purchase]);

      final result = await resultFuture;

      expect(result.success, isTrue);
      expect(service.currentState.activeOfferId, annualOfferId);
      expect(
        await settings.getString(SettingKeys.monetizationActiveOfferId),
        annualOfferId,
      );
    });

    test(
      'purchaseOffer refuses recurring plans when lifetime is already active',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidProLifetime,
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastLifetimePurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();
        final offerId = service.currentState.offers.first.id;

        final result = await service.purchaseOffer(offerId);

        expect(result.success, isFalse);
        expect(result.cancelled, isFalse);
        expect(result.message, contains('Lifetime is already active'));
        verifyNever(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        );
      },
    );

    test(
      'purchaseOffer lets Android users retry with another plan after dismissing Play checkout',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        var buyCallCount = 0;
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async {
          buyCallCount += 1;
          return true;
        });
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(pastPurchases: const []),
        );

        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.androidPro);
        when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) async {});

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();
        final monthlyOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.monthly,
            )
            .id;
        final annualOfferId = service.currentState.offers
            .firstWhere(
              (offer) =>
                  offer.billingPeriod == MonetizationBillingPeriod.annual,
            )
            .id;

        final firstAttempt = service.purchaseOffer(monthlyOfferId);
        await Future<void>.delayed(Duration.zero);

        final secondAttempt = service.purchaseOffer(annualOfferId);
        await Future<void>.delayed(Duration.zero);

        final firstResult = await firstAttempt;
        purchaseController.add([purchase]);
        final secondResult = await secondAttempt;

        expect(firstResult.success, isFalse);
        expect(firstResult.cancelled, isTrue);
        expect(secondResult.success, isTrue);
        expect(service.currentState.activeOfferId, annualOfferId);
        expect(buyCallCount, 2);
        verify(androidPlatformAddition.queryPastPurchases).called(1);
      },
    );

    test(
      'restorePurchases refuses to start while another purchase is in progress',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        final buyStartedCompleter = Completer<bool>();
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) => buyStartedCompleter.future);

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();
        final purchaseFuture = service.purchaseOffer(
          service.currentState.defaultOffer!.id,
        );
        await Future<void>.delayed(Duration.zero);

        final restoreResult = await service.restorePurchases();

        expect(restoreResult.success, isFalse);
        expect(
          restoreResult.message,
          'Another purchase or restore is already in progress.',
        );

        buyStartedCompleter.complete(false);
        await purchaseFuture;
      },
    );

    test(
      'initialization clears cached Android entitlement when Play has no active subscription',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await settings.setBool(
          SettingKeys.monetizationProUnlocked,
          value: true,
        );
        await settings.setString(
          SettingKeys.monetizationActiveProductId,
          MonetizationProductIds.androidPro,
        );

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(pastPurchases: []),
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();

        expect(service.currentState.isProUnlocked, isFalse);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isFalse,
        );
      },
    );

    test(
      'restorePurchases uses active Google Play subscriptions on Android',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(androidPlatformAddition.queryPastPurchases).thenAnswer(
          (_) async => QueryPurchaseDetailsResponse(
            pastPurchases: [
              _androidPastPurchase(purchaseTimeMillis: 1712732400000),
            ],
          ),
        );

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        final result = await service.restorePurchases();

        expect(result.success, isTrue);
        expect(service.currentState.isProUnlocked, isTrue);
        expect(
          await settings.getBool(SettingKeys.monetizationProUnlocked),
          isTrue,
        );
      },
    );

    test('restore timeout clears a stale cached store entitlement', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        MonetizationProductIds.androidPro,
      );

      when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {});

      final service = MonetizationService(
        settings,
        inAppPurchase: inAppPurchase,
        allowDebugUnlock: false,
        restoreTimeout: Duration.zero,
      );
      addTearDown(service.dispose);

      final result = await service.restorePurchases();

      expect(result.success, isFalse);
      expect(service.currentState.isProUnlocked, isFalse);
      expect(
        await settings.getBool(SettingKeys.monetizationProUnlocked),
        isFalse,
      );
      expect(
        await settings.getString(SettingKeys.monetizationActiveProductId),
        isNull,
      );
    });

    test(
      'restore timeout clears loading when a purchase update was observed',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.androidPro);
        when(() => purchase.status).thenReturn(PurchaseStatus.restored);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenAnswer((_) => Completer<void>().future);
        when(() => inAppPurchase.restorePurchases()).thenAnswer((_) async {});

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
          restoreTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(service.dispose);

        await service.initialize();
        unawaited(
          Future<void>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            purchaseController.add([purchase]);
          }),
        );

        final result = await service.restorePurchases();

        expect(result.success, isFalse);
        expect(service.currentState.isLoading, isFalse);
      },
    );

    test(
      'purchase finalization failure resolves the pending purchase',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        when(() => inAppPurchase.isAvailable()).thenAnswer((_) async => true);
        when(() => inAppPurchase.queryProductDetails(any())).thenAnswer(
          (_) async => ProductDetailsResponse(
            productDetails: _androidCatalogDetails(),
            notFoundIDs: const [],
          ),
        );
        when(
          () => inAppPurchase.buyNonConsumable(
            purchaseParam: any(named: 'purchaseParam'),
          ),
        ).thenAnswer((_) async => true);

        final purchase = MockPurchaseDetails();
        when(
          () => purchase.productID,
        ).thenReturn(MonetizationProductIds.androidPro);
        when(() => purchase.status).thenReturn(PurchaseStatus.purchased);
        when(() => purchase.pendingCompletePurchase).thenReturn(true);
        when(() => purchase.transactionDate).thenReturn('1712732400000');
        when(
          () => inAppPurchase.completePurchase(purchase),
        ).thenThrow(Exception('billing finalize failed'));

        final service = MonetizationService(
          settings,
          inAppPurchase: inAppPurchase,
          androidPlatformAddition: androidPlatformAddition,
          allowDebugUnlock: false,
        );
        addTearDown(service.dispose);

        await service.initialize();
        final resultFuture = service.purchaseOffer(
          service.currentState.defaultOffer!.id,
        );
        await Future<void>.delayed(Duration.zero);
        purchaseController.add([purchase]);

        final result = await resultFuture;

        expect(result.success, isFalse);
        expect(result.message, contains('Failed to finalize purchase'));
        expect(service.currentState.isLoading, isFalse);
        expect(
          service.currentState.lastError,
          contains('Failed to finalize purchase'),
        );
      },
    );
  });
}

final _usdPriceLocale = SKPriceLocaleWrapper(
  currencySymbol: r'$',
  currencyCode: 'USD',
  countryCode: 'US',
);

SubscriptionOfferDetailsWrapper _subscriptionOfferDetails({
  required String basePlanId,
  required String offerIdToken,
  required List<PricingPhaseWrapper> pricingPhases,
  String? offerId,
}) => SubscriptionOfferDetailsWrapper(
  basePlanId: basePlanId,
  offerId: offerId,
  offerTags: const [],
  offerIdToken: offerIdToken,
  pricingPhases: pricingPhases,
);

PricingPhaseWrapper _pricingPhase({
  required String formattedPrice,
  required int priceAmountMicros,
  required String billingPeriod,
  required RecurrenceMode recurrenceMode,
}) => PricingPhaseWrapper(
  billingCycleCount: 1,
  billingPeriod: billingPeriod,
  formattedPrice: formattedPrice,
  priceAmountMicros: priceAmountMicros,
  priceCurrencyCode: 'USD',
  recurrenceMode: recurrenceMode,
);

List<ProductDetails> _androidCatalogDetails() => [
  ...GooglePlayProductDetails.fromProductDetails(
    ProductDetailsWrapper(
      description: 'MonkeySSH Pro subscription',
      name: 'MonkeySSH Pro',
      productId: MonetizationProductIds.androidPro,
      productType: ProductType.subs,
      title: 'MonkeySSH Pro',
      subscriptionOfferDetails: [
        _subscriptionOfferDetails(
          basePlanId: 'monthly',
          offerIdToken: 'monthly-base-token',
          pricingPhases: [
            _pricingPhase(
              formattedPrice: r'$5.00',
              priceAmountMicros: 5000000,
              billingPeriod: 'P1M',
              recurrenceMode: RecurrenceMode.infiniteRecurring,
            ),
          ],
        ),
        _subscriptionOfferDetails(
          basePlanId: 'annual',
          offerIdToken: 'annual-base-token',
          pricingPhases: [
            _pricingPhase(
              formattedPrice: r'$50.00',
              priceAmountMicros: 50000000,
              billingPeriod: 'P1Y',
              recurrenceMode: RecurrenceMode.infiniteRecurring,
            ),
          ],
        ),
      ],
    ),
  ),
];

GooglePlayPurchaseDetails _androidPastPurchase({
  required int purchaseTimeMillis,
}) => GooglePlayPurchaseDetails(
  purchaseID: 'order-$purchaseTimeMillis',
  productID: MonetizationProductIds.androidPro,
  verificationData: PurchaseVerificationData(
    localVerificationData: 'local-verification-data',
    serverVerificationData: 'server-verification-data',
    source: 'google_play',
  ),
  transactionDate: purchaseTimeMillis.toString(),
  billingClientPurchase: PurchaseWrapper(
    orderId: 'order-$purchaseTimeMillis',
    packageName: 'xyz.depollsoft.monkeyssh',
    purchaseTime: purchaseTimeMillis,
    purchaseToken: 'token-$purchaseTimeMillis',
    signature: 'signature',
    products: const [MonetizationProductIds.androidPro],
    isAutoRenewing: true,
    originalJson: '{}',
    isAcknowledged: true,
    purchaseState: PurchaseStateWrapper.purchased,
  ),
  status: PurchaseStatus.restored,
);

GooglePlayPurchaseDetails _androidPastLifetimePurchase({
  required int purchaseTimeMillis,
}) => GooglePlayPurchaseDetails(
  purchaseID: 'lifetime-$purchaseTimeMillis',
  productID: MonetizationProductIds.androidProLifetime,
  verificationData: PurchaseVerificationData(
    localVerificationData: 'local-verification-data',
    serverVerificationData: 'server-verification-data',
    source: 'google_play',
  ),
  transactionDate: purchaseTimeMillis.toString(),
  billingClientPurchase: PurchaseWrapper(
    orderId: 'lifetime-$purchaseTimeMillis',
    packageName: 'xyz.depollsoft.monkeyssh',
    purchaseTime: purchaseTimeMillis,
    purchaseToken: 'token-$purchaseTimeMillis',
    signature: 'signature',
    products: const [MonetizationProductIds.androidProLifetime],
    isAutoRenewing: false,
    originalJson: '{}',
    isAcknowledged: true,
    purchaseState: PurchaseStateWrapper.purchased,
  ),
  status: PurchaseStatus.restored,
);
