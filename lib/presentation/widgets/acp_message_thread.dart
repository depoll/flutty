import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_inline_image.dart';
import 'acp_markdown.dart';
import 'acp_markdown_virtualization.dart';
import 'acp_plan.dart';
import 'acp_status_entry.dart';
import 'acp_thought.dart';
import 'acp_tool_call.dart';
import 'acp_usage.dart';
import 'acp_user_prompt.dart';

final Expando<String> _userPromptSummaryCache = Expando<String>(
  'ACP user prompt summary',
);

/// Builds the compact context shown when a user prompt is above the viewport.
String acpUserPromptSummary(AcpUserPromptEntry entry) {
  final cached = _userPromptSummaryCache[entry];
  if (cached != null) return cached;
  final summary = _buildAcpUserPromptSummary(entry);
  _userPromptSummaryCache[entry] = summary;
  return summary;
}

String _buildAcpUserPromptSummary(AcpUserPromptEntry entry) {
  const maxLength = 240;
  final text = StringBuffer();
  var pendingSpace = false;
  var truncated = false;
  outer:
  for (final part in entry.parts.whereType<AcpTextPart>()) {
    for (final rune in part.text.runes) {
      if (_isPromptSummaryWhitespace(rune)) {
        pendingSpace = text.isNotEmpty;
        continue;
      }
      if (pendingSpace && text.length < maxLength) text.write(' ');
      pendingSpace = false;
      if (text.length >= maxLength) {
        truncated = true;
        break outer;
      }
      text.writeCharCode(rune);
    }
    pendingSpace = text.isNotEmpty;
  }
  if (text.isNotEmpty) {
    final value = text.toString();
    return truncated && value.length >= maxLength
        ? '${value.substring(0, maxLength - 1)}…'
        : value;
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

bool _isPromptSummaryWhitespace(int rune) =>
    rune <= 0x20 ||
    const <int>{
      0x0085,
      0x00A0,
      0x1680,
      0x2000,
      0x2001,
      0x2002,
      0x2003,
      0x2004,
      0x2005,
      0x2006,
      0x2007,
      0x2008,
      0x2009,
      0x200A,
      0x2028,
      0x2029,
      0x202F,
      0x205F,
      0x3000,
    }.contains(rune);

final Expando<List<String>> _assistantMarkdownChunks = Expando<List<String>>(
  'ACP virtual Markdown segments',
);
final Expando<List<List<AcpPromptPart>>> _userPromptSegments =
    Expando<List<List<AcpPromptPart>>>('ACP virtual user prompt segments');

final class _AcpThreadChild {
  const _AcpThreadChild({
    required this.entry,
    required this.entryIndex,
    this.markdown,
    this.markdownPartIndex,
    this.markdownPartCount,
    this.userParts,
    this.userPartIndex,
    this.userPartCount,
  });

  final AcpTimelineEntry entry;
  final int entryIndex;
  final String? markdown;
  final int? markdownPartIndex;
  final int? markdownPartCount;
  final List<AcpPromptPart>? userParts;
  final int? userPartIndex;
  final int? userPartCount;

  bool get isEntryContinuation =>
      (markdownPartIndex ?? 0) > 0 || (userPartIndex ?? 0) > 0;

  String get keyValue {
    final markdownPart = markdownPartIndex;
    if (markdownPart != null && markdownPart > 0) {
      return '${entry.id}-markdown-part-$markdownPart';
    }
    final userPart = userPartIndex;
    if (userPart != null && userPart > 0) {
      return '${entry.id}-user-part-$userPart';
    }
    return entry.id;
  }
}

List<_AcpThreadChild> _buildThreadChildren(List<AcpTimelineEntry> entries) {
  final children = <_AcpThreadChild>[];
  for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    final entry = entries[entryIndex];
    if (entry case AcpUserPromptEntry(:final parts)
        when parts.any(
          (part) =>
              part is AcpTextPart &&
              part.text.length > kAcpTextVirtualChunkChars,
        )) {
      final segments = _userPromptSegments[entry] ??= <List<AcpPromptPart>>[
        for (final part in parts)
          if (part case AcpTextPart(
            :final text,
          ) when text.length > kAcpTextVirtualChunkChars)
            for (final chunk in splitAcpTextForVirtualization(text))
              <AcpPromptPart>[AcpTextPart(chunk)]
          else
            <AcpPromptPart>[part],
      ];
      for (var partIndex = 0; partIndex < segments.length; partIndex++) {
        children.add(
          _AcpThreadChild(
            entry: entry,
            entryIndex: entryIndex,
            userParts: segments[partIndex],
            userPartIndex: partIndex,
            userPartCount: segments.length,
          ),
        );
      }
      continue;
    }
    if (entry case AcpAssistantMessageEntry(
      :final markdown,
    ) when markdown.length > kAcpMarkdownVirtualChunkChars) {
      final chunks = _assistantMarkdownChunks[entry] ??=
          splitAcpMarkdownForVirtualization(markdown);
      for (var partIndex = 0; partIndex < chunks.length; partIndex++) {
        children.add(
          _AcpThreadChild(
            entry: entry,
            entryIndex: entryIndex,
            markdown: chunks[partIndex],
            markdownPartIndex: partIndex,
            markdownPartCount: chunks.length,
          ),
        );
      }
      continue;
    }
    children.add(_AcpThreadChild(entry: entry, entryIndex: entryIndex));
  }
  return children;
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
  List<AcpTimelineEntry>? _threadEntries;
  List<_AcpThreadChild> _threadChildren = const [];
  Map<int, int> _firstChildIndexByEntry = const {};
  Map<String, int> _childIndexByKey = const {};
  int? _stickyPromptIndex;
  int? _firstVisibleEntryIndex;
  Timer? _promptNavigationHideTimer;
  bool _promptNavigationVisible = false;
  bool _stickyUpdateScheduled = false;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _syncThreadChildren();
    _controller.addListener(_scheduleStickyUpdate);
    _scheduleStickyUpdate();
  }

  @override
  void didUpdateWidget(covariant AcpMessageThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncThreadChildren();
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
    _promptNavigationHideTimer?.cancel();
    _controller.removeListener(_scheduleStickyUpdate);
    _ownedController?.dispose();
    super.dispose();
  }

  void _syncThreadChildren() {
    if (identical(_threadEntries, widget.entries)) return;
    _threadEntries = widget.entries;
    _threadChildren = _buildThreadChildren(widget.entries);
    final firstChildIndexByEntry = <int, int>{};
    for (var index = 0; index < _threadChildren.length; index++) {
      firstChildIndexByEntry.putIfAbsent(
        _threadChildren[index].entryIndex,
        () => index,
      );
    }
    _firstChildIndexByEntry = firstChildIndexByEntry;
    _childIndexByKey = <String, int>{
      for (var index = 0; index < _threadChildren.length; index++)
        _threadChildren[index].keyValue: index,
    };
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
        _threadChildren.isEmpty) {
      _setViewportContext(stickyPromptIndex: null, firstEntryIndex: null);
      return;
    }

    final viewportTop = renderObject.constraints.scrollOffset;
    var child = renderObject.firstChild;
    int? firstVisibleChildIndex;
    while (child != null) {
      final childTop = renderObject.childScrollOffset(child) ?? 0;
      final childBottom = childTop + child.size.height;
      if (childBottom > viewportTop + 0.5) {
        firstVisibleChildIndex = renderObject.indexOf(child);
        break;
      }
      child = renderObject.childAfter(child);
    }
    firstVisibleChildIndex ??= renderObject.indexOf(renderObject.lastChild!);
    final threadChildIndex = firstVisibleChildIndex.clamp(
      0,
      _threadChildren.length - 1,
    );
    final entryIndex = _threadChildren[threadChildIndex].entryIndex;

    int? promptIndex;
    for (var index = entryIndex; index >= 0; index--) {
      if (widget.entries[index] is AcpUserPromptEntry) {
        promptIndex = index;
        break;
      }
    }
    final promptIsVisible =
        firstVisibleChildIndex < _threadChildren.length &&
        promptIndex == entryIndex &&
        _threadChildren[threadChildIndex].entry is AcpUserPromptEntry;
    _setViewportContext(
      stickyPromptIndex: promptIsVisible ? null : promptIndex,
      firstEntryIndex: entryIndex,
    );
  }

  void _setViewportContext({
    required int? stickyPromptIndex,
    required int? firstEntryIndex,
  }) {
    if (_stickyPromptIndex == stickyPromptIndex &&
        _firstVisibleEntryIndex == firstEntryIndex) {
      return;
    }
    setState(() {
      _stickyPromptIndex = stickyPromptIndex;
      _firstVisibleEntryIndex = firstEntryIndex;
    });
  }

  int? _previousUserPromptIndex() {
    final firstVisible = _firstVisibleEntryIndex;
    if (firstVisible == null) return null;
    final start = _stickyPromptIndex ?? firstVisible - 1;
    for (var index = start; index >= 0; index--) {
      if (widget.entries[index] is AcpUserPromptEntry) return index;
    }
    return null;
  }

  int? _nextUserPromptIndex() {
    final firstVisible = _firstVisibleEntryIndex;
    if (firstVisible == null) return null;
    final start = (_stickyPromptIndex ?? firstVisible) + 1;
    for (var index = start; index < widget.entries.length; index++) {
      if (widget.entries[index] is AcpUserPromptEntry) return index;
    }
    return null;
  }

  void _showPromptNavigation() {
    if (widget.entries.whereType<AcpUserPromptEntry>().length < 2) return;
    _promptNavigationHideTimer?.cancel();
    if (!_promptNavigationVisible && mounted) {
      setState(() => _promptNavigationVisible = true);
    }
    _promptNavigationHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _promptNavigationVisible) {
        setState(() => _promptNavigationVisible = false);
      }
    });
  }

  bool _handleThreadScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final userInitiated =
        notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is ScrollUpdateNotification &&
            notification.dragDetails != null ||
        notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
    if (userInitiated) _showPromptNavigation();
    return false;
  }

  void _navigateToPrompt(int? entryIndex) {
    if (entryIndex == null) return;
    _showPromptNavigation();
    unawaited(_scrollEntryIntoView(entryIndex));
  }

  Future<void> _scrollEntryIntoView(int entryIndex) async {
    if (!_controller.hasClients) return;
    final targetChildIndex = _firstChildIndexByEntry[entryIndex];
    if (targetChildIndex == null) return;
    widget.onStickyPromptTap?.call();
    // A sticky prompt can be many screens above the viewport and therefore no
    // longer have a built element. Seek until SliverList materializes it, then
    // animate to its exact scroll offset. RenderObject.showOnScreen is not
    // reliable here because a cached off-screen child may be considered
    // revealed without moving the outer CustomScrollView to its beginning.
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    for (var attempt = 0; attempt < 12; attempt++) {
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
        if (sliver.indexOf(child) == targetChildIndex) {
          final childOffset = sliver.childScrollOffset(child);
          if (childOffset == null) return;
          final destination = (sliverOrigin + childOffset).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          if (reduceMotion) {
            _controller.jumpTo(destination);
          } else {
            await _controller.animateTo(
              destination,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            );
          }
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
        position.viewportDimension * 24,
      );
      final estimate = targetChildIndex < firstIndex
          ? sliverOrigin +
                firstOffset -
                (firstIndex - targetChildIndex) * averageExtent
          : sliverOrigin +
                lastOffset +
                last.size.height +
                (targetChildIndex - lastIndex - 1) * averageExtent;
      final destination = estimate.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((destination - position.pixels).abs() < 1) return;
      if (reduceMotion) {
        _controller.jumpTo(destination);
      } else {
        final screens =
            ((destination - position.pixels).abs() / position.viewportDimension)
                .clamp(0, 6);
        await _controller.animateTo(
          destination,
          duration: Duration(milliseconds: 140 + (screens * 20).round()),
          curve: Curves.easeInOutCubic,
        );
      }
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
    if (index == _threadChildren.length) {
      return Padding(
        key: const ValueKey('acp-message-thread-footer'),
        padding: const EdgeInsets.only(top: FluttyTheme.spacingSm),
        child: Align(alignment: Alignment.centerLeft, child: widget.footer),
      );
    }
    final threadChild = _threadChildren[index];
    final entry = threadChild.entry;
    final Widget content;
    if (entry is AcpUserPromptEntry && threadChild.userParts != null) {
      content = AcpUserPromptView(
        entry: entry,
        parts: threadChild.userParts,
        segmentIndex: threadChild.userPartIndex,
        segmentCount: threadChild.userPartCount,
        imageResolver: widget.imageResolver,
        onTapImage: widget.onTapImage,
        onOpenResource: widget.onOpenResource,
        onCopyResource: widget.onCopyResource,
      );
    } else if (entry is AcpAssistantMessageEntry &&
        threadChild.markdown != null) {
      content = _AssistantMessage(
        entry: entry,
        markdown: threadChild.markdown,
        partIndex: threadChild.markdownPartIndex,
        partCount: threadChild.markdownPartCount,
        onTapLink: widget.onTapLink,
        imageResolver: widget.imageResolver,
        onTapImage: widget.onTapImage,
        onCopyCode: widget.onCopyCode,
      );
    } else {
      content = _buildEntry(context, entry);
    }
    return Padding(
      key: ValueKey(threadChild.keyValue),
      padding: EdgeInsets.only(
        top: index == 0 || threadChild.isEntryContinuation
            ? 0
            : FluttyTheme.spacingSm,
      ),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncThreadChildren();
    final stickyIndex = _stickyPromptIndex;
    final stickyPrompt =
        stickyIndex != null &&
            stickyIndex >= 0 &&
            stickyIndex < widget.entries.length &&
            widget.entries[stickyIndex] is AcpUserPromptEntry
        ? widget.entries[stickyIndex] as AcpUserPromptEntry
        : null;
    final previousPromptIndex = _previousUserPromptIndex();
    final nextPromptIndex = _nextUserPromptIndex();
    final userPromptCount = widget.entries
        .whereType<AcpUserPromptEntry>()
        .length;
    final childCount = _threadChildren.length + (widget.footer == null ? 0 : 1);
    return AcpImageActions(
      resolver: widget.imageResolver,
      onTap: widget.onTapImage,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _handleThreadScroll,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _scheduleStickyUpdate();
                return false;
              },
              child: CustomScrollView(
                controller: _controller,
                shrinkWrap: widget.shrinkWrap,
                physics: widget.physics,
                semanticChildCount: _threadChildren.length,
                slivers: [
                  SliverPadding(
                    padding: widget.padding,
                    sliver: SliverList(
                      key: _sliverListKey,
                      delegate: SliverChildBuilderDelegate(
                        _buildListChild,
                        childCount: childCount,
                        findChildIndexCallback: (key) => key is ValueKey<String>
                            ? _childIndexByKey[key.value]
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (stickyPrompt != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _StickyUserPromptSummary(
                summary: acpUserPromptSummary(stickyPrompt),
                onTap: () => _navigateToPrompt(stickyIndex),
              ),
            ),
          if (userPromptCount > 1)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: FluttyTheme.spacingSm),
                  child: _UserPromptNavigation(
                    visible: _promptNavigationVisible,
                    previousEnabled: previousPromptIndex != null,
                    nextEnabled: nextPromptIndex != null,
                    onPrevious: () => _navigateToPrompt(previousPromptIndex),
                    onNext: () => _navigateToPrompt(nextPromptIndex),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UserPromptNavigation extends StatelessWidget {
  const _UserPromptNavigation({
    required this.visible,
    required this.previousEnabled,
    required this.nextEnabled,
    required this.onPrevious,
    required this.onNext,
  });

  final bool visible;
  final bool previousEnabled;
  final bool nextEnabled;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return AnimatedOpacity(
      key: const ValueKey('acp-user-prompt-navigation'),
      opacity: visible ? 1 : 0,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeSemantics(
          excluding: !visible,
          child: Material(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(FluttyTheme.radiusLg),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('acp-previous-user-message'),
                  tooltip: 'Previous user message',
                  onPressed: previousEnabled ? onPrevious : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                ),
                SizedBox(
                  width: 28,
                  child: Divider(height: 1, color: scheme.outlineVariant),
                ),
                IconButton(
                  key: const ValueKey('acp-next-user-message'),
                  tooltip: 'Next user message',
                  onPressed: nextEnabled ? onNext : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
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
    this.markdown,
    this.partIndex,
    this.partCount,
    this.onTapLink,
    this.imageResolver,
    this.onTapImage,
    this.onCopyCode,
  });

  final AcpAssistantMessageEntry entry;
  final String? markdown;
  final int? partIndex;
  final int? partCount;
  final MarkdownTapLinkCallback? onTapLink;
  final AcpImageResolver? imageResolver;
  final ValueChanged<AcpImageContent>? onTapImage;
  final ValueChanged<String>? onCopyCode;

  @override
  Widget build(BuildContext context) {
    final streaming = entry.status == AcpStreamStatus.streaming;
    final markdownView = AcpMarkdown(
      data: markdown ?? entry.markdown,
      onTapLink: onTapLink,
      imageResolver: imageResolver,
      onTapImage: onTapImage,
      onCopyCode: onCopyCode,
    );
    final part = partIndex;
    final count = partCount;
    final partDescription = part != null && count != null
        ? ', part ${part + 1} of $count'
        : '';
    final isFinalPart = part == null || count == null || part == count - 1;
    return Semantics(
      container: true,
      liveRegion: !streaming && isFinalPart,
      label: streaming
          ? 'Agent response streaming$partDescription'
          : 'Agent response complete$partDescription',
      child: markdownView,
    );
  }
}
