import 'package:flutter/material.dart';
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

/// Renders an ordered list of [AcpTimelineEntry]s as a conversation thread.
///
/// The renderer is suitable for both live streaming and replay: it is a pure
/// function of [entries], and keys each row by its entry [AcpTimelineEntry.id]
/// so per-entry widget state (expanded thoughts, tool-call details) and scroll
/// position stay stable as the conversation grows.
///
/// It builds lazily with a [ListView.builder] to stay performant for long
/// transcripts. Callbacks let the host wire up links, images, resources, and
/// locations without the widgets performing any I/O themselves.
class AcpMessageThread extends StatelessWidget {
  /// Creates a message thread.
  const AcpMessageThread({
    required this.entries,
    super.key,
    this.controller,
    this.padding = const EdgeInsets.all(FluttyTheme.spacingMd),
    this.shrinkWrap = false,
    this.physics,
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

  Widget _buildEntry(BuildContext context, AcpTimelineEntry entry) {
    switch (entry) {
      case AcpUserPromptEntry():
        return AcpUserPromptView(
          entry: entry,
          imageResolver: imageResolver,
          onTapImage: onTapImage,
          onOpenResource: onOpenResource,
          onCopyResource: onCopyResource,
        );
      case AcpAssistantMessageEntry():
        return _AssistantMessage(
          entry: entry,
          onTapLink: onTapLink,
          imageResolver: imageResolver,
          onTapImage: onTapImage,
          onCopyCode: onCopyCode,
        );
      case AcpThoughtEntry():
        return AcpThoughtView(
          entry: entry,
          initiallyExpanded: thoughtsInitiallyExpanded,
          onTapLink: onTapLink,
          imageResolver: imageResolver,
        );
      case AcpPlanEntry():
        return AcpPlanView(plan: entry.plan);
      case AcpToolCallEntry():
        return AcpToolCallView(
          toolCall: entry.toolCall,
          onOpenLocation: onOpenLocation,
        );
      case AcpUsageEntry():
        return AcpUsageView(usage: entry.usage);
      case AcpStatusEntry():
        return AcpStatusEntryView(entry: entry);
    }
  }

  @override
  Widget build(BuildContext context) => AcpImageActions(
    resolver: imageResolver,
    onTap: onTapImage,
    child: ListView.builder(
      controller: controller,
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: physics,
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Padding(
          key: ValueKey(entry.id),
          padding: EdgeInsets.only(top: index == 0 ? 0 : FluttyTheme.spacingMd),
          child: _buildEntry(context, entry),
        );
      },
    ),
  );
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
