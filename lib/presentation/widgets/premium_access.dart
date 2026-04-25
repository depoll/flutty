import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../screens/upgrade_screen.dart';

/// Ensures [feature] is unlocked before continuing.
Future<bool> requireMonetizationFeatureAccess({
  required BuildContext context,
  required WidgetRef ref,
  required MonetizationFeature feature,
  String? blockedAction,
  String? blockedOutcome,
}) async {
  final service = ref.read(monetizationServiceProvider);
  if (await service.canUseFeature(feature)) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    final queryParameters = <String, String>{'feature': feature.name};
    if (blockedAction != null) {
      queryParameters['action'] = blockedAction;
    }
    if (blockedOutcome != null) {
      queryParameters['outcome'] = blockedOutcome;
    }
    await context.pushNamed(Routes.upgrade, queryParameters: queryParameters);
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => UpgradeScreen(
          feature: feature,
          blockedAction: blockedAction,
          blockedOutcome: blockedOutcome,
        ),
      ),
    );
  }
  if (!context.mounted) {
    return false;
  }
  return service.canUseFeature(feature);
}
