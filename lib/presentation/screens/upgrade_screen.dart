import 'package:collection/collection.dart';
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
  String? _selectedOfferId;

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
    final result = await ref
        .read(monetizationServiceProvider)
        .restorePurchases();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
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
    final manageSubscriptionUrl = _manageSubscriptionUrl();
    final state =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final feature = widget.feature;
    final selectedOffer =
        state.offers.firstWhereOrNull(
          (offer) => offer.id == _selectedOfferId,
        ) ??
        state.defaultOffer;
    final priceLabel =
        selectedOffer?.displayPriceLabel ??
        (state.isLoading
            ? 'Loading pricing...'
            : 'Pricing loads from the App Store or Google Play');
    final priceDetailLabel =
        selectedOffer?.detailLabel ??
        (selectedOffer == null
            ? 'The exact price comes from your local storefront and currency.'
            : null);
    final introductoryOfferLabel = selectedOffer?.introductoryOfferLabel;
    final purchaseLabel = selectedOffer == null
        ? 'Subscription unavailable'
        : 'Continue with ${selectedOffer.planLabel}';

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
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          if (feature != null) ...[
            const SizedBox(height: 20),
            _UpgradeReasonCard(feature: feature),
          ],
          const SizedBox(height: 24),
          Text(
            'Included with Pro',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
            Text(
              'Choose a plan',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: selectedOffer?.id,
              onChanged: state.isLoading
                  ? (_) {}
                  : (value) => setState(() => _selectedOfferId = value),
              child: Column(
                children: state.offers
                    .map(
                      (offer) => Card(
                        clipBehavior: Clip.antiAlias,
                        child: RadioListTile<String>(
                          value: offer.id,
                          selected: selectedOffer?.id == offer.id,
                          enabled: !state.isLoading,
                          title: Text(offer.planLabel),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(offer.displayPriceLabel),
                              if (offer.detailLabel case final detail?)
                                Text(detail),
                              if (offer.introductoryOfferLabel
                                  case final intro?)
                                Text(intro),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
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
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (priceDetailLabel case final detail?) ...[
                    Text(detail, style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 8),
                  ],
                  if (introductoryOfferLabel case final intro?) ...[
                    Text(
                      intro,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    state.isProUnlocked
                        ? 'MonkeySSH Pro is already unlocked on this device.'
                        : 'No trial traps, fake urgency, or hidden close buttons. You can restore or manage your subscription from Settings at any time.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (state.lastError case final error?
                      when error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed:
                state.isProUnlocked || state.isLoading || selectedOffer == null
                ? null
                : () => _purchasePro(selectedOffer.id),
            child: Text(state.isLoading ? 'Working...' : purchaseLabel),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: state.isLoading ? null : _restorePurchases,
            child: const Text('Restore purchases'),
          ),
          TextButton(
            onPressed: state.isLoading || manageSubscriptionUrl == null
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
