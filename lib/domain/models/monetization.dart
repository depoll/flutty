import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// Product identifiers used by the mobile subscription flow.
abstract final class MonetizationProductIds {
  /// Google Play subscription product.
  static const androidPro = 'monkeyssh_pro';

  /// App Store monthly subscription product.
  static const iosMonthly = 'monkeyssh_pro_monthly';

  /// App Store annual subscription product.
  static const iosAnnual = 'monkeyssh_pro_annual';

  /// All recognized paid products across platforms.
  static const allKnown = <String>{androidPro, iosMonthly, iosAnnual};

  /// Product identifiers to query on the current platform.
  static Set<String> forPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android => {androidPro},
    TargetPlatform.iOS => {iosMonthly, iosAnnual},
    _ => const {},
  };
}

/// Premium features controlled by MonkeySSH Pro.
enum MonetizationFeature {
  /// Encrypted host and key transfer bundles.
  encryptedTransfers,

  /// Full app migration import/export packages.
  migrationImportExport,

  /// Auto-connect commands and snippets.
  autoConnectAutomation,

  /// Guided launch presets for coding-agent CLIs.
  agentLaunchPresets,
}

/// Presentation helpers for [MonetizationFeature].
extension MonetizationFeaturePresentation on MonetizationFeature {
  /// Human-readable label for this premium feature.
  String get label => switch (this) {
    MonetizationFeature.encryptedTransfers => 'Encrypted transfers',
    MonetizationFeature.migrationImportExport => 'Migration import/export',
    MonetizationFeature.autoConnectAutomation => 'Auto-connect automation',
    MonetizationFeature.agentLaunchPresets => 'Agent launch presets',
  };

  /// Plain-language description shown in upgrade prompts.
  String get description => switch (this) {
    MonetizationFeature.encryptedTransfers =>
      'Share encrypted host and key bundles between devices.',
    MonetizationFeature.migrationImportExport =>
      'Move the whole app state with encrypted migration packages.',
    MonetizationFeature.autoConnectAutomation =>
      'Run commands or saved snippets automatically after connect.',
    MonetizationFeature.agentLaunchPresets =>
      'Save repeatable startup flows for tools like Codex, Claude Code, Copilot CLI, or OpenCode.',
  };
}

/// Whether store billing can be used on the current device.
enum MonetizationBillingAvailability {
  /// Billing has not been checked yet.
  unknown,

  /// Billing is unsupported on this platform.
  unsupported,

  /// Billing is supported but currently unavailable.
  unavailable,

  /// Billing is supported and product information was loaded.
  available,
}

/// Billing period for a MonkeySSH Pro plan.
enum MonetizationBillingPeriod {
  /// Monthly billing cadence.
  monthly,

  /// Annual billing cadence.
  annual,

  /// A billing cadence that could not be identified.
  unknown,
}

/// Presentation helpers for [MonetizationBillingPeriod].
extension MonetizationBillingPeriodPresentation on MonetizationBillingPeriod {
  /// Human-readable plan title.
  String get label => switch (this) {
    MonetizationBillingPeriod.monthly => 'Monthly',
    MonetizationBillingPeriod.annual => 'Annual',
    MonetizationBillingPeriod.unknown => 'MonkeySSH Pro',
  };

  /// Short suffix for billing copy.
  String get billingSuffix => switch (this) {
    MonetizationBillingPeriod.monthly => 'month',
    MonetizationBillingPeriod.annual => 'year',
    MonetizationBillingPeriod.unknown => 'billing period',
  };
}

/// Current subscription entitlements.
class MonetizationEntitlements {
  /// Creates a new [MonetizationEntitlements].
  const MonetizationEntitlements({required this.proUnlocked});

  /// No premium features are unlocked.
  const MonetizationEntitlements.free() : proUnlocked = false;

  /// MonkeySSH Pro is unlocked.
  const MonetizationEntitlements.pro() : proUnlocked = true;

  /// Whether MonkeySSH Pro is active.
  final bool proUnlocked;

  /// Whether this entitlement unlocks [feature].
  bool allows(MonetizationFeature feature) => proUnlocked;
}

/// Store offer that can unlock MonkeySSH Pro.
class MonetizationOffer {
  /// Creates a new [MonetizationOffer].
  const MonetizationOffer({
    required this.id,
    required this.productId,
    required this.billingPeriod,
    required this.planLabel,
    required this.priceLabel,
    required this.displayPriceLabel,
    required this.rawPrice,
    required this.currencyCode,
    required this.currencySymbol,
    this.detailLabel,
    this.introductoryOfferLabel,
  });

  /// Unique identifier for this selectable offer.
  final String id;

  /// Store product identifier.
  final String productId;

  /// Billing period represented by this offer.
  final MonetizationBillingPeriod billingPeriod;

  /// Human-readable plan title.
  final String planLabel;

