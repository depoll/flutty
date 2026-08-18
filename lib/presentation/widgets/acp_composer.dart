import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_updates.dart';
import '../controllers/acp_composer_controller.dart';
import 'acp_attachment_strip.dart';
import 'acp_chat_typography.dart';
import 'acp_slash_command_picker.dart';

/// Opens an attachment picker and returns the selected candidates.
typedef AcpAttachmentPick =
    Future<List<AcpAttachmentCandidate>> Function(BuildContext context);

/// The injectable attachment-picker entry points offered by the add menu.
///
/// Each entry is optional; only the provided sources appear in the menu. All
/// picker invocation goes through these callbacks so the composer can be
/// exercised in tests without any platform picker.
@immutable
class AcpComposerAttachmentActions {
  /// Creates attachment actions.
  const AcpComposerAttachmentActions({
    this.pickPhotos,
    this.pickFiles,
    this.pickRemoteFiles,
  });

  /// Picks photos or media from the device gallery/camera.
  final AcpAttachmentPick? pickPhotos;

  /// Picks arbitrary local files.
  final AcpAttachmentPick? pickFiles;

  /// Picks files from the remote host over SFTP.
  final AcpAttachmentPick? pickRemoteFiles;

  /// Whether at least one source is available.
  bool get hasAny =>
      pickPhotos != null || pickFiles != null || pickRemoteFiles != null;
}

/// A mobile-first, keyboard- and safe-area-aware ACP prompt composer.
///
/// The composer hosts a multiline text field, an ordered attachment strip, an
/// add-attachment menu (photos/media, local files, remote SFTP files), a
/// dynamic slash-command autocomplete, an inline error surface, and a primary
/// action that toggles between Send and Stop as the turn streams. It draws no
/// nested cards, uses ≥44px touch targets, and is entirely theme-driven.
class AcpComposer extends StatefulWidget {
  /// Creates a composer bound to [controller].
  const AcpComposer({
    required this.controller,
    super.key,
    this.attachmentActions = const AcpComposerAttachmentActions(),
    this.onOpenConfig,
    this.hintText = 'Message the agent',
    this.useBottomSafeArea = true,
  });

  /// The controller holding composer state and behaviour.
  final AcpComposerController controller;

  /// The attachment picker entry points to expose in the add menu.
  final AcpComposerAttachmentActions attachmentActions;

  /// Opens the session configuration surface; hidden when null.
  final VoidCallback? onOpenConfig;

  /// Placeholder text for the empty field.
  final String hintText;

  /// Whether the composer should reserve the device bottom safe area.
  final bool useBottomSafeArea;

  @override
  State<AcpComposer> createState() => _AcpComposerState();
}

class _AcpComposerState extends State<AcpComposer> {
  late final TextEditingController _text;
  late final FocusNode _focusNode;
  var _syncing = false;
  var _highlightedSlash = 0;

  AcpComposerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: _controller.text);
    _focusNode = FocusNode(onKeyEvent: _handleKey);
    _text.addListener(_onFieldChanged);
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(AcpComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _highlightedSlash = 0;
      // Re-sync the field to the newly bound controller's text/caret.
      _syncFieldFromController();
      _clampHighlight();
    }
  }

  @override
  void dispose() {
    _text.removeListener(_onFieldChanged);
    // Detach from whichever controller is currently bound.
    _controller.removeListener(_onControllerChanged);
    _text.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (_syncing) {
      return;
    }
    final selection = _text.selection;
    final caret = selection.isValid ? selection.baseOffset : _text.text.length;
    _controller.setText(_text.text, caret: caret);
  }

  void _onControllerChanged() {
    _syncFieldFromController();
    _clampHighlight();
    if (_controller.isSlashActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.isSlashActive && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _syncFieldFromController() {
    if (_controller.text != _text.text) {
      _syncing = true;
      _text.value = TextEditingValue(
        text: _controller.text,
        selection: TextSelection.collapsed(
          offset: _controller.caret.clamp(0, _controller.text.length),
        ),
      );
      _syncing = false;
    }
  }

  void _clampHighlight() {
    final count = _controller.slashCommands.length;
    if (count == 0) {
      _highlightedSlash = 0;
      return;
    }
    if (_highlightedSlash >= count) {
      _highlightedSlash = count - 1;
    }
    if (_highlightedSlash < 0) {
      _highlightedSlash = 0;
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final sendShortcut =
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter);
    if (sendShortcut && _controller.canSend) {
      unawaited(_controller.send());
      return KeyEventResult.handled;
    }
    if (!_controller.isSlashActive) {
      return KeyEventResult.ignored;
    }
    final commands = _controller.slashCommands;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        setState(
          () => _highlightedSlash = (_highlightedSlash + 1) % commands.length,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        setState(
          () => _highlightedSlash =
              (_highlightedSlash - 1 + commands.length) % commands.length,
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _selectSlash(commands[_highlightedSlash.clamp(0, commands.length - 1)]);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _controller.dismissSlash();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _selectSlash(AcpAvailableCommand command) {
    _controller.selectSlashCommand(command);
    setState(() => _highlightedSlash = 0);
    _focusNode.requestFocus();
  }

  Future<void> _openAddMenu() async {
    final actions = widget.attachmentActions;
    final source = await showModalBottomSheet<AcpAttachmentPick>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions.pickPhotos != null)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photo or video'),
                onTap: () => Navigator.of(context).pop(actions.pickPhotos),
              ),
            if (actions.pickFiles != null)
              ListTile(
                leading: const Icon(Icons.attach_file),
                title: const Text('Choose file'),
                onTap: () => Navigator.of(context).pop(actions.pickFiles),
              ),
            if (actions.pickRemoteFiles != null)
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Remote file (SFTP)'),
                onTap: () => Navigator.of(context).pop(actions.pickRemoteFiles),
              ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) {
      return;
    }
    final candidates = await source(context);
    if (!mounted) {
      return;
    }
    for (final candidate in candidates) {
      if (!_controller.addAttachment(candidate)) {
        break;
      }
    }
  }

  Future<void> _handlePrimaryAction() async {
    if (_controller.canSend) {
      await _controller.send();
    }
  }

  Future<void> _stopActiveTurn() => _controller.cancel();

  Future<void> _confirmRemoteUpload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upload to the server?'),
        content: const Text(
          'These attachments are too large or not supported inline. Upload '
          'them to the host\'s private directory and attach a link instead?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    _controller.enableRemoteUploadFallback();
    await _controller.send();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        _clampHighlight();
        return SafeArea(
          top: false,
          bottom: widget.useBottomSafeArea,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_controller.isSlashActive)
                  KeyedSubtree(
                    key: const ValueKey('acp-slash-picker'),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FluttyTheme.spacingSm,
                        FluttyTheme.spacingSm,
                        FluttyTheme.spacingSm,
                        0,
                      ),
                      child: AcpSlashCommandPicker(
                        commands: _controller.slashCommands,
                        highlightedIndex: _highlightedSlash,
                        onHighlightChanged: (index) =>
                            setState(() => _highlightedSlash = index),
                        onSelected: _selectSlash,
                      ),
                    ),
                  ),
                if (_controller.error != null)
                  KeyedSubtree(
                    key: const ValueKey('acp-error-banner'),
                    child: _ErrorBanner(
                      error: _controller.error!,
                      onDismiss: _controller.clearError,
                      onUpload:
                          _controller.error!.isUploadRecoverable &&
                              _controller.attachments.isNotEmpty
                          ? _confirmRemoteUpload
                          : null,
                    ),
                  ),
                if (_controller.attachments.isNotEmpty)
                  KeyedSubtree(
                    key: const ValueKey('acp-attachments'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FluttyTheme.spacingSm,
                      ),
                      child: AcpAttachmentStrip(
                        attachments: _controller.attachments,
                        enabled: _controller.isEditable,
                        onRemove: _controller.removeAttachment,
                        onRetry: _controller.retryAttachment,
                      ),
                    ),
                  ),
                KeyedSubtree(
                  key: const ValueKey('acp-input-row'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      FluttyTheme.spacingSm,
                      FluttyTheme.spacingSm,
                      FluttyTheme.spacingSm,
                      FluttyTheme.spacingSm,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _AddButton(
                          enabled:
                              _controller.isEditable &&
                              widget.attachmentActions.hasAny &&
                              _controller.canAddAttachment,
                          onPressed: _openAddMenu,
                        ),
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 160),
                            child: TextField(
                              controller: _text,
                              focusNode: _focusNode,
                              readOnly: !_controller.isEditable,
                              minLines: 1,
                              maxLines: null,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              textCapitalization: TextCapitalization.sentences,
                              style: AcpChatTypography.monoStyleOf(
                                context,
                              ).copyWith(color: scheme.onSurface, fontSize: 14),
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: widget.hintText,
                                hintStyle:
                                    AcpChatTypography.monoStyleOf(
                                      context,
                                    ).copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 14,
                                    ),
                              ),
                            ),
                          ),
                        ),
                        if (widget.onOpenConfig != null)
                          IconButton(
                            tooltip: 'Session settings',
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            icon: const Icon(Icons.tune),
                            onPressed: widget.onOpenConfig,
                          ),
                        if (_controller.canCancel)
                          _StopTurnButton(onPressed: _stopActiveTurn),
                        _PrimaryActionButton(
                          activity: _controller.activity,
                          canSend: _controller.canSend,
                          onPressed: _handlePrimaryAction,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Add attachment',
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    icon: const Icon(Icons.add),
    onPressed: enabled ? onPressed : null,
  );
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.activity,
    required this.canSend,
    required this.onPressed,
  });

  final AcpComposerActivity activity;
  final bool canSend;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = activity != AcpComposerActivity.idle;
    final queueing = busy;
    final label = queueing ? 'Queue message' : 'Send';
    final child = Icon(
      queueing ? Icons.playlist_add : Icons.arrow_upward,
      size: 22,
    );
    return Semantics(
      button: true,
      enabled: canSend,
      label: label,
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton.filled(
          tooltip: label,
          style: IconButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
          ),
          onPressed: canSend ? onPressed : null,
          icon: child,
        ),
      ),
    );
  }
}

class _StopTurnButton extends StatelessWidget {
  const _StopTurnButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Stop active turn',
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          tooltip: 'Stop active turn',
          style: IconButton.styleFrom(foregroundColor: scheme.error),
          onPressed: onPressed,
          icon: const Icon(Icons.stop, size: 22),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.error,
    required this.onDismiss,
    this.onUpload,
  });

  final AcpComposerError error;
  final VoidCallback onDismiss;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.fromLTRB(
          FluttyTheme.spacingMd,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingSm,
          FluttyTheme.spacingSm,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: FluttyTheme.spacingSm),
            Expanded(
              child: Text(
                error.message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            if (onUpload != null)
              TextButton(onPressed: onUpload, child: const Text('Upload')),
            IconButton(
              tooltip: 'Dismiss error',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Icon(Icons.close, size: 18, color: scheme.onErrorContainer),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
