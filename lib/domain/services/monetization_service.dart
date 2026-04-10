import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/monetization.dart';
import 'settings_service.dart';

/// Coordinates local premium state and mobile store purchase flows.
class MonetizationService {
  /// Creates a new [MonetizationService].
  MonetizationService(
    this._settings, {
    InAppPurchase? inAppPurchase,
    bool? allowDebugUnlock,
  }) : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
       _allowDebugUnlock = allowDebugUnlock ?? kDebugMode;

  final SettingsService _settings;
  final InAppPurchase _inAppPurchase;
  final bool _allowDebugUnlock;
  final _controller = StreamController<MonetizationState>.broadcast();
  final _productDetailsById = <String, ProductDetails>{};

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  Completer<MonetizationActionResult>? _pendingPurchaseResult;
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
      _productDetailsById.clear();
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
      MonetizationProductIds.all,
    );
    _productDetailsById
      ..clear()
      ..addEntries(
        response.productDetails.map((details) => MapEntry(details.id, details)),
      );
    final offers = response.productDetails
        .map(
          (details) => MonetizationOffer(
            productId: details.id,
            title: details.title,
            description: details.description,
            priceLabel: details.price,
          ),
        )
        .sortedBy((offer) => offer.productId)
        .toList(growable: false);

    _emit(
      _state.copyWith(
        isLoading: false,
        billingAvailability: MonetizationBillingAvailability.available,
        offers: offers,
        lastError: response.error?.message,
      ),
    );
  }

  /// Whether [feature] is currently unlocked.
  Future<bool> canUseFeature(MonetizationFeature feature) async {
    await initialize();
    return _state.allowsFeature(feature);
  }

  /// Starts the Pro subscription purchase flow.
  Future<MonetizationActionResult> purchaseProMonthly() async {
    await initialize();
    if (!_supportsStoreBilling) {
      return const MonetizationActionResult.failure(
        'Subscriptions are only available on iPhone and Android.',
      );
    }
    final details = _productDetailsById[MonetizationProductIds.proMonthly];
    if (details == null) {
      await refreshCatalog();
    }
    final resolvedDetails =
        _productDetailsById[MonetizationProductIds.proMonthly];
    if (resolvedDetails == null) {
      return const MonetizationActionResult.failure(
        'The subscription is not currently available.',
      );
    }

    final completer = Completer<MonetizationActionResult>();
    _pendingPurchaseResult = completer;
    _emit(_state.copyWith(isLoading: true, lastError: null));
    final started = await _inAppPurchase.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: resolvedDetails),
    );
    if (!started) {
      _pendingPurchaseResult = null;
      _emit(_state.copyWith(isLoading: false));
      return const MonetizationActionResult.failure(
        'Could not start the purchase flow.',
      );
    }

    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _pendingPurchaseResult = null;
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
    _emit(_state.copyWith(isLoading: true, lastError: null));
    await _inAppPurchase.restorePurchases();

    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _pendingPurchaseResult = null;
        _emit(_state.copyWith(isLoading: false));
        if (_state.isProUnlocked) {
          return const MonetizationActionResult.success(
            'MonkeySSH Pro is already unlocked on this device.',
          );
        }
        return const MonetizationActionResult.failure(
          'No active subscription could be restored.',
        );
      },
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
      if (!MonetizationProductIds.all.contains(purchase.productID)) {
        continue;
      }

      switch (purchase.status) {
        case PurchaseStatus.pending:
          _emit(_state.copyWith(isLoading: true, lastError: null));
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
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
  }

  Future<void> _completePurchaseIfNeeded(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _inAppPurchase.completePurchase(purchase);
    }
  }

  void _resolvePendingPurchase(MonetizationActionResult result) {
    final completer = _pendingPurchaseResult;
    if (completer == null || completer.isCompleted) {
      return;
    }
    _pendingPurchaseResult = null;
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
