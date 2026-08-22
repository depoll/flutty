import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_inline_image.dart';
import 'acp_markdown.dart';
import 'acp_plan.dart';
import 'acp_status_entry.dart';
import 'acp_thought.dart';
import 'acp_tool_call.dart';
import 'acp_usage.dart';
import 'acp_user_prompt.dart';

/// Builds the compact context shown when a user prompt is above the viewport.
String acpUserPromptSummary(AcpUserPromptEntry entry) {
  final text = entry.parts
      .whereType<AcpTextPart>()
      .map((part) => part.text.trim())
      .where((part) => part.isNotEmpty)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (text.isNotEmpty) {
    return text.length <= 240 ? text : '${text.substring(0, 239)}…';
  }

  final attachments = <String>[
    for (final part in entry.parts)
      switch (part) {
        AcpImagePart(:final image) =>
          (image.label?.trim().isNotEmpty ?? false)
              ? image.label!.trim()
              : 'Image',
        AcpResourcePart(:final resource) => resource.displayName,
        AcpTextPart() => '',
      },
  ]..removeWhere((label) => label.isEmpty);
  if (attachments.isEmpty) return 'Your message';
  final summary = attachments.join(' · ');
  return summary.length <= 240 ? summary : '${summary.substring(0, 239)}…';
}

/// Renders an ordered list of [AcpTimelineEntry]s as a conversation thread.
///
/// The renderer is suitable for both live streaming and replay. It stays lazy,
/// preserves external scroll-controller behavior, and pins a one-line summary
/// of the user prompt whose following response is currently at the viewport
/// top. The summary disappears whenever that full prompt is itself visible.
class AcpMessageThread extends StatefulWidget {
  /// Creates a message thread.
  const AcpMessageThread({
    required this.entries,
    super.key,
    this.controller,
    this.padding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: FluttyTheme.spacingSm,
    ),
    this.shrinkWrap = false,
    this.physics,
    this.footer,
    this.onStickyPromptTap,
    this.imageResolver,
    this.onTapImage,
    this.onOpenResource,
    this.onCopyResource,
    this.onTapLink,
    this.onCopyCode,
    this.onOpenLocation,
    this.thoughtsInitiallyExpanded = false,
  });

  /// The ordered timeline entries to render.
  final List<AcpTimelineEntry> entries;

  /// Optional scroll controller.
  final ScrollController? controller;

  /// Padding around the list content.
  final EdgeInsetsGeometry padding;

  /// Whether the list shrink-wraps its content.
  final bool shrinkWrap;

  /// Optional scroll physics.
  final ScrollPhysics? physics;

  /// Optional live-state footer rendered after the final transcript entry.
  final Widget? footer;

  /// Called synchronously before a sticky prompt starts navigating upward.
  ///
  /// Containers can use this to suspend live-follow behavior before the scroll
  /// animation begins.
  final VoidCallback? onStickyPromptTap;

  /// Resolver for non-inline images.
  final AcpImageResolver? imageResolver;

  /// Called when an image is tapped.
  final ValueChanged<AcpImageContent>? onTapImage;

  /// Called when a resource chip is opened.
  final ValueChanged<AcpResourceRef>? onOpenResource;

  /// Called when a resource chip is copied.
  final ValueChanged<AcpResourceRef>? onCopyResource;

  /// Custom Markdown link handler; defaults to a safe launcher.
  final MarkdownTapLinkCallback? onTapLink;

  /// Called when a code block is copied.
  final ValueChanged<String>? onCopyCode;

  /// Called when a tool-call file location is opened.
  final ValueChanged<AcpToolLocation>? onOpenLocation;

  /// Whether thought sections start expanded.
  final bool thoughtsInitiallyExpanded;

  @override
  State<AcpMessageThread> createState() => _AcpMessageThreadState();
}

