// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';

void main() {
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
