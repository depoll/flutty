import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A loading placeholder that mimics the shape of a list of rows (a leading
/// block plus two text bars), so a loading surface teaches its eventual layout
/// instead of showing a bare centered spinner.
///
/// The placeholder is intentionally static (no looping animation): a calm,
/// settled skeleton reads as "loading" without an infinite ticker that would
/// stall `pumpAndSettle` in tests or burn frames behind a brief async wait.
class BrandListSkeleton extends StatelessWidget {
  /// Creates a [BrandListSkeleton].
  const BrandListSkeleton({
    this.rowCount = 6,
    this.padding = const EdgeInsets.symmetric(
      horizontal: FluttyTheme.spacingMd,
      vertical: FluttyTheme.spacingSm,
    ),
    super.key,
  });

  /// Number of placeholder rows to render.
  final int rowCount;

  /// Padding around the list of placeholder rows.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: padding,
    physics: const NeverScrollableScrollPhysics(),
    itemCount: rowCount,
    itemBuilder: (context, i) => Padding(
      padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
      child: _SkeletonRow(titleFraction: i.isEven ? 0.55 : 0.42),
    ),
  );
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.titleFraction});

  final double titleFraction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final block = colorScheme.onSurface.withAlpha(20);
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: block,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          ),
        ),
        const SizedBox(width: FluttyTheme.spacingMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: titleFraction,
                child: _bar(block, 12),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: titleFraction + 0.25,
                child: _bar(block, 10),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bar(Color color, double height) => Container(
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
    ),
  );
}