  /// Store-provided recurring price string.
  final String priceLabel;

  /// UI-ready recurring price label with billing cadence.
  final String displayPriceLabel;

  /// Raw recurring price in the store currency.
  final double rawPrice;

  /// ISO currency code for this offer.
  final String currencyCode;

  /// Currency symbol for this offer locale.
  final String currencySymbol;

  /// Secondary billing detail for this offer.
  final String? detailLabel;

  /// Introductory offer copy, such as a free trial.
  final String? introductoryOfferLabel;

  /// Whether this offer includes an introductory discount or trial.
  bool get hasIntroductoryOffer => introductoryOfferLabel != null;
}

/// Current billing and entitlement state for MonkeySSH Pro.
class MonetizationState {
  /// Creates a new [MonetizationState].
  const MonetizationState({
    required this.billingAvailability,
    required this.entitlements,
    required this.offers,
    required this.debugUnlockAvailable,
    required this.debugUnlocked,
    this.activeProductId,
    this.entitlementUpdatedAt,
    this.lastError,
    this.isLoading = false,
  });

  /// Creates the initial free state.
  factory MonetizationState.initial({required bool debugUnlockAvailable}) =>
      MonetizationState(
        billingAvailability: MonetizationBillingAvailability.unknown,
        entitlements: const MonetizationEntitlements.free(),
        offers: const [],
        debugUnlockAvailable: debugUnlockAvailable,
        debugUnlocked: false,
      );

  /// Store billing availability on the current device.
  final MonetizationBillingAvailability billingAvailability;

  /// Current premium entitlements.
  final MonetizationEntitlements entitlements;

  /// Loaded subscription offers.
  final List<MonetizationOffer> offers;

  /// Whether a debug-only local unlock switch should be shown.
  final bool debugUnlockAvailable;

  /// Whether the debug-only local unlock is active.
  final bool debugUnlocked;

  /// Product ID that most recently unlocked Pro, if known.
  final String? activeProductId;

  /// Timestamp of the most recent entitlement update.
  final DateTime? entitlementUpdatedAt;

  /// Last billing-related error surfaced to the UI.
  final String? lastError;

  /// Whether a billing action is in flight.
  final bool isLoading;

  /// Whether MonkeySSH Pro is currently unlocked.
  bool get isProUnlocked => entitlements.proUnlocked;

  /// Default offer to preselect on the paywall, if any.
  MonetizationOffer? get defaultOffer =>
      offers.firstWhereOrNull(
        (offer) => offer.billingPeriod == MonetizationBillingPeriod.monthly,
      ) ??
      (offers.isEmpty ? null : offers.first);

  /// Whether [feature] is currently available.
  bool allowsFeature(MonetizationFeature feature) =>
      entitlements.allows(feature);

  /// Returns a copy of this state with selected fields replaced.
  MonetizationState copyWith({
    MonetizationBillingAvailability? billingAvailability,
    MonetizationEntitlements? entitlements,
    List<MonetizationOffer>? offers,
    bool? debugUnlockAvailable,
    bool? debugUnlocked,
    Object? activeProductId = _unsetField,
    Object? entitlementUpdatedAt = _unsetField,
    Object? lastError = _unsetField,
    bool? isLoading,
  }) => MonetizationState(
    billingAvailability: billingAvailability ?? this.billingAvailability,
    entitlements: entitlements ?? this.entitlements,
    offers: offers ?? this.offers,
    debugUnlockAvailable: debugUnlockAvailable ?? this.debugUnlockAvailable,
    debugUnlocked: debugUnlocked ?? this.debugUnlocked,
    activeProductId: identical(activeProductId, _unsetField)
        ? this.activeProductId
        : activeProductId as String?,
    entitlementUpdatedAt: identical(entitlementUpdatedAt, _unsetField)
        ? this.entitlementUpdatedAt
        : entitlementUpdatedAt as DateTime?,
    lastError: identical(lastError, _unsetField)
        ? this.lastError
        : lastError as String?,
    isLoading: isLoading ?? this.isLoading,
  );
}

/// Result of a purchase or restore action.
class MonetizationActionResult {
  /// Creates a new [MonetizationActionResult].
  const MonetizationActionResult({
    required this.success,
    required this.cancelled,
    required this.message,
  });

  /// Creates a successful result.
  const MonetizationActionResult.success(String message)
    : this(success: true, cancelled: false, message: message);

  /// Creates a failed result.
  const MonetizationActionResult.failure(String message)
    : this(success: false, cancelled: false, message: message);

  /// Creates a cancelled result.
  const MonetizationActionResult.cancelled(String message)
    : this(success: false, cancelled: true, message: message);

  /// Whether the action succeeded.
  final bool success;

  /// Whether the user cancelled the action.
  final bool cancelled;

  /// Human-readable result message.
  final String message;
}

const _unsetField = Object();
