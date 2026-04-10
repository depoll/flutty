import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

import '../models/monetization.dart';
import 'settings_service.dart';

/// Coordinates local premium state and mobile store purchase flows.
class MonetizationService {
  /// Creates a new [MonetizationService].
  MonetizationService(
    this._settings, {
    InAppPurchase? inAppPurchase,
    bool? allowDebugUnlock,
    Duration purchaseTimeout = const Duration(seconds: 60),
    Duration restoreTimeout = const Duration(seconds: 45),
  }) : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
       _allowDebugUnlock = allowDebugUnlock ?? kDebugMode,
       _purchaseTimeout = purchaseTimeout,
       _restoreTimeout = restoreTimeout;

  final SettingsService _settings;
  final InAppPurchase _inAppPurchase;
  final bool _allowDebugUnlock;
  final Duration _purchaseTimeout;
  final Duration _restoreTimeout;
  final _controller = StreamController<MonetizationState>.broadcast();
  final _purchaseOptionsByOfferId = <String, _MonetizationPurchaseOption>{};

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  Completer<MonetizationActionResult>? _pendingPurchaseResult;
  bool _restoreInFlight = false;
  bool _restoreObservedPurchaseUpdate = false;
  bool _initialized = false;
  MonetizationState _state = MonetizationState.initial(
    debugUnlockAvailable: kDebugMode,
  );

  /// Current monetization state.
  MonetizationState get currentState => _state;

  /// Stream of monetization state updates.
  Stream<MonetizationState> get states async* {
    yield _state;
    yield* _controller.stream;
  }

