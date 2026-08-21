import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

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

/// Opens the app's snippet picker and returns text to insert at the caret.
typedef AcpSnippetPick = Future<String?> Function(BuildContext context);

/// The injectable attachment-picker entry points offered by the add menu.
///
/// Each entry is optional; only the provided sources appear in the menu. All
/// picker invocation goes through these callbacks so the composer can be
/// exercised in tests without any platform picker.
@immutable
class AcpComposerAttachmentActions {
  /// Creates attachment actions.
  const AcpComposerAttachmentActions({
    this.pickSnippet,
    this.pickPhotos,
    this.pickFiles,
    this.pickRemoteFiles,
  });

  /// Picks a saved command snippet to insert into the prompt.
  final AcpSnippetPick? pickSnippet;

  /// Picks photos or media from the device gallery/camera.
  final AcpAttachmentPick? pickPhotos;

  /// Picks arbitrary local files.
  final AcpAttachmentPick? pickFiles;

  /// Picks files from the remote host over SFTP.
  final AcpAttachmentPick? pickRemoteFiles;

  /// Whether at least one source is available.
  bool get hasAny =>
      pickSnippet != null ||
      pickPhotos != null ||
      pickFiles != null ||
      pickRemoteFiles != null;
}

/// Controls the native composer focus from the persistent terminal shell.
class AcpComposerFocusController {
  _AcpComposerState? _state;

  /// Whether the composer currently owns text focus.
  bool get hasFocus => _state?._focusNode.hasFocus ?? false;

  /// Focuses the composer and opens the platform keyboard.
  void requestFocus() => _state?._focusNode.requestFocus();

  /// Dismisses the platform keyboard without discarding the draft.
  void dismissKeyboard() => _state?._focusNode.unfocus();

  /// Inserts text at the current composer selection.
  void insertText(String text) => _state?._insertExternalText(text);

  /// Applies one special toolbar key to the composer selection.
  void sendSpecialKey(TerminalKey key) => _state?._handleExternalKey(key);

  /// Opens the composer's photo/media picker.
  Future<void> pickPhotos() async =>
      _state?._handleAddAction(_AcpAddAction.photos);

  /// Opens the composer's local-file picker.
  Future<void> pickFiles() async =>
      _state?._handleAddAction(_AcpAddAction.files);

  // ignore: use_setters_to_change_properties
  void _attach(_AcpComposerState state) => _state = state;

