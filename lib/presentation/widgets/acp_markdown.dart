import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';
import 'acp_code_block.dart';
import 'acp_inline_image.dart';

/// URL schemes that [AcpMarkdown] will open by default.
const _allowedLinkSchemes = {'http', 'https', 'mailto', 'tel'};

/// Safely opens [href] if it uses an allowed scheme.
///
/// Unsupported or malformed links are ignored rather than launched, so tapping
/// a link can never trigger an arbitrary intent.
Future<void> launchAcpLink(String? href) async {
  if (href == null || href.isEmpty) {
    return;
  }
  final uri = Uri.tryParse(href);
  if (uri == null || !_allowedLinkSchemes.contains(uri.scheme.toLowerCase())) {
    return;
  }
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// Renders assistant Markdown with selectable text, safe links, tables, lists,
/// blockquotes, inline images, and syntax-highlighted code blocks that expose a
/// copy action.
///
/// All colors are derived from the resolved [Theme] so the content follows the
/// active (including terminal-driven) palette. Code blocks reuse the shared
/// highlight utilities via [AcpCodeBlock]. Links are opened through
/// [launchAcpLink] unless a custom [onTapLink] is supplied.
class AcpMarkdown extends StatelessWidget {
  /// Creates a Markdown renderer.
  const AcpMarkdown({
    required this.data,
    super.key,
    this.selectable = true,
    this.onTapLink,
    this.imageResolver,
    this.onTapImage,
    this.onCopyCode,
    this.syntaxTheme,
  });

  /// The Markdown source to render.
  final String data;

  /// Whether text is selectable.
  final bool selectable;

  /// Custom link tap handler; defaults to [launchAcpLink].
  final MarkdownTapLinkCallback? onTapLink;

  /// Resolver for non-inline images embedded in the Markdown.
  final AcpImageResolver? imageResolver;

  /// Called when an inline image is tapped.
  final ValueChanged<AcpImageContent>? onTapImage;

  /// Called after a code block's contents are copied.
  final ValueChanged<String>? onCopyCode;

  /// Optional highlight.js theme map for code blocks.
  final Map<String, TextStyle>? syntaxTheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = MarkdownStyleSheet.fromTheme(theme);
    final styleSheet = base.copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      a: TextStyle(
        color: scheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: scheme.primary,
      ),
      code: FluttyTheme.monoStyle.copyWith(
        color: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      blockquote: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      blockquoteDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
      ),
      blockquotePadding: const EdgeInsets.all(FluttyTheme.spacingSm),
      tableBorder: TableBorder.all(color: scheme.outline),
      tableHead: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      tableBody: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
    );

    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      softLineBreak: true,
      onTapLink: onTapLink ?? _defaultOnTapLink,
      imageBuilder: _buildImage,
      builders: {
        'pre': _AcpCodeBlockBuilder(
          syntaxTheme: syntaxTheme,
          onCopy: onCopyCode,
        ),
      },
    );
  }

  void _defaultOnTapLink(String text, String? href, String title) {
    unawaited(launchAcpLink(href));
  }

  Widget _buildImage(Uri uri, String? title, String? alt) => Padding(
    padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
    child: AcpInlineImage(
      image: AcpImageContent(uri: uri.toString(), label: alt ?? title),
      resolver: imageResolver,
      onTap: onTapImage,
    ),
  );
}

class _AcpCodeBlockBuilder extends MarkdownElementBuilder {
  _AcpCodeBlockBuilder({this.syntaxTheme, this.onCopy});

  final Map<String, TextStyle>? syntaxTheme;
  final ValueChanged<String>? onCopy;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String? language;
    final children = element.children;
    if (children != null && children.isNotEmpty) {
      final first = children.first;
      if (first is md.Element) {
        final className = first.attributes['class'];
        if (className != null && className.startsWith('language-')) {
          language = className.substring('language-'.length);
        }
      }
    }
    var code = element.textContent;
    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
      child: AcpCodeBlock(
        code: code,
        language: language,
        syntaxTheme: syntaxTheme,
        onCopy: onCopy,
      ),
    );
  }
}