  /// Initializes cached state and starts listening for store purchase updates.
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _purchaseSubscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Purchase stream error: $error');
        _emit(_state.copyWith(isLoading: false, lastError: '$error'));
      },
    );

    final cachedProUnlocked = await _settings.getBool(
      SettingKeys.monetizationProUnlocked,
    );
    var debugUnlocked = false;
    if (_allowDebugUnlock) {
      debugUnlocked = await _settings.getBool(
        SettingKeys.monetizationDebugUnlocked,
      );
    }
    final updatedAt = _parseCachedDate(
      await _settings.getString(SettingKeys.monetizationEntitlementUpdatedAt),
    );
    final activeProductId = await _settings.getString(
      SettingKeys.monetizationActiveProductId,
    );

    _emit(
      _state.copyWith(
        billingAvailability: _supportsStoreBilling
            ? MonetizationBillingAvailability.unknown
            : MonetizationBillingAvailability.unsupported,
        entitlements: cachedProUnlocked || debugUnlocked
            ? const MonetizationEntitlements.pro()
            : const MonetizationEntitlements.free(),
        debugUnlockAvailable: _allowDebugUnlock,
        debugUnlocked: debugUnlocked,
        activeProductId: activeProductId,
        entitlementUpdatedAt: updatedAt,
      ),
    );

    if (_supportsStoreBilling) {
      await refreshCatalog();
    }
  }

  /// Refreshes store product metadata.
  Future<void> refreshCatalog() async {
    await initialize();
    if (!_supportsStoreBilling) {
      return;
    }

    _emit(_state.copyWith(isLoading: true, lastError: null));
    final isAvailable = await _inAppPurchase.isAvailable();
    if (!isAvailable) {
      _purchaseOptionsByOfferId.clear();
      _emit(
        _state.copyWith(
          isLoading: false,
          billingAvailability: MonetizationBillingAvailability.unavailable,
          offers: const [],
          lastError: null,
        ),
      );
      return;
    }

    final response = await _inAppPurchase.queryProductDetails(
      MonetizationProductIds.forPlatform(defaultTargetPlatform),
    );
    final catalog = _buildMonetizationCatalog(response.productDetails);
    _purchaseOptionsByOfferId
      ..clear()
      ..addAll(catalog.purchaseOptionsByOfferId);

    _emit(
      _state.copyWith(
        isLoading: false,
        billingAvailability: MonetizationBillingAvailability.available,
        offers: catalog.offers,
        lastError: response.error?.message,
      ),
    );
  }

  /// Whether [feature] is currently unlocked.
  Future<bool> canUseFeature(MonetizationFeature feature) async {
    await initialize();
    return _state.allowsFeature(feature);
  }

  /// Starts a purchase flow for the selected MonkeySSH Pro offer.
  Future<MonetizationActionResult> purchaseOffer(String offerId) async {
    await initialize();
    if (!_supportsStoreBilling) {
      return const MonetizationActionResult.failure(
        'Subscriptions are only available on iPhone and Android.',
      );
    }
    var purchaseOption = _purchaseOptionsByOfferId[offerId];
    if (purchaseOption == null) {
      await refreshCatalog();
      purchaseOption = _purchaseOptionsByOfferId[offerId];
    }
    if (purchaseOption == null) {
      return const MonetizationActionResult.failure(
        'The subscription is not currently available.',
      );
    }

    final completer = Completer<MonetizationActionResult>();
    _pendingPurchaseResult = completer;
    _restoreInFlight = false;
    _restoreObservedPurchaseUpdate = false;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    final purchaseParam = switch (purchaseOption) {
      _MonetizationPurchaseOption(
        productDetails: final GooglePlayProductDetails productDetails,
        offerToken: final offerToken?,
      ) =>
        GooglePlayPurchaseParam(
          productDetails: productDetails,
          offerToken: offerToken,
        ),
      _MonetizationPurchaseOption(productDetails: final productDetails) =>
        PurchaseParam(productDetails: productDetails),
    };
    final started = await _inAppPurchase.buyNonConsumable(
      purchaseParam: purchaseParam,
    );
    if (!started) {
      _pendingPurchaseResult = null;
      _emit(_state.copyWith(isLoading: false));
      return const MonetizationActionResult.failure(
        'Could not start the purchase flow.',
      );
    }

    return completer.future.timeout(
      _purchaseTimeout,
      onTimeout: () {
        _pendingPurchaseResult = null;
        _restoreInFlight = false;
        _restoreObservedPurchaseUpdate = false;
        _emit(_state.copyWith(isLoading: false));
        return const MonetizationActionResult.failure(
          'The purchase is taking longer than expected. If it completed, try restoring purchases.',
        );
      },
    );
  }

  /// Restores previous purchases from the store.
  Future<MonetizationActionResult> restorePurchases() async {
    await initialize();
    if (!_supportsStoreBilling) {
      return const MonetizationActionResult.failure(
        'Restoring purchases is only available on iPhone and Android.',
      );
    }

    final completer = Completer<MonetizationActionResult>();
    _pendingPurchaseResult = completer;
    _restoreInFlight = true;
    _restoreObservedPurchaseUpdate = false;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    await _inAppPurchase.restorePurchases();

    return completer.future.timeout(
      _restoreTimeout,
      onTimeout: () async {
        _pendingPurchaseResult = null;
        final restoreObservedPurchaseUpdate = _restoreObservedPurchaseUpdate;
        _restoreInFlight = false;
        _restoreObservedPurchaseUpdate = false;
        if (!restoreObservedPurchaseUpdate) {
          await _clearCachedStoreEntitlement();
        } else {
          _emit(_state.copyWith(isLoading: false));
        }
        return const MonetizationActionResult.failure(
          'No active subscription could be restored.',
        );
      },
    );
  }

  /// Recovers the UI if an interrupted purchase flow never delivered a result.
  void recoverInterruptedPurchase() {
    final completer = _pendingPurchaseResult;
    if (_restoreInFlight || completer == null || completer.isCompleted) {
      return;
    }
    _emit(_state.copyWith(isLoading: false, lastError: null));
    _resolvePendingPurchase(
      const MonetizationActionResult.cancelled('Purchase cancelled.'),
    );
  }

  /// Enables or disables the debug-only local unlock.
  Future<void> setDebugUnlocked({required bool unlocked}) async {
    if (!_allowDebugUnlock) {
      return;
    }
    await _settings.setBool(
      SettingKeys.monetizationDebugUnlocked,
      value: unlocked,
    );
    final hasStoreUnlock = await _settings.getBool(
      SettingKeys.monetizationProUnlocked,
    );
    _emit(
      _state.copyWith(
        debugUnlocked: unlocked,
        entitlements: unlocked || hasStoreUnlock
            ? const MonetizationEntitlements.pro()
            : const MonetizationEntitlements.free(),
        entitlementUpdatedAt: DateTime.now(),
      ),
    );
  }

  /// Releases store listeners held by this service.
  Future<void> dispose() async {
    await _purchaseSubscription?.cancel();
    await _controller.close();
  }

  bool get _supportsStoreBilling =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      if (!MonetizationProductIds.allKnown.contains(purchase.productID)) {
        continue;
      }

      switch (purchase.status) {
        case PurchaseStatus.pending:
          _emit(_state.copyWith(isLoading: true, lastError: null));
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (_restoreInFlight) {
            _restoreObservedPurchaseUpdate = true;
          }
          unawaited(_handleSuccessfulPurchase(purchase));
          break;
        case PurchaseStatus.error:
          unawaited(_completePurchaseIfNeeded(purchase));
          _emit(
            _state.copyWith(
              isLoading: false,
              lastError: purchase.error?.message ?? 'Purchase failed.',
            ),
          );
          _resolvePendingPurchase(
            MonetizationActionResult.failure(
              purchase.error?.message ?? 'Purchase failed.',
            ),
          );
          break;
        case PurchaseStatus.canceled:
          _emit(_state.copyWith(isLoading: false));
          _resolvePendingPurchase(
            const MonetizationActionResult.cancelled('Purchase cancelled.'),
          );
          break;
      }
    }
  }

  Future<void> _handleSuccessfulPurchase(PurchaseDetails purchase) async {
    try {
      await _completePurchaseIfNeeded(purchase);
      final timestamp =
          _parsePurchaseDate(purchase.transactionDate) ?? DateTime.now();
      await _settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await _settings.setString(
        SettingKeys.monetizationActiveProductId,
        purchase.productID,
      );
      await _settings.setString(
        SettingKeys.monetizationEntitlementUpdatedAt,
        timestamp.toUtc().toIso8601String(),
      );
      _emit(
        _state.copyWith(
          isLoading: false,
          entitlements: const MonetizationEntitlements.pro(),
          activeProductId: purchase.productID,
          entitlementUpdatedAt: timestamp,
          lastError: null,
        ),
      );
      _resolvePendingPurchase(
        const MonetizationActionResult.success('MonkeySSH Pro unlocked.'),
      );
    } on Object catch (error, stackTrace) {
      final message = 'Failed to finalize purchase: $error';
      debugPrint('$message\n$stackTrace');
      _emit(_state.copyWith(isLoading: false, lastError: message));
      _resolvePendingPurchase(MonetizationActionResult.failure(message));
    }
  }

  Future<void> _completePurchaseIfNeeded(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _inAppPurchase.completePurchase(purchase);
    }
  }

  Future<void> _clearCachedStoreEntitlement() async {
    await _settings.setBool(SettingKeys.monetizationProUnlocked, value: false);
    await _settings.delete(SettingKeys.monetizationActiveProductId);
    await _settings.delete(SettingKeys.monetizationEntitlementUpdatedAt);
    _emit(
      _state.copyWith(
        isLoading: false,
        entitlements: _state.debugUnlocked
            ? const MonetizationEntitlements.pro()
            : const MonetizationEntitlements.free(),
        activeProductId: null,
        entitlementUpdatedAt: null,
        lastError: null,
      ),
    );
  }

  void _resolvePendingPurchase(MonetizationActionResult result) {
    final completer = _pendingPurchaseResult;
    if (completer == null || completer.isCompleted) {
      return;
    }
    _pendingPurchaseResult = null;
    _restoreInFlight = false;
    _restoreObservedPurchaseUpdate = false;
    completer.complete(result);
  }

  void _emit(MonetizationState state) {
    _state = state;
    if (!_controller.isClosed) {
      _controller.add(state);
    }
  }

  DateTime? _parseCachedDate(String? rawValue) =>
      rawValue == null ? null : DateTime.tryParse(rawValue)?.toLocal();

  DateTime? _parsePurchaseDate(String? rawValue) {
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }
    final milliseconds = int.tryParse(rawValue);
    if (milliseconds == null) {
      return DateTime.tryParse(rawValue)?.toLocal();
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}

