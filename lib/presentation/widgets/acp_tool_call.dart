import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_chat_typography.dart';
import 'acp_diff.dart';
import 'acp_inline_image.dart';

/// Presentation helpers for [AcpToolStatus].
extension AcpToolStatusPresentation on AcpToolStatus {
  /// Short human-readable label for the status.
  String get label => switch (this) {
    AcpToolStatus.pending => 'Pending',
    AcpToolStatus.running => 'Running',
    AcpToolStatus.completed => 'Completed',
    AcpToolStatus.failed => 'Failed',
    AcpToolStatus.cancelled => 'Cancelled',
  };
}

/// Presentation helpers for [AcpToolKind].
extension AcpToolKindPresentation on AcpToolKind {
  /// Icon representing the tool kind.
  IconData get icon => switch (this) {
    AcpToolKind.read => Icons.description_outlined,
    AcpToolKind.edit => Icons.edit_outlined,
    AcpToolKind.delete => Icons.delete_outline,
    AcpToolKind.move => Icons.drive_file_move_outlined,
    AcpToolKind.search => Icons.search,
    AcpToolKind.execute => Icons.terminal_rounded,
    AcpToolKind.fetch => Icons.cloud_download_outlined,
    AcpToolKind.think => Icons.psychology_outlined,
    AcpToolKind.other => Icons.build_outlined,
  };
}

/// Renders a single tool call as a compact, expandable status row.
///
/// The row shows a kind icon, title, and a status badge conveyed with both an
/// icon and text (never colour alone). Expanding reveals input, output, file
/// locations, and unified diffs. It uses no nested cards and no coloured side
/// stripes; detail sections use tonal tints. The row is stateless in look but
/// tracks its own expansion state.
class AcpToolCallView extends StatefulWidget {
  /// Creates a tool call view.
  const AcpToolCallView({
    required this.toolCall,
    super.key,
    this.initiallyExpanded = false,
    this.onOpenLocation,
  });

  /// The merged tool call state to render.
  final AcpToolCall toolCall;

  /// Whether the detail section is expanded initially.
  final bool initiallyExpanded;

  /// Called when a file location is tapped.
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  @override
  State<AcpToolCallView> createState() => _AcpToolCallViewState();
}