class _AcpMessageThreadState extends State<AcpMessageThread> {
  final GlobalKey _sliverListKey = GlobalKey();
  ScrollController? _ownedController;
  int? _stickyPromptIndex;
  bool _stickyUpdateScheduled = false;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_scheduleStickyUpdate);
    _scheduleStickyUpdate();
  }

  @override
  void didUpdateWidget(covariant AcpMessageThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedController)?.removeListener(
        _scheduleStickyUpdate,
      );
      _controller.addListener(_scheduleStickyUpdate);
    }
    _scheduleStickyUpdate();
  }

  @override
  void dispose() {
    _controller.removeListener(_scheduleStickyUpdate);
    _ownedController?.dispose();
    super.dispose();
  }

  void _scheduleStickyUpdate() {
    if (_stickyUpdateScheduled) return;
    _stickyUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyUpdateScheduled = false;
      if (mounted) _updateStickyPrompt();
    });
  }

  void _updateStickyPrompt() {
    final renderObject = _sliverListKey.currentContext?.findRenderObject();
    if (!_controller.hasClients ||
        renderObject is! RenderSliverMultiBoxAdaptor ||
        renderObject.firstChild == null ||
        widget.entries.isEmpty) {
      _setStickyPromptIndex(null);
      return;
    }

    final viewportTop = renderObject.constraints.scrollOffset;
    var child = renderObject.firstChild;
    int? firstVisibleIndex;
    while (child != null) {
      final childTop = renderObject.childScrollOffset(child) ?? 0;
      final childBottom = childTop + child.size.height;
      if (childBottom > viewportTop + 0.5) {
        firstVisibleIndex = renderObject.indexOf(child);
        break;
      }
      child = renderObject.childAfter(child);
    }
    firstVisibleIndex ??= renderObject.indexOf(renderObject.lastChild!);
    final entryIndex = firstVisibleIndex.clamp(0, widget.entries.length - 1);

    int? promptIndex;
    for (var index = entryIndex; index >= 0; index--) {
      if (widget.entries[index] is AcpUserPromptEntry) {
        promptIndex = index;
        break;
      }
    }
    // If the actual first visible child is the prompt row, its full card still
    // supplies context and the compact duplicate stays detached. A footer uses
    // an index after the entries and must not be mistaken for that prompt.
    final promptIsVisible =
        firstVisibleIndex < widget.entries.length &&
        promptIndex == firstVisibleIndex;
    _setStickyPromptIndex(promptIsVisible ? null : promptIndex);
  }

  void _setStickyPromptIndex(int? value) {
    if (_stickyPromptIndex == value) return;
    setState(() => _stickyPromptIndex = value);
  }

  Future<void> _scrollEntryIntoView(int entryIndex) async {
    if (!_controller.hasClients) return;
    widget.onStickyPromptTap?.call();
    // A sticky prompt can be many screens above the viewport and therefore no
    // longer have a built element. Seek until SliverList materializes it, then
    // animate to its exact scroll offset. RenderObject.showOnScreen is not
    // reliable here because a cached off-screen child may be considered
    // revealed without moving the outer CustomScrollView to its beginning.
    for (var attempt = 0; attempt < 16; attempt++) {
      if (!mounted || !_controller.hasClients) return;
      final sliver = _sliverListKey.currentContext?.findRenderObject();
      if (sliver is! RenderSliverMultiBoxAdaptor ||
          sliver.firstChild == null ||
          sliver.lastChild == null) {
        return;
      }
      final position = _controller.position;
      final sliverOrigin = position.pixels - sliver.constraints.scrollOffset;
      var child = sliver.firstChild;
      while (child != null) {
        if (sliver.indexOf(child) == entryIndex) {
          final childOffset = sliver.childScrollOffset(child);
          if (childOffset == null) return;
          await _controller.animateTo(
            (sliverOrigin + childOffset).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
          return;
        }
        child = sliver.childAfter(child);
      }

      final first = sliver.firstChild!;
      final last = sliver.lastChild!;
      final firstIndex = sliver.indexOf(first);
      final lastIndex = sliver.indexOf(last);
      final firstOffset = sliver.childScrollOffset(first) ?? 0;
      final lastOffset = sliver.childScrollOffset(last) ?? firstOffset;
      final visibleSpan = (lastOffset + last.size.height - firstOffset).abs();
      final averageExtent = (visibleSpan / (lastIndex - firstIndex + 1)).clamp(
        44.0,
        position.viewportDimension * 2,
      );
      final estimate = entryIndex < firstIndex
          ? sliverOrigin +
                firstOffset -
                (firstIndex - entryIndex) * averageExtent
          : sliverOrigin +
                lastOffset +
                (entryIndex - lastIndex) * averageExtent;
      final destination = estimate.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((destination - position.pixels).abs() < 1) return;
      _controller.jumpTo(destination);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Widget _buildEntry(BuildContext context, AcpTimelineEntry entry) {
    switch (entry) {
      case AcpUserPromptEntry():
        return AcpUserPromptView(
          entry: entry,
          imageResolver: widget.imageResolver,
          onTapImage: widget.onTapImage,
          onOpenResource: widget.onOpenResource,
          onCopyResource: widget.onCopyResource,
        );
      case AcpAssistantMessageEntry():
        return _AssistantMessage(
          entry: entry,
          onTapLink: widget.onTapLink,
          imageResolver: widget.imageResolver,
          onTapImage: widget.onTapImage,
          onCopyCode: widget.onCopyCode,
        );
      case AcpThoughtEntry():
        return AcpThoughtView(
          entry: entry,
          initiallyExpanded: widget.thoughtsInitiallyExpanded,
          onTapLink: widget.onTapLink,
          imageResolver: widget.imageResolver,
        );
      case AcpPlanEntry():
        return AcpPlanView(plan: entry.plan);
      case AcpToolCallEntry():
        final tool = AcpToolCallView(
          toolCall: entry.toolCall,
          onOpenLocation: widget.onOpenLocation,
        );
        return entry.isSubagent ? _SubagentLaunchSurface(child: tool) : tool;
      case AcpSubagentTranscriptEntry():
        return _SubagentTranscriptSurface(
          entry: entry,
          childBuilder: (child) => _buildEntry(context, child),
        );
      case AcpUsageEntry():
        return AcpUsageView(usage: entry.usage);
      case AcpStatusEntry():
        return AcpStatusEntryView(entry: entry);
    }
  }

  Widget _buildListChild(BuildContext context, int index) {
    if (index == widget.entries.length) {
      return Padding(
        key: const ValueKey('acp-message-thread-footer'),
        padding: const EdgeInsets.only(top: FluttyTheme.spacingSm),
        child: Align(alignment: Alignment.centerLeft, child: widget.footer),
      );
    }
    final entry = widget.entries[index];
    return Padding(
      key: ValueKey(entry.id),
      padding: EdgeInsets.only(top: index == 0 ? 0 : FluttyTheme.spacingSm),
      child: _buildEntry(context, entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stickyIndex = _stickyPromptIndex;
    final stickyPrompt =
        stickyIndex != null &&
            stickyIndex >= 0 &&
            stickyIndex < widget.entries.length &&
            widget.entries[stickyIndex] is AcpUserPromptEntry
        ? widget.entries[stickyIndex] as AcpUserPromptEntry
        : null;
    final childCount = widget.entries.length + (widget.footer == null ? 0 : 1);
    return AcpImageActions(
      resolver: widget.imageResolver,
      onTap: widget.onTapImage,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) {
              _scheduleStickyUpdate();
              return false;
            },
            child: CustomScrollView(
              controller: _controller,
              shrinkWrap: widget.shrinkWrap,
              physics: widget.physics,
              semanticChildCount: widget.entries.length,
              slivers: [
                SliverPadding(
                  padding: widget.padding,
                  sliver: SliverList(
                    key: _sliverListKey,
                    delegate: SliverChildBuilderDelegate(
                      _buildListChild,
                      childCount: childCount,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (stickyPrompt != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _StickyUserPromptSummary(
                summary: acpUserPromptSummary(stickyPrompt),
                onTap: () => _scrollEntryIntoView(stickyIndex!),
              ),
            ),
        ],
      ),
    );
  }
}

class _StickyUserPromptSummary extends StatelessWidget {
  const _StickyUserPromptSummary({required this.summary, required this.onTap});

  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      header: true,
      button: true,
      onTap: onTap,
      label: 'Current user prompt: $summary. Show original message.',
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                key: const ValueKey('acp-sticky-user-prompt'),
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_outline_rounded,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          'you · $summary',
                          key: const ValueKey('acp-sticky-user-prompt-text'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface,
                            fontSize: 12.5,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubagentLaunchSurface extends StatelessWidget {
  const _SubagentLaunchSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: FluttyTheme.spacingXs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 14,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: FluttyTheme.spacingXs),
            Text(
              'Subagent',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      child,
    ],
  );
}

class _SubagentTranscriptSurface extends StatelessWidget {
  const _SubagentTranscriptSurface({
    required this.entry,
    required this.childBuilder,
  });

  final AcpSubagentTranscriptEntry entry;
  final Widget Function(AcpTimelineEntry entry) childBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Nested subagent transcript',
      child: Container(
        key: ValueKey('acp-subagent-transcript-${entry.launchToolCallId}'),
        margin: const EdgeInsets.only(left: FluttyTheme.spacingSm),
        padding: const EdgeInsets.only(left: FluttyTheme.spacingMd),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.primary, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.smart_toy_outlined, size: 14, color: scheme.primary),
                const SizedBox(width: FluttyTheme.spacingXs),
                Text(
                  'Subagent transcript',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            for (var index = 0; index < entry.entries.length; index++)
              Padding(
                padding: EdgeInsets.only(
                  top: index == 0
                      ? FluttyTheme.spacingSm
                      : FluttyTheme.spacingMd,
                ),
                child: childBuilder(entry.entries[index]),
              ),
          ],
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.entry,
    this.onTapLink,
    this.imageResolver,
    this.onTapImage,
    this.onCopyCode,
  });

  final AcpAssistantMessageEntry entry;
  final MarkdownTapLinkCallback? onTapLink;
  final AcpImageResolver? imageResolver;
  final ValueChanged<AcpImageContent>? onTapImage;
  final ValueChanged<String>? onCopyCode;

  @override
  Widget build(BuildContext context) {
    final streaming = entry.status == AcpStreamStatus.streaming;
    final markdown = AcpMarkdown(
      data: entry.markdown,
      onTapLink: onTapLink,
      imageResolver: imageResolver,
      onTapImage: onTapImage,
      onCopyCode: onCopyCode,
    );
    return Semantics(
      container: true,
      liveRegion: !streaming,
      label: streaming ? 'Agent response streaming' : 'Agent response complete',
      child: markdown,
    );
  }
}