/// Provider for [MonetizationService].
final monetizationServiceProvider = Provider<MonetizationService>((ref) {
  final service = MonetizationService(ref.watch(settingsServiceProvider));
  ref.onDispose(() => unawaited(service.dispose()));
  unawaited(service.initialize());
  return service;
});

/// Stream provider for the latest [MonetizationState].
final monetizationStateProvider = StreamProvider<MonetizationState>((ref) {
  final service = ref.watch(monetizationServiceProvider);
  unawaited(service.initialize());
  return service.states;
});

/// Builds normalized MonkeySSH Pro offers from raw store product details.
@visibleForTesting
List<MonetizationOffer> buildMonetizationOffers(
  Iterable<ProductDetails> productDetails,
) => _buildMonetizationCatalog(productDetails).offers;

_MonetizationCatalog _buildMonetizationCatalog(
  Iterable<ProductDetails> productDetails,
) {
  final selectedByGroupKey = <String, _CatalogOfferCandidate>{};
  for (final details in productDetails) {
    final candidate = _buildCatalogOfferCandidate(details);
    if (candidate == null) {
      continue;
    }
    final existing = selectedByGroupKey[candidate.groupKey];
    if (existing == null ||
        candidate.preferenceRank > existing.preferenceRank ||
        (candidate.preferenceRank == existing.preferenceRank &&
            candidate.offer.rawPrice < existing.offer.rawPrice)) {
      selectedByGroupKey[candidate.groupKey] = candidate;
    }
  }

  final selectedCandidates = selectedByGroupKey.values.toList(growable: false)
    ..sort(_compareCatalogOfferCandidates);

  return _MonetizationCatalog(
    offers: selectedCandidates.map((candidate) => candidate.offer).toList(),
    purchaseOptionsByOfferId: {
      for (final candidate in selectedCandidates)
        candidate.offer.id: candidate.purchaseOption,
    },
  );
}

