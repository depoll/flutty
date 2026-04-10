/// Product identifiers used by the mobile subscription flow.
abstract final class MonetizationProductIds {
  /// MonkeySSH Pro subscription product.
  static const pro = 'monkeyssh_pro';

  /// All recognized paid products.
  static const all = <String>{pro};
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
      'Save repeatable Claude Code, Copilot CLI, or Aider startup flows.',
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
    required this.productId,
    required this.title,
    required this.description,
    required this.priceLabel,
  });

  /// Store product identifier.
  final String productId;

  /// Offer title.
  final String title;

  /// Offer description.
  final String description;

  /// Store-provided price string.
  final String priceLabel;
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

  /// First offer to show on the paywall, if any.
  MonetizationOffer? get primaryOffer => offers.isEmpty ? null : offers.first;

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
