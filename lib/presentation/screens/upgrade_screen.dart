import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../widgets/premium_badge.dart';

/// Upgrade screen for MonkeySSH Pro.
class UpgradeScreen extends ConsumerStatefulWidget {
  /// Creates a new [UpgradeScreen].
  const UpgradeScreen({this.feature, super.key});

  /// Feature that triggered the upgrade flow, when known.
  final MonetizationFeature? feature;

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  var _restoreInProgress = false;

  String _pricingSourceLabel() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'Pricing loads from the App Store',
    TargetPlatform.android => 'Pricing loads from Google Play',
    _ => 'Pricing loads from your local storefront',
  };

  Future<void> _purchasePro(String offerId) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref
        .read(monetizationServiceProvider)
        .purchaseOffer(offerId);
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _restorePurchases() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _restoreInProgress = true);
    try {
      final result = await ref
          .read(monetizationServiceProvider)
          .restorePurchases();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(result.message)));
    } finally {
      if (mounted) {
        setState(() => _restoreInProgress = false);
      }
    }
  }

  Uri? _manageSubscriptionUrl() => switch (defaultTargetPlatform) {
    TargetPlatform.iOS => Uri.parse(
      'https://apps.apple.com/account/subscriptions',
    ),
    TargetPlatform.android => Uri.parse(
      'https://play.google.com/store/account/subscriptions',
    ),
    _ => null,
  };

  Future<void> _openManageSubscriptions() async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _manageSubscriptionUrl();
    if (url == null) {
      return;
    }
    final canOpen = await canLaunchUrl(url);
    if (!canOpen) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not open the subscription management page.'),
          ),
        );
      }
      return;
    }
    final didOpen = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!didOpen && mounted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not open the subscription management page.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final manageSubscriptionUrl = _manageSubscriptionUrl();
    final state =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final isCatalogLoading = state.isLoading && state.offers.isEmpty;
    final isBusy = isCatalogLoading || _restoreInProgress;
    final feature = widget.feature;
    final highlightedOffer = state.activeOffer ?? state.defaultOffer;
    final priceLabel =
        highlightedOffer?.displayPriceLabel ??
        (isCatalogLoading ? 'Loading pricing...' : _pricingSourceLabel());
    final priceDetailLabel =
        highlightedOffer?.detailLabel ??
        (highlightedOffer == null
            ? 'The exact price comes from your local storefront and currency.'
            : null);
    final introductoryOfferLabel = highlightedOffer?.introductoryOfferLabel;

    return Scaffold(
      appBar: AppBar(title: const Text('MonkeySSH Pro')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              const PremiumBadge(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Unlock the workflow extras that make remote coding-agent sessions faster to start and easier to move between devices.',
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          if (feature != null) ...[
            const SizedBox(height: 20),
            _UpgradeReasonCard(feature: feature),
          ],
          const SizedBox(height: 24),
          Text('Included with Pro', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          const _UpgradeBenefitTile(
            icon: Icons.rocket_launch_outlined,
            title: 'Agent launch presets',
            subtitle:
                'Save repeatable startup flows per host for tools like Codex, Claude Code, Copilot CLI, or OpenCode.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.play_circle_outline,
            title: 'Auto-connect workflows',
            subtitle:
                'Run a command or saved snippet automatically after opening a terminal.',
          ),
          const _UpgradeBenefitTile(
            icon: Icons.swap_horiz_outlined,
            title: 'Encrypted transfers',
            subtitle:
                'Share hosts, keys, and migration bundles through encrypted files.',
          ),
          if (state.offers.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Choose a plan', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Column(
              children: state.offers
                  .map(
                    (offer) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PlanOfferCard(
                        offer: offer,
                        isCurrentPlan: state.isActiveOffer(offer),
                        hasAnyActiveSubscription: state.isProUnlocked,
                        isBusy: isBusy,
                        canManageSubscription: manageSubscriptionUrl != null,
                        onSelect: () => _purchasePro(offer.id),
                        onManage: _openManageSubscriptions,
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    priceLabel,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (priceDetailLabel case final detail?) ...[
                    Text(detail, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 8),
                  ],
                  if (introductoryOfferLabel case final intro?) ...[
                    Text(
                      intro,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    state.isProUnlocked
                        ? switch (state.activeOffer) {
                            final activeOffer? =>
                              '${activeOffer.planLabel} is active on this device.',
                            null =>
                              'MonkeySSH Pro is already unlocked on this device.',
                          }
                        : 'No trial traps, fake urgency, or hidden close buttons. You can restore or manage your subscription from Settings at any time.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (state.lastError case final error?
                      when error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: isBusy ? null : _restorePurchases,
            child: Text(
              _restoreInProgress ? 'Working...' : 'Restore purchases',
            ),
          ),
          TextButton(
            onPressed: isBusy || manageSubscriptionUrl == null
                ? null
                : _openManageSubscriptions,
            child: const Text('Manage subscription'),
          ),
          if (state.debugUnlockAvailable) ...[
            const SizedBox(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Debug: local Pro unlock'),
              subtitle: const Text(
                'Development-only switch for testing premium flows before the store product is live.',
              ),
              value: state.debugUnlocked,
              onChanged: (value) => ref
                  .read(monetizationServiceProvider)
                  .setDebugUnlocked(unlocked: value),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanOfferCard extends StatelessWidget {
  const _PlanOfferCard({
    required this.offer,
    required this.isCurrentPlan,
    required this.hasAnyActiveSubscription,
    required this.isBusy,
    required this.canManageSubscription,
    required this.onSelect,
    required this.onManage,
  });

  final MonetizationOffer offer;
  final bool isCurrentPlan;
  final bool hasAnyActiveSubscription;
  final bool isBusy;
  final bool canManageSubscription;
  final VoidCallback onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cardColor = isCurrentPlan
        ? Color.alphaBlend(colorScheme.primary.withAlpha(24), theme.cardColor)
        : theme.cardColor;
    final actionLabel = isCurrentPlan
        ? canManageSubscription
              ? 'Manage current plan'
              : 'Current plan'
        : hasAnyActiveSubscription
        ? 'Switch to ${offer.planLabel}'
        : 'Subscribe ${offer.planLabel.toLowerCase()}';
    final onTap = isBusy
        ? null
        : isCurrentPlan
        ? (canManageSubscription ? onManage : null)
        : onSelect;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isCurrentPlan
              ? colorScheme.primary
              : colorScheme.outlineVariant,
          width: isCurrentPlan ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      offer.planLabel,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (isCurrentPlan)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withAlpha(26),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Current',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                offer.displayPriceLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (offer.detailLabel case final detail?) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (offer.introductoryOfferLabel case final intro?) ...[
                const SizedBox(height: 8),
                Text(
                  intro,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onTap, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpgradeReasonCard extends StatelessWidget {
  const _UpgradeReasonCard({required this.feature});

  final MonetizationFeature feature;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${feature.label} is part of MonkeySSH Pro',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(feature.description),
        ],
      ),
    ),
  );
}

class _UpgradeBenefitTile extends StatelessWidget {
  const _UpgradeBenefitTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
  );
}