  void _detach(_AcpComposerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
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
    this.focusController,
    this.onOpenConfig,
    this.hintText = 'Message the agent',
    this.useBottomSafeArea = true,
  });

  /// The controller holding composer state and behaviour.
  final AcpComposerController controller;

  /// The attachment picker entry points to expose in the add menu.
  final AcpComposerAttachmentActions attachmentActions;

  /// Optional owner used by the terminal shell's persistent keyboard button.
  final AcpComposerFocusController? focusController;

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
    widget.focusController?._attach(this);
  }

  @override
  void didUpdateWidget(AcpComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusController, widget.focusController)) {
      oldWidget.focusController?._detach(this);
      widget.focusController?._attach(this);
    }
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
    widget.focusController?._detach(this);
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

  void _insertExternalText(String text) {
    if (!_controller.isEditable || text.isEmpty) {
      return;
    }
    final selection = _text.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, _text.text.length)
        : _controller.caret;
    final end = selection.isValid
        ? selection.end.clamp(start, _text.text.length)
        : start;
    final next = _text.text.replaceRange(start, end, text);
    _controller.setText(next, caret: start + text.length);
    _focusNode.requestFocus();
  }

  void _handleExternalKey(TerminalKey key) {
    final caret = _controller.caret.clamp(0, _controller.text.length);
    switch (key) {
      case TerminalKey.escape:
        _controller.dismissSlash();
        _focusNode.unfocus();
      case TerminalKey.tab:
        _insertExternalText('\t');
      case TerminalKey.enter:
        _insertExternalText('\n');
      case TerminalKey.arrowLeft:
        _controller.setText(
          _controller.text,
          caret: (caret - 1).clamp(0, _controller.text.length),
        );
      case TerminalKey.arrowRight:
        _controller.setText(
          _controller.text,
          caret: (caret + 1).clamp(0, _controller.text.length),
        );
      case TerminalKey.arrowUp || TerminalKey.pageUp || TerminalKey.home:
        _controller.setText(_controller.text, caret: 0);
      case TerminalKey.arrowDown || TerminalKey.pageDown || TerminalKey.end:
        _controller.setText(_controller.text, caret: _controller.text.length);
      default:
        return;
    }
    _focusNode.requestFocus();
  }

  Future<void> _handleAddAction(_AcpAddAction action) async {
    final actions = widget.attachmentActions;
    switch (action) {
      case _AcpAddAction.snippet:
        final snippet = await actions.pickSnippet?.call(context);
        if (!mounted || snippet == null || snippet.isEmpty) {
          return;
        }
        final caret = _controller.caret.clamp(0, _controller.text.length);
        final next = _controller.text.replaceRange(caret, caret, snippet);
        _controller.setText(next, caret: caret + snippet.length);
        _focusNode.requestFocus();
      case _AcpAddAction.photos:
        await _addAttachments(actions.pickPhotos);
      case _AcpAddAction.files:
        await _addAttachments(actions.pickFiles);
      case _AcpAddAction.remoteFiles:
        await _addAttachments(actions.pickRemoteFiles);
    }
  }

  Future<void> _addAttachments(AcpAttachmentPick? source) async {
    if (source == null || !_controller.canAddAttachment) {
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
    _focusNode.requestFocus();
  }

  Future<void> _handlePrimaryAction() async {
    if (!_controller.canSend) return;
    await _controller.send();
    if (!mounted) return;
    final error = _controller.error;
    if (error != null &&
        error.isUploadRecoverable &&
        _controller.attachments.isNotEmpty) {
      await _confirmRemoteUpload();
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
                          actions: widget.attachmentActions,
                          enabled:
                              _controller.isEditable &&
                              widget.attachmentActions.hasAny,
                          attachmentsEnabled: _controller.canAddAttachment,
                          onSelected: _handleAddAction,
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
                              textAlignVertical: TextAlignVertical.center,
                              style: AcpChatTypography.monoStyleOf(
                                context,
                              ).copyWith(color: scheme.onSurface, fontSize: 14),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: false,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: FluttyTheme.spacingMd,
                                  vertical: 13,
                                ),
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
                        const SizedBox(width: FluttyTheme.spacingSm),
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

enum _AcpAddAction { snippet, photos, files, remoteFiles }

class _AddButton extends StatelessWidget {
  const _AddButton({
    required this.actions,
    required this.enabled,
    required this.attachmentsEnabled,
    required this.onSelected,
  });

  final AcpComposerAttachmentActions actions;
  final bool enabled;
  final bool attachmentsEnabled;
  final ValueChanged<_AcpAddAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final itemCount = [
      actions.pickSnippet,
      actions.pickPhotos,
      actions.pickFiles,
      actions.pickRemoteFiles,
    ].where((action) => action != null).length;
    return PopupMenuButton<_AcpAddAction>(
      enabled: enabled,
      tooltip: 'Add to prompt',
      position: PopupMenuPosition.over,
      offset: Offset(0, -(itemCount * 48.0 + 12)),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 210),
      icon: const Icon(Icons.add),
      itemBuilder: (context) => [
        if (actions.pickSnippet != null)
          const PopupMenuItem(
            value: _AcpAddAction.snippet,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.code_rounded),
              title: Text('Snippet'),
            ),
          ),
        if (actions.pickPhotos != null)
          PopupMenuItem(
            value: _AcpAddAction.photos,
            enabled: attachmentsEnabled,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_library_outlined),
              title: Text('Photo or video'),
            ),
          ),
        if (actions.pickFiles != null)
          PopupMenuItem(
            value: _AcpAddAction.files,
            enabled: attachmentsEnabled,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.attach_file),
              title: Text('Choose file'),
            ),
          ),
        if (actions.pickRemoteFiles != null)
          PopupMenuItem(
            value: _AcpAddAction.remoteFiles,
            enabled: attachmentsEnabled,
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.cloud_outlined),
              title: Text('Remote file (SFTP)'),
            ),
          ),
      ],
      onSelected: onSelected,
    );
  }
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
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          style: IconButton.styleFrom(
            minimumSize: const Size.square(44),
            maximumSize: const Size.square(44),
            padding: EdgeInsets.zero,
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