_CatalogOfferCandidate? _buildCatalogOfferCandidate(ProductDetails details) =>
    switch (details) {
      final GooglePlayProductDetails googlePlayDetails =>
        _buildGooglePlayOfferCandidate(googlePlayDetails),
      final AppStoreProductDetails appStoreDetails =>
        _buildAppStoreOfferCandidate(appStoreDetails),
      final AppStoreProduct2Details appStore2Details =>
        _buildAppStore2OfferCandidate(appStore2Details),
      _ => _buildFallbackOfferCandidate(details),
    };

_CatalogOfferCandidate? _buildGooglePlayOfferCandidate(
  GooglePlayProductDetails details,
) {
  final subscriptionIndex = details.subscriptionIndex;
  final offerDetails = subscriptionIndex == null
      ? null
      : details.productDetails.subscriptionOfferDetails?[subscriptionIndex];
  if (offerDetails == null) {
    return null;
  }
  if (offerDetails.pricingPhases.isEmpty) {
    return null;
  }

  final recurringPhase = _findRecurringPricingPhase(offerDetails.pricingPhases);
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    planId: offerDetails.basePlanId,
    recurringIsoPeriod: recurringPhase.billingPeriod,
  );
  final groupKey = '${details.id}:${offerDetails.basePlanId}';
  final offerId = '$groupKey:${offerDetails.offerId ?? 'base'}';
  final priceLabel = recurringPhase.formattedPrice;

  return _CatalogOfferCandidate(
    groupKey: groupKey,
    preferenceRank: _googlePlayOfferPriority(offerDetails),
    offer: MonetizationOffer(
      id: offerId,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: priceLabel,
      displayPriceLabel: _buildDisplayPriceLabel(priceLabel, billingPeriod),
      rawPrice: recurringPhase.priceAmountMicros / 1000000,
      currencyCode: recurringPhase.priceCurrencyCode,
      currencySymbol: _extractCurrencySymbol(
        priceLabel,
        recurringPhase.priceCurrencyCode,
      ),
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildGooglePlayIntroductoryOfferLabel(
        offerDetails.pricingPhases,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(
      productDetails: details,
      offerToken: details.offerToken,
    ),
  );
}

_CatalogOfferCandidate _buildAppStoreOfferCandidate(
  AppStoreProductDetails details,
) {
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    storeKitPeriod: details.skProduct.subscriptionPeriod,
  );
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: details.skProduct.introductoryPrice == null ? 0 : 1,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildStoreKitIntroductoryOfferLabel(
        details.skProduct.introductoryPrice,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

_CatalogOfferCandidate _buildAppStore2OfferCandidate(
  AppStoreProduct2Details details,
) {
  final subscription = details.sk2Product.subscription;
  final introductoryOffer = subscription?.promotionalOffers.firstWhereOrNull(
    (offer) => offer.type == SK2SubscriptionOfferType.introductory,
  );
  final billingPeriod = _billingPeriodFromIdentifiers(
    productId: details.id,
    storeKit2Period: subscription?.subscriptionPeriod,
  );
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: introductoryOffer == null ? 0 : 1,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
      introductoryOfferLabel: _buildStoreKit2IntroductoryOfferLabel(
        introductoryOffer,
        details.currencySymbol,
      ),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

_CatalogOfferCandidate _buildFallbackOfferCandidate(ProductDetails details) {
  final billingPeriod = _billingPeriodFromIdentifiers(productId: details.id);
  return _CatalogOfferCandidate(
    groupKey: details.id,
    preferenceRank: 0,
    offer: MonetizationOffer(
      id: details.id,
      productId: details.id,
      billingPeriod: billingPeriod,
      planLabel: billingPeriod.label,
      priceLabel: details.price,
      displayPriceLabel: _buildDisplayPriceLabel(details.price, billingPeriod),
      rawPrice: details.rawPrice,
      currencyCode: details.currencyCode,
      currencySymbol: details.currencySymbol,
      detailLabel: _defaultOfferDetailLabel(billingPeriod),
    ),
    purchaseOption: _MonetizationPurchaseOption(productDetails: details),
  );
}

int _compareCatalogOfferCandidates(
  _CatalogOfferCandidate left,
  _CatalogOfferCandidate right,
) {
  final billingComparison = _billingPeriodSortOrder(
    left.offer.billingPeriod,
  ).compareTo(_billingPeriodSortOrder(right.offer.billingPeriod));
  if (billingComparison != 0) {
    return billingComparison;
  }
  return left.offer.rawPrice.compareTo(right.offer.rawPrice);
}

int _billingPeriodSortOrder(MonetizationBillingPeriod billingPeriod) =>
    switch (billingPeriod) {
      MonetizationBillingPeriod.monthly => 0,
      MonetizationBillingPeriod.annual => 1,
      MonetizationBillingPeriod.unknown => 2,
    };

PricingPhaseWrapper _findRecurringPricingPhase(
  List<PricingPhaseWrapper> phases,
) =>
    phases.lastWhereOrNull(
      (phase) => phase.recurrenceMode == RecurrenceMode.infiniteRecurring,
    ) ??
    phases.last;

int _googlePlayOfferPriority(SubscriptionOfferDetailsWrapper offerDetails) {
  if (offerDetails.pricingPhases.isEmpty) {
    return 0;
  }
  final firstPhase = offerDetails.pricingPhases.first;
  if (firstPhase.priceAmountMicros == 0) {
    return 2;
  }
  return offerDetails.offerId == null ? 0 : 1;
}

MonetizationBillingPeriod _billingPeriodFromIdentifiers({
  required String productId,
  String? planId,
  String? recurringIsoPeriod,
  SKProductSubscriptionPeriodWrapper? storeKitPeriod,
  SK2SubscriptionPeriod? storeKit2Period,
}) {
  for (final value in [planId, productId]) {
    final normalized = value?.toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      continue;
    }
    if (normalized.contains('annual') || normalized.contains('year')) {
      return MonetizationBillingPeriod.annual;
    }
    if (normalized.contains('monthly') || normalized.contains('month')) {
      return MonetizationBillingPeriod.monthly;
    }
  }
  if (recurringIsoPeriod != null) {
    return _billingPeriodFromIsoPeriod(recurringIsoPeriod);
  }
  if (storeKitPeriod != null) {
    return _billingPeriodFromStoreKitPeriod(
      units: storeKitPeriod.numberOfUnits,
      unitName: storeKitPeriod.unit.name,
    );
  }
  if (storeKit2Period != null) {
    return _billingPeriodFromStoreKitPeriod(
      units: storeKit2Period.value,
      unitName: storeKit2Period.unit.name,
    );
  }
  return MonetizationBillingPeriod.unknown;
}

MonetizationBillingPeriod _billingPeriodFromIsoPeriod(String isoPeriod) {
  final normalized = isoPeriod.toUpperCase();
  if (normalized.contains('Y')) {
    return MonetizationBillingPeriod.annual;
  }
  if (normalized.contains('M')) {
    return MonetizationBillingPeriod.monthly;
  }
  return MonetizationBillingPeriod.unknown;
}

MonetizationBillingPeriod _billingPeriodFromStoreKitPeriod({
  required int units,
  required String unitName,
}) {
  final normalizedUnit = unitName.toLowerCase();
  if (normalizedUnit == 'year' && units >= 1) {
    return MonetizationBillingPeriod.annual;
  }
  if (normalizedUnit == 'month' && units >= 1) {
    return MonetizationBillingPeriod.monthly;
  }
  return MonetizationBillingPeriod.unknown;
}

String _buildDisplayPriceLabel(
  String priceLabel,
  MonetizationBillingPeriod billingPeriod,
) => switch (billingPeriod) {
  MonetizationBillingPeriod.monthly => '$priceLabel / month',
  MonetizationBillingPeriod.annual => '$priceLabel / year',
  MonetizationBillingPeriod.unknown => priceLabel,
};

String? _defaultOfferDetailLabel(MonetizationBillingPeriod billingPeriod) =>
    switch (billingPeriod) {
      MonetizationBillingPeriod.monthly => 'Billed monthly',
      MonetizationBillingPeriod.annual => 'Billed yearly',
      MonetizationBillingPeriod.unknown => null,
    };

String? _buildGooglePlayIntroductoryOfferLabel(
  List<PricingPhaseWrapper> pricingPhases,
) {
  if (pricingPhases.isEmpty) {
    return null;
  }
  final firstPhase = pricingPhases.first;
  final recurringPhase = _findRecurringPricingPhase(pricingPhases);
  final duration = _formatPricingPhaseDuration(firstPhase);
  if (firstPhase.priceAmountMicros == 0) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  if (firstPhase.priceAmountMicros < recurringPhase.priceAmountMicros) {
    return duration == null
        ? 'Introductory pricing available'
        : '${firstPhase.formattedPrice} for $duration';
  }
  return null;
}

String? _buildStoreKitIntroductoryOfferLabel(
  SKProductDiscountWrapper? introductoryPrice,
) {
  if (introductoryPrice == null) {
    return null;
  }
  final duration = _formatStoreKitDuration(
    introductoryPrice.subscriptionPeriod.numberOfUnits,
    introductoryPrice.subscriptionPeriod.unit.name,
    repeatCount: introductoryPrice.numberOfPeriods,
  );
  if (introductoryPrice.paymentMode == SKProductDiscountPaymentMode.freeTrail) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  final priceLabel =
      '${introductoryPrice.priceLocale.currencySymbol}${introductoryPrice.price}';
  return duration == null
      ? 'Introductory pricing available'
      : '$priceLabel for $duration';
}

String? _buildStoreKit2IntroductoryOfferLabel(
  SK2SubscriptionOffer? introductoryOffer,
  String currencySymbol,
) {
  if (introductoryOffer == null) {
    return null;
  }
  final duration = _formatStoreKitDuration(
    introductoryOffer.period.value,
    introductoryOffer.period.unit.name,
    repeatCount: introductoryOffer.periodCount,
  );
  if (introductoryOffer.paymentMode ==
      SK2SubscriptionOfferPaymentMode.freeTrial) {
    return duration == null
        ? 'Free trial for eligible new customers'
        : '$duration free trial for eligible new customers';
  }
  final priceLabel =
      '$currencySymbol${introductoryOffer.price.toStringAsFixed(2)}';
  return duration == null
      ? 'Introductory pricing available'
      : '$priceLabel for $duration';
}

String? _formatPricingPhaseDuration(PricingPhaseWrapper pricingPhase) =>
    _formatIsoDuration(
      pricingPhase.billingPeriod,
      repeatCount: pricingPhase.billingCycleCount == 0
          ? 1
          : pricingPhase.billingCycleCount,
    );

String? _formatStoreKitDuration(
  int unitCount,
  String unitName, {
  required int repeatCount,
}) {
  final totalUnits = unitCount * repeatCount;
  return switch (unitName.toLowerCase()) {
    'day' => _pluralize(totalUnits, 'day'),
    'week' => _pluralize(totalUnits, 'week'),
    'month' => _pluralize(totalUnits, 'month'),
    'year' => _pluralize(totalUnits, 'year'),
    _ => null,
  };
}

String? _formatIsoDuration(String isoDuration, {required int repeatCount}) {
  final match = RegExp(
    r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$',
  ).firstMatch(isoDuration.toUpperCase());
  if (match == null) {
    return null;
  }
  final years = (int.tryParse(match.group(1) ?? '') ?? 0) * repeatCount;
  final months = (int.tryParse(match.group(2) ?? '') ?? 0) * repeatCount;
  final weeks = (int.tryParse(match.group(3) ?? '') ?? 0) * repeatCount;
  final days = (int.tryParse(match.group(4) ?? '') ?? 0) * repeatCount;
  final parts = <String>[
    if (years > 0) _pluralize(years, 'year'),
    if (months > 0) _pluralize(months, 'month'),
    if (weeks > 0) _pluralize(weeks, 'week'),
    if (days > 0) _pluralize(days, 'day'),
  ];
  if (parts.isEmpty) {
    return null;
  }
  return parts.join(' ');
}

String _pluralize(int count, String unit) =>
    count == 1 ? '1 $unit' : '$count ${unit}s';

String _extractCurrencySymbol(
  String formattedPrice,
  String fallbackCurrencyCode,
) {
  final currencySymbol = RegExp(
    r'^[^\d ]+|[^\d ]+$',
  ).firstMatch(formattedPrice)?.group(0);
  if (currencySymbol == null || currencySymbol.isEmpty) {
    return fallbackCurrencyCode;
  }
  return currencySymbol;
}

class _MonetizationCatalog {
  const _MonetizationCatalog({
    required this.offers,
    required this.purchaseOptionsByOfferId,
  });

  final List<MonetizationOffer> offers;
  final Map<String, _MonetizationPurchaseOption> purchaseOptionsByOfferId;
}

class _MonetizationPurchaseOption {
  const _MonetizationPurchaseOption({
    required this.productDetails,
    this.offerToken,
  });

  final ProductDetails productDetails;
  final String? offerToken;
}

class _CatalogOfferCandidate {
  const _CatalogOfferCandidate({
    required this.groupKey,
    required this.preferenceRank,
    required this.offer,
    required this.purchaseOption,
  });

  final String groupKey;
  final int preferenceRank;
  final MonetizationOffer offer;
  final _MonetizationPurchaseOption purchaseOption;
}