class _AcpToolCallViewState extends State<AcpToolCallView> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _hasDetails {
    final call = widget.toolCall;
    return (call.rawInput?.isNotEmpty ?? false) ||
        (call.rawOutput?.isNotEmpty ?? false) ||
        call.locations.isNotEmpty ||
        call.diffs.isNotEmpty;
  }

  ({IconData icon, Color color, bool spinning}) _statusVisual(
    ColorScheme scheme,
  ) => switch (widget.toolCall.status) {
    AcpToolStatus.pending => (
      icon: Icons.schedule,
      color: scheme.onSurfaceVariant,
      spinning: false,
    ),
    AcpToolStatus.running => (
      icon: Icons.sync,
      color: scheme.primary,
      spinning: true,
    ),
    AcpToolStatus.completed => (
      icon: Icons.check_circle_outline,
      color: scheme.primary,
      spinning: false,
    ),
    AcpToolStatus.failed => (
      icon: Icons.error_outline,
      color: scheme.error,
      spinning: false,
    ),
    AcpToolStatus.cancelled => (
      icon: Icons.cancel_outlined,
      color: scheme.onSurfaceVariant,
      spinning: false,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final call = widget.toolCall;
    final status = call.status;
    final visual = _statusVisual(scheme);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final header = InkWell(
      onTap: _hasDetails ? () => setState(() => _expanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingSm,
            vertical: FluttyTheme.spacingXs,
          ),
          child: Row(
            children: [
              Icon(call.kind.icon, size: 17, color: scheme.onSurfaceVariant),
              const SizedBox(width: FluttyTheme.spacingSm),
              Expanded(
                child: Text(
                  call.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AcpChatTypography.monoStyleOf(context).copyWith(
                    color: scheme.onSurface,
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: FluttyTheme.spacingSm),
              _StatusBadge(
                icon: visual.icon,
                color: visual.color,
                label: status.label,
                spinning: visual.spinning && !reduceMotion,
              ),
              if (_hasDetails)
                Padding(
                  padding: const EdgeInsets.only(left: FluttyTheme.spacingXs),
                  child: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    final imageActions = AcpImageActions.maybeOf(context);
    return Semantics(
      container: true,
      label: '${call.title}, ${status.label}',
      value: _hasDetails ? (_expanded ? 'expanded' : 'collapsed') : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (call.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                0,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < call.images.length; index++) ...[
                    if (index > 0)
                      const SizedBox(height: FluttyTheme.spacingSm),
                    AcpInlineImage(
                      image: call.images[index],
                      resolver: imageActions?.resolver,
                      onTap: imageActions?.onTap,
                    ),
                  ],
                ],
              ),
            ),
          if (_expanded && _hasDetails)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FluttyTheme.spacingSm,
                0,
                FluttyTheme.spacingSm,
                FluttyTheme.spacingSm,
              ),
              child: _ToolCallDetails(
                toolCall: call,
                onOpenLocation: widget.onOpenLocation,
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.icon,
    required this.color,
    required this.label,
    required this.spinning,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool spinning;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (spinning)
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        )
      else
        Icon(icon, size: 14, color: color),
      const SizedBox(width: FluttyTheme.spacingXs),
      Text(
        label,
        style: AcpChatTypography.monoStyleOf(
          context,
        ).copyWith(fontSize: 11, color: color),
      ),
    ],
  );
}

class _ToolCallDetails extends StatelessWidget {
  const _ToolCallDetails({required this.toolCall, this.onOpenLocation});

  final AcpToolCall toolCall;
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    final input = toolCall.rawInput;
    if (input != null && input.isNotEmpty) {
      children.add(_LabeledMonoBlock(label: 'Input', text: input));
    }
    if (toolCall.locations.isNotEmpty) {
      children.add(
        _LocationsSection(
          locations: toolCall.locations,
          onOpenLocation: onOpenLocation,
        ),
      );
    }
    for (final diff in toolCall.diffs) {
      children.add(AcpDiffView(diff: diff));
    }
    final output = toolCall.rawOutput;
    if (output != null && output.isNotEmpty) {
      children.add(_LabeledMonoBlock(label: 'Output', text: output));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: FluttyTheme.spacingSm),
          children[i],
        ],
      ],
    );
  }
}

class _LabeledMonoBlock extends StatelessWidget {
  const _LabeledMonoBlock({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: FluttyTheme.spacingXs),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          ),
          child: Padding(
            padding: const EdgeInsets.all(FluttyTheme.spacingSm),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                text,
                style: AcpChatTypography.monoStyleOf(
                  context,
                ).copyWith(fontSize: 12, color: scheme.onSurface, height: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LocationsSection extends StatelessWidget {
  const _LocationsSection({required this.locations, this.onOpenLocation});

  final List<AcpToolLocation> locations;
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          locations.length == 1 ? 'Location' : 'Locations',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: FluttyTheme.spacingXs),
        for (final location in locations)
          _LocationRow(location: location, onOpen: onOpenLocation),
      ],
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.location, this.onOpen});

  final AcpToolLocation location;
  final ValueChanged<AcpToolLocation>? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = location.line;
    final label = line != null ? '${location.path}:$line' : location.path;
    final onOpen = this.onOpen;
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.chevron_right, size: 14, color: scheme.onSurfaceVariant),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AcpChatTypography.monoStyleOf(context).copyWith(
                fontSize: 12,
                color: onOpen != null ? scheme.primary : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: onOpen != null,
      label: 'Location $label',
      child: onOpen == null
          ? content
          : InkWell(
              onTap: () => onOpen(location),
              borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
              child: content,
            ),
    );
  }
}
