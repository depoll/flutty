/// Full-screen ACP agent chat.
///
/// A single conversation surface on mobile (with an app-bar session switcher)
/// and a persistent session rail plus conversation pane on wide layouts. It
/// watches the multi-host [AcpSessionManager], reconnects recent/detached
/// sessions on open, renders the live/replay timeline with auto-scroll that
/// respects the user's scroll position, and hosts the composer, permission
/// surface, and configuration controls.
///
/// The screen is a pure function of its opaque route identifiers; it never
/// persists or logs transcript content.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_attachment.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/acp_timeline.dart' as domain;
import '../../domain/services/acp_attachment_service.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../controllers/acp_composer_controller.dart';
import '../controllers/acp_sftp_client_cache.dart';
import '../models/acp_attachment_picker_adapters.dart';
import '../models/acp_timeline.dart' as ui;
import '../models/acp_timeline_mapper.dart';
import '../widgets/acp_chat_typography.dart';
import '../widgets/acp_composer.dart';
import '../widgets/acp_concurrency_choice.dart';
import '../widgets/acp_config_option_controls.dart';
import '../widgets/acp_connection_support.dart';
import '../widgets/acp_inline_image.dart';
import '../widgets/acp_message_thread.dart';
import '../widgets/acp_new_session_sheet.dart';
import '../widgets/acp_permission_surface.dart';
import '../widgets/acp_session_presentation.dart';
import '../widgets/acp_session_switcher.dart';
import '../widgets/brand_error_state.dart';
import '../widgets/cursor_block.dart';
import '../widgets/terminal_overlay_focus.dart';
import '../widgets/terminal_pinch_zoom_gesture_handler.dart';
import '../widgets/terminal_text_style.dart';
import 'sftp_screen.dart';

/// Builds the attachment picker actions for a chat session. Overridable in
/// tests so the composer can be exercised without platform pickers.
typedef AcpChatAttachmentActionsBuilder =
    AcpComposerAttachmentActions Function(int hostId, int? connectionId);

/// Wide-layout breakpoint for the session rail.
const double kAgentChatWideBreakpoint = 840;

/// Clamps native agent text to the same supported range as terminal text.
double clampAgentChatFontSize(num size) {
  if (!size.isFinite) {
    return 8;
  }
  return size.clamp(8, 32).toDouble();
}

/// Full-screen agent chat for one ACP session.
class AgentChatScreen extends ConsumerStatefulWidget {
  /// Creates an agent chat screen from its opaque session identifiers.
  const AgentChatScreen({
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
    this.attachmentActionsBuilder,
    this.embedded = false,
    this.preferredFontSize,
    this.preferredFontFamily,
    this.onFontSizeCommitted,
    this.onExitEmbedded,
    this.onSessionChanged,
    super.key,
  });

  /// Saved host identifier.
  final int hostId;

  /// ACP provider identifier.
  final String providerId;

  /// Opaque remote bridge identifier.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Optional attachment picker override for tests.
  final AcpChatAttachmentActionsBuilder? attachmentActionsBuilder;

  /// Whether the conversation replaces a terminal viewport inside its shell.
  final bool embedded;

  /// Terminal/session font size used by the embedded conversation.
  final double? preferredFontSize;

  /// Terminal/host font family used by the embedded conversation.
  final String? preferredFontFamily;

  /// Persists a font size committed by a completed pinch gesture.
  final ValueChanged<double>? onFontSizeCommitted;

  /// Returns an embedded conversation to the terminal viewport.
  final VoidCallback? onExitEmbedded;

  /// Replaces the active embedded conversation after a fork.
  final ValueChanged<AcpSessionKey>? onSessionChanged;

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  late AcpSessionKey _key;
  late final AcpComposerController _composer;
  final ScrollController _scroll = ScrollController();

  var _autoScroll = true;
  var _showJumpToLatest = false;
  var _connecting = true;
  AcpSessionError? _connectError;
  final AcpSftpClientCache _sftpCache = AcpSftpClientCache();

  @override
  void initState() {
    super.initState();
    _key = AcpSessionKey.of(
      hostId: widget.hostId,
      providerId: widget.providerId,
      bridgeId: widget.bridgeId,
      acpSessionId: widget.acpSessionId,
    );
    final manager = ref.read(acpSessionManagerProvider);
    _composer = AcpComposerController(
      manager: manager,
      sessionKey: _key,
      uploaderBuilder: _buildUploader,
      initialSession: manager.state.byKeyValue(_key.value),
    );
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureConnected());
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _composer.dispose();
    super.dispose();
  }

  AcpAttachmentUploader? _buildUploader() {
    final connectionId = _currentConnectionId();
    final client = _sftpCache.clientForConnection(connectionId);
    // Never upload through a client owned by a stale SSH connection: if the
    // host reconnected under a new connectionId, the cache returns null here
    // and we kick off a reopen so the next attempt uses the live connection.
    if (client == null) {
      _sftpCache.invalidateIfStale(connectionId);
      unawaited(_ensureSftpClient());
      return null;
    }
    return SftpAcpAttachmentUploader(sftp: client);
  }

  int? _currentConnectionId() => ref
      .read(sshServiceProvider)
      .getSessionsForHost(widget.hostId)
      .firstOrNull
      ?.connectionId;

  Future<void> _ensureConnected() async {
    final manager = ref.read(acpSessionManagerProvider);
    final existing = manager.state.byKeyValue(_key.value);
    if (existing != null && existing.isLive) {
      unawaited(manager.selectSession(_key));
      unawaited(_ensureSftpClient());
      return;
    }
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final recents = await manager.loadRecentSessions();
      final match = recents.where((r) => r.key.value == _key.value).firstOrNull;
      final result = await _reconnect(cwd: match?.cwd ?? '~');
      if (!mounted) {
        return;
      }
      switch (result) {
        case AcpSessionLaunchStarted(:final key):
          final keyChanged = key != _key;
          setState(() {
            _key = key;
            _connecting = false;
          });
          if (keyChanged) {
            _composer.rebindSession(
              key,
              session: manager.state.byKeyValue(key.value),
            );
            if (widget.embedded) {
              widget.onSessionChanged?.call(key);
            }
          }
          unawaited(manager.selectSession(key));
          unawaited(_ensureSftpClient());
        case AcpSessionLaunchFailed(:final error):
          setState(() {
            _connecting = false;
            _connectError = error;
          });
        case AcpSessionLaunchBlocked() || null:
          setState(() => _connecting = false);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = const AcpSessionError(
            kind: AcpSessionErrorKind.unknown,
            message: 'Could not reconnect to this session.',
          );
        });
      }
    }
  }

  Future<AcpSessionLaunchResult?> _reconnect({
    required String cwd,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    final manager = ref.read(acpSessionManagerProvider);
    final connection = await ensureAcpHostConnection(context, ref, _key.hostId);
    if (!connection.success) {
      return AcpSessionLaunchFailed(
        _key,
        AcpSessionError(
          kind: AcpSessionErrorKind.transport,
          message:
              connection.error ?? 'Could not establish the SSH connection.',
        ),
      );
    }
    final result = await manager.reconnectSession(
      hostId: _key.hostId,
      providerId: _key.providerId,
      bridgeId: _key.bridgeId,
      acpSessionId: _key.acpSessionId,
      cwd: cwd,
      confirmInstall: (request) => confirmAcpMonkeyMuxInstall(context, request),
      replace: replace,
    );
    if (result is AcpSessionLaunchBlocked && mounted) {
      final choice = await showAcpConcurrencyChoice(
        context,
        decision: result.decision,
        managerState: manager.state,
      );
      if (choice == null) {
        return null;
      }
      return _resolveConcurrency(choice, result.decision, cwd);
    }
    return result;
  }

  Future<AcpSessionLaunchResult?> _resolveConcurrency(
    AcpConcurrencyChoice choice,
    AcpConcurrencyRequiresChoice decision,
    String cwd,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    switch (choice) {
      case AcpConcurrencyChoice.stopAndContinue:
        final blocking = [
          for (final value in decision.blockingSessionKeys)
            manager.state.byKeyValue(value)?.key,
        ].whereType<AcpSessionKey>().toList(growable: false);
        return _reconnect(cwd: cwd, replace: blocking);
      case AcpConcurrencyChoice.upgrade:
        await context.push<void>('/upgrade?feature=concurrentAcpSessions');
        if (!mounted) {
          return null;
        }
        final unlocked = ref
            .read(monetizationServiceProvider)
            .currentState
            .isProUnlocked;
        return unlocked ? _reconnect(cwd: cwd) : null;
    }
  }

  /// Returns a live SFTP client owned by the host's current SSH connection,
  /// reopening it when the cached client belongs to a stale connectionId (for
  /// example after a host reconnect) or has not been opened yet.
  Future<SftpClient?> _ensureSftpClient() async {
    final session = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull;
    if (session == null) {
      return _sftpCache.ensure(connectionId: null, open: _throwNoSession);
    }
    return _sftpCache.ensure(
      connectionId: session.connectionId,
      open: session.sftp,
    );
  }

  static Future<SftpClient> _throwNoSession() =>
      throw StateError('No SSH session');

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final nearBottom = position.pixels >= position.maxScrollExtent - 120;
    if (nearBottom != _autoScroll || _showJumpToLatest == nearBottom) {
      setState(() {
        _autoScroll = nearBottom;
        _showJumpToLatest = !nearBottom;
      });
    }
  }

  void _scheduleAutoScroll() {
    if (!_autoScroll) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_autoScroll) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) {
      return;
    }
    setState(() {
      _autoScroll = true;
      _showJumpToLatest = false;
    });
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  AcpComposerAttachmentActions _attachmentActions(AcpSessionState session) {
    final connectionId = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull
        ?.connectionId;
    final builder = widget.attachmentActionsBuilder;
    if (builder != null) {
      return builder(widget.hostId, connectionId);
    }
    return AcpComposerAttachmentActions(
      pickPhotos: _pickPhotos,
      pickFiles: _pickFiles,
      pickRemoteFiles: (context) => _pickRemoteFiles(context, connectionId),
    );
  }

  Future<List<AcpAttachmentCandidate>> _pickPhotos(BuildContext context) async {
    // Pick images and videos together, preserving the existing XFile adapter
    // and the composer's size/count limits.
    final files = await ImagePicker().pickMultipleMedia();
    return [
      for (final file in files) await acpAttachmentCandidateFromXFile(file),
    ];
  }

  Future<List<AcpAttachmentCandidate>> _pickFiles(BuildContext context) async {
    // pickFiles selects multiple files by default in the current file_picker
    // (the explicit allowMultiple flag is deprecated); adapters/limits are
    // preserved by the shared PlatformFile adapter below.
    final result = await FilePicker.pickFiles();
    if (result == null) {
      return const [];
    }
    return [
      for (final file in result.files)
        await acpAttachmentCandidateFromPlatformFile(file),
    ];
  }

  Future<List<AcpAttachmentCandidate>> _pickRemoteFiles(
    BuildContext context,
    int? connectionId,
  ) async {
    final selection = await showRemoteFilePicker(
      context: context,
      hostId: widget.hostId,
      connectionId: connectionId,
      constraints: const RemoteFilePickerConstraints(allowMultiple: true),
    );
    if (selection == null) {
      return const [];
    }
    return [
      for (final file in selection)
        acpAttachmentCandidateFromRemoteFileSelection(file),
    ];
  }

  Future<void> _openConfig(AcpSessionState session) => showAcpConfigOptions(
    context,
    options: session.configOptions,
    onSetConfigOption: (configId, value) => ref
        .read(acpSessionManagerProvider)
        .setConfigOption(_key, configId: configId, value: value),
    modeState: session.modeState,
    modelState: session.modelState,
    onSetMode: (modeId) =>
        ref.read(acpSessionManagerProvider).setMode(_key, modeId),
    onSetModel: (modelId) =>
        ref.read(acpSessionManagerProvider).setModel(_key, modelId),
    enabled: session.status == AcpConnectionStatus.ready,
  );

  List<AcpPermissionPrompt> _prompts(AcpSessionState session) {
    final manager = ref.read(acpSessionManagerProvider);
    final toolTitles = <String, String>{
      for (final entry
          in session.timeline.entries.whereType<domain.AcpToolCallEntry>())
        if (entry.title?.trim().isNotEmpty ?? false)
          entry.toolCallId: entry.title!.trim(),
    };
    return [
      for (final pending in session.pendingPermissions)
        acpToolPromptFromSession(
          pending,
          onSelect: (optionId) =>
              manager.respondToPermission(_key, pending.requestKey, optionId),
          onCancel: () => manager.cancelPermission(_key, pending.requestKey),
          toolTitle: toolTitles[pending.toolCallId],
        ),
      for (final write in session.pendingWrites)
        AcpWritePermissionPrompt(
          stableKey: 'write:${write.sessionId}:${write.requestKey}',
          fileName: _basename(write.path),
          contentBytes: write.contentByteLength,
          onApprove: () => manager.approveWrite(_key, write.requestKey),
          onReject: () => manager.rejectWrite(_key, write.requestKey),
          revealContent: () =>
              manager.pendingWriteContent(_key, write.requestKey) ?? '',
        ),
    ];
  }

  /// Resolves a chat image to bounded bytes without ever implicitly fetching
  /// over the network.
  ///
  /// In-memory and `data:` images are handled by [AcpInlineImage] itself and
  /// never reach here. Same-host `file:` (or absolute-path) URIs are read via
  /// SFTP up to the shared inline image byte cap; `http(s)`/unknown URIs are
  /// never fetched and resolve to `null`.
  Future<Uint8List?> _resolveChatImage(ui.AcpImageContent image) async {
    final inline = image.bytes;
    if (inline != null) {
      return inline;
    }
    final uri = image.uri;
    if (uri == null || uri.isEmpty || uri.startsWith('data:')) {
      return null;
    }
    if (uri.startsWith('file:')) {
      final parsed = Uri.tryParse(uri);
      final path = parsed?.path;
      return (path != null && path.isNotEmpty)
          ? _readRemoteImageBytes(path)
          : null;
    }
    if (uri.startsWith('/')) {
      return _readRemoteImageBytes(uri);
    }
    // http(s) and unknown schemes are never fetched implicitly.
    return null;
  }

  /// Reads a same-host remote file over SFTP, bounded to the shared inline
  /// image byte cap. Oversized files (declared or streamed) resolve to `null`
  /// so a hostile path can never force an unbounded read into memory.
  Future<Uint8List?> _readRemoteImageBytes(String path) async {
    final sftp = await _ensureSftpClient();
    if (sftp == null) {
      return null;
    }
    try {
      final stat = await sftp.stat(path);
      final size = stat.size;
      if (size != null && size > kAcpMaxInlineImageBytes) {
        return null;
      }
      final file = await sftp.open(path);
      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in file.read()) {
          builder.add(chunk);
          if (builder.length > kAcpMaxInlineImageBytes) {
            return null;
          }
        }
      } finally {
        await file.close();
      }
      return builder.takeBytes();
    } on Object {
      return null;
    }
  }

  void _openImageViewer(ui.AcpImageContent image) {
    final size = MediaQuery.sizeOf(context);
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(FluttyTheme.spacingMd),
        backgroundColor: Colors.black,
        child: SizedBox(
          key: const ValueKey('acp-image-viewer'),
          width: size.width,
          height: size.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: AcpInlineImage(
                      image: image,
                      resolver: _resolveChatImage,
                      maxWidth: size.width,
                      maxHeight: size.height,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openResource(ui.AcpResourceRef resource) {
    final uri = resource.uri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      final parsed = Uri.tryParse(uri);
      if (parsed != null) {
        unawaited(launchUrl(parsed, mode: LaunchMode.externalApplication));
      }
      return;
    }
    _openRemotePath(uri.startsWith('file:') ? Uri.parse(uri).path : uri);
  }

  void _openRemotePath(String path) {
    final connectionId = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull
        ?.connectionId;
    final location = Uri(
      path: '/sftp/${widget.hostId}',
      queryParameters: {
        'path': path,
        if (connectionId != null) 'connectionId': '$connectionId',
      },
    ).toString();
    context.push<void>(location);
  }

  void _copyToClipboard(String value, String label) {
    unawaited(Clipboard.setData(ClipboardData(text: value)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AcpSessionManagerState>>(
      acpSessionManagerStateProvider,
      (previous, next) {
        final session = next.asData?.value.byKeyValue(_key.value);
        _composer.updateSession(session);
        _scheduleAutoScroll();
        if (session != null && session.status == AcpConnectionStatus.ready) {
          unawaited(_ensureSftpClient());
        }
      },
    );

    final managerState = ref
        .watch(acpSessionManagerStateProvider)
        .asData
        ?.value;
    final session = managerState?.byKeyValue(_key.value);
    final isWide = MediaQuery.sizeOf(context).width >= kAgentChatWideBreakpoint;
    final Widget conversation;
    if (isWide && !widget.embedded) {
      conversation = Scaffold(
        body: Row(
          children: [
            AcpSessionRail(currentKey: _key),
            Expanded(child: _buildConversation(session, showBack: true)),
          ],
        ),
      );
    } else {
      conversation = _buildConversation(session, showBack: !widget.embedded);
    }

    final fontSize = clampAgentChatFontSize(
      widget.preferredFontSize ?? ref.watch(fontSizeNotifierProvider),
    );
    final fontFamily =
        widget.preferredFontFamily ??
        ref.watch(fontFamilyNotifierProvider) ??
        'monospace';
    return _AgentChatZoomSurface(
      fontSize: fontSize,
      fontFamily: fontFamily,
      onFontSizeCommitted:
          widget.onFontSizeCommitted ??
          (size) => unawaited(
            ref.read(fontSizeNotifierProvider.notifier).setFontSize(size),
          ),
      child: conversation,
    );
  }

  Widget _buildConversation(
    AcpSessionState? session, {
    required bool showBack,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: showBack,
          title: Text('Agent', style: FluttyTheme.displayMono()),
        ),
        body: _connectError != null
            ? _buildConnectError(_connectError!)
            : _connecting
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: TextButton.icon(
                  onPressed: _ensureConnected,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
              ),
      );
    }

    final entries = mapAcpSessionTimeline(session);
    final prompts = _prompts(session);
    final activity = acpSessionActivityDisplay(session);
    _scheduleAutoScroll();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        titleSpacing: 0,
        title: InkWell(
          onTap: widget.embedded
              ? null
              : () => showAcpSessionSwitcher(context, currentKey: _key),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingSm,
              vertical: FluttyTheme.spacingXs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        acpSessionDisplayTitle(session),
                        style: FluttyTheme.displayMono(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${session.providerLabel} · '
                        '${acpCwdSummary(session.cwd)} · '
                        '${activity.label}',
                        style: FluttyTheme.monoStyle.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!widget.embedded) const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        actions: [
          if (!widget.embedded)
            IconButton(
              tooltip: 'MonkeyMux windows',
              icon: const Icon(Icons.window_outlined),
              onPressed: _openMonkeyMuxWindows,
            ),
          _buildOverflowMenu(session),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (session.status != AcpConnectionStatus.ready)
              _buildSessionStatusBanner(session)
            else if (!activity.isReady)
              _SessionStatusBanner(
                message: switch (activity.label) {
                  'working' => 'agent is working',
                  'sending' => 'sending prompt',
                  'cancelling' => 'cancelling current turn',
                  _ => activity.label,
                },
                icon: activity.icon,
                tone: activity.tone,
                transitioning:
                    session.promptStatus != AcpPromptStatus.idle &&
                    !activity.needsInput,
                progressFraction: activity.progressFraction,
                indeterminateProgress: activity.indeterminate,
              ),
            Expanded(
              child: Stack(
                children: [
                  if (entries.isEmpty)
                    _AcpEmptyConversation(
                      providerLabel: session.providerLabel,
                      cwd: acpCwdSummary(session.cwd),
                    )
                  else
                    AcpMessageThread(
                      entries: entries,
                      controller: _scroll,
                      imageResolver: _resolveChatImage,
                      onTapImage: _openImageViewer,
                      onOpenResource: _openResource,
                      onCopyResource: (resource) =>
                          _copyToClipboard(resource.uri, 'Resource'),
                      onCopyCode: (code) => _copyToClipboard(code, 'Code'),
                      onOpenLocation: (location) =>
                          _openRemotePath(location.path),
                    ),
                  if (_showJumpToLatest)
                    Positioned(
                      right: FluttyTheme.spacingMd,
                      bottom: FluttyTheme.spacingMd,
                      child: SizedBox.square(
                        dimension: 44,
                        child: FloatingActionButton.small(
                          heroTag: 'acp-jump-latest',
                          tooltip: 'Jump to latest',
                          onPressed: _jumpToLatest,
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (prompts.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.34,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluttyTheme.spacingMd,
                  ),
                  child: AcpPermissionSurface(prompts: prompts),
                ),
              ),
            AcpComposer(
              controller: _composer,
              attachmentActions: _attachmentActions(session),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionStatusBanner(AcpSessionState session) {
    final status = session.status;
    final transitioning =
        status == AcpConnectionStatus.idle ||
        status == AcpConnectionStatus.connecting ||
        status == AcpConnectionStatus.initializing ||
        status == AcpConnectionStatus.reconnecting;
    final (message, icon) = switch (status) {
      AcpConnectionStatus.idle => ('agent is getting ready', Icons.schedule),
      AcpConnectionStatus.connecting => ('connecting to agent', Icons.link),
      AcpConnectionStatus.initializing => (
        'initializing native chat',
        Icons.settings_outlined,
      ),
      AcpConnectionStatus.reconnecting => ('reattaching session', Icons.sync),
      AcpConnectionStatus.authenticationRequired => (
        'agent sign-in required',
        Icons.lock_outline,
      ),
      AcpConnectionStatus.detached => (
        'session is detached',
        Icons.pause_circle_outline,
      ),
      AcpConnectionStatus.bridgeExpired => (
        'remote session expired',
        Icons.history_toggle_off,
      ),
      AcpConnectionStatus.providerExited => (
        'agent process exited',
        Icons.exit_to_app,
      ),
      AcpConnectionStatus.failed => (
        'agent connection failed',
        Icons.error_outline,
      ),
      AcpConnectionStatus.closed => ('session is closed', Icons.link_off),
      AcpConnectionStatus.ready => ('ready', Icons.check_circle_outline),
    };
    return _SessionStatusBanner(
      message: message,
      icon: icon,
      transitioning: transitioning,
      actionLabel: status == AcpConnectionStatus.authenticationRequired
          ? 'Open terminal'
          : (transitioning ? null : 'Reconnect'),
      onAction: status == AcpConnectionStatus.authenticationRequired
          ? _openTerminalForAuth
          : (transitioning ? null : _ensureConnected),
    );
  }

  Widget _buildConnectError(AcpSessionError error) {
    final canOpenTerminal =
        error.kind == AcpSessionErrorKind.authenticationRequired;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandErrorState(
              title: 'couldn’t open this session',
              message: error.message,
              onRetry: _ensureConnected,
            ),
            const SizedBox(height: FluttyTheme.spacingLg),
            if (canOpenTerminal)
              OutlinedButton.icon(
                onPressed: _openTerminalForAuth,
                icon: const Icon(Icons.terminal),
                label: const Text('Open Terminal'),
              ),
            const SizedBox(height: FluttyTheme.spacingSm),
            TextButton.icon(
              onPressed: _leaveChat,
              icon: const Icon(Icons.window_outlined),
              label: const Text('Back to windows'),
            ),
          ],
        ),
      ),
    );
  }

  void _openMonkeyMuxWindows() {
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    unawaited(context.push<void>('/terminal/${widget.hostId}'));
  }

  void _leaveChat() {
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
      return;
    }
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go(buildAcpSessionFallbackLocation());
  }

  void _openTerminalForAuth() {
    final authCommand = acpTerminalAuthCommandFor(widget.providerId);
    if (authCommand != null) {
      unawaited(
        Clipboard.setData(ClipboardData(text: authCommand.argv.join(' '))),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign-in command copied — run it in the terminal.'),
        ),
      );
    }
    if (widget.embedded) {
      widget.onExitEmbedded?.call();
    } else {
      context.push<void>('/terminal/${widget.hostId}');
    }
  }

  Widget _buildOverflowMenu(AcpSessionState session) {
    final sessionCaps = session.capabilities.session;
    return PopupMenuButton<_ChatAction>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => _handleAction(action, session),
      itemBuilder: (context) => [
        if (session.status == AcpConnectionStatus.ready)
          const PopupMenuItem(
            value: _ChatAction.settings,
            child: ListTile(
              leading: Icon(Icons.tune),
              title: Text('Session settings'),
            ),
          ),
        if (!session.isLive ||
            session.status == AcpConnectionStatus.reconnecting)
          const PopupMenuItem(
            value: _ChatAction.reconnect,
            child: ListTile(
              leading: Icon(Icons.refresh),
              title: Text('Reconnect'),
            ),
          ),
        const PopupMenuItem(
          value: _ChatAction.detach,
          child: ListTile(
            leading: Icon(Icons.pause_circle_outline),
            title: Text('Detach'),
          ),
        ),
        const PopupMenuItem(
          value: _ChatAction.stop,
          child: ListTile(
            leading: Icon(Icons.stop_circle_outlined),
            title: Text('Stop session'),
          ),
        ),
        if (sessionCaps.fork)
          const PopupMenuItem(
            value: _ChatAction.fork,
            child: ListTile(
              leading: Icon(Icons.call_split),
              title: Text('Fork session'),
            ),
          ),
        if (sessionCaps.delete)
          const PopupMenuItem(
            value: _ChatAction.delete,
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Delete session'),
            ),
          ),
      ],
    );
  }

  Future<bool> _confirmDeleteSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      requestFocus: terminalOverlayRouteRequestFocus(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete session?'),
        content: const Text(
          'This permanently removes the session from the agent. This action '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete session'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _handleAction(
    _ChatAction action,
    AcpSessionState session,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    switch (action) {
      case _ChatAction.settings:
        await _openConfig(session);
      case _ChatAction.reconnect:
        await _ensureConnected();
      case _ChatAction.detach:
        await manager.detachSession(_key);
        if (mounted) {
          _leaveChat();
        }
      case _ChatAction.stop:
        await manager.stopSession(_key);
        if (mounted) {
          _leaveChat();
        }
      case _ChatAction.fork:
        await _fork();
      case _ChatAction.delete:
        if (!await _confirmDeleteSession() || !mounted) {
          return;
        }
        await manager.deleteSession(_key);
        if (mounted) {
          _leaveChat();
        }
    }
  }

  /// Forks the current session, resolving a free-tier concurrency block with
  /// the same stop-and-continue vs. Pro-upgrade choice used elsewhere, then
  /// opening the new session or surfacing a safe error.
  Future<void> _fork() async {
    final manager = ref.read(acpSessionManagerProvider);
    var result = await manager.forkSession(_key);

    if (result is AcpSessionLaunchBlocked) {
      if (!mounted) {
        return;
      }
      final decision = result.decision;
      final choice = await showAcpConcurrencyChoice(
        context,
        decision: decision,
        managerState: manager.state,
      );
      if (choice == null || !mounted) {
        return;
      }
      switch (choice) {
        case AcpConcurrencyChoice.stopAndContinue:
          // forkSession has no replace parameter, so free capacity first by
          // stopping the blocking live session(s), then retry the fork.
          for (final value in decision.blockingSessionKeys) {
            final blockingKey = manager.state.byKeyValue(value)?.key;
            if (blockingKey != null) {
              await manager.stopSession(blockingKey);
            }
          }
          if (!mounted) {
            return;
          }
          result = await manager.forkSession(_key);
        case AcpConcurrencyChoice.upgrade:
          await context.push<void>('/upgrade?feature=concurrentAcpSessions');
          if (!mounted) {
            return;
          }
          final unlocked = ref
              .read(monetizationServiceProvider)
              .currentState
              .isProUnlocked;
          if (!unlocked) {
            return;
          }
          result = await manager.forkSession(_key);
      }
    }

    if (!mounted) {
      return;
    }
    switch (result) {
      case AcpSessionLaunchStarted(:final key):
        if (widget.embedded) {
          widget.onSessionChanged?.call(key);
        } else {
          context.replace(
            buildAgentChatLocation(
              hostId: key.hostId,
              providerId: key.providerId,
              bridgeId: key.bridgeId,
              acpSessionId: key.acpSessionId,
            ),
          );
        }
      case AcpSessionLaunchFailed(:final error):
        _showSnack(error.message);
      case AcpSessionLaunchBlocked():
        // Still blocked after the resolution attempt: leave the session as-is.
        break;
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _basename(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final separator = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    final segment = separator >= 0 ? trimmed.substring(separator + 1) : trimmed;
    return segment.isEmpty ? path : segment;
  }
}

class _SessionStatusBanner extends StatelessWidget {
  const _SessionStatusBanner({
    required this.message,
    required this.icon,
    required this.transitioning,
    this.tone = AcpStatusTone.neutral,
    this.progressFraction,
    this.indeterminateProgress = false,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final bool transitioning;
  final AcpStatusTone tone;
  final double? progressFraction;
  final bool indeterminateProgress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = acpStatusColor(scheme, tone);
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingMd,
            vertical: FluttyTheme.spacingSm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: statusColor),
                  const SizedBox(width: FluttyTheme.spacingSm),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            message,
                            style: AcpChatTypography.monoStyleOf(context)
                                .copyWith(
                                  color: scheme.onSurface,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (transitioning) ...[
                          const SizedBox(width: FluttyTheme.spacingSm),
                          CursorBlock(color: statusColor, size: 10),
                        ],
                      ],
                    ),
                  ),
                  if (actionLabel != null)
                    TextButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ),
              if (progressFraction != null || indeterminateProgress) ...[
                const SizedBox(height: FluttyTheme.spacingXs),
                LinearProgressIndicator(
                  value: indeterminateProgress ? null : progressFraction,
                  minHeight: 2,
                  color: statusColor,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AcpEmptyConversation extends StatelessWidget {
  const _AcpEmptyConversation({required this.providerLabel, required this.cwd});

  final String providerLabel;
  final String cwd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FluttyTheme.spacingLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.terminal, color: scheme.primary, size: 22),
                const SizedBox(width: FluttyTheme.spacingSm),
                CursorBlock(color: scheme.primary, size: 14),
              ],
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            Text(
              'ready when you are',
              style: FluttyTheme.displayMono(
                fontSize: 17,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            Text(
              '$providerLabel · $cwd',
              style: FluttyTheme.monoStyle.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingSm),
            Text(
              'Type / to see agent commands.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentChatZoomSurface extends StatefulWidget {
  const _AgentChatZoomSurface({
    required this.fontSize,
    required this.fontFamily,
    required this.onFontSizeCommitted,
    required this.child,
  });

  final double fontSize;
  final String fontFamily;
  final ValueChanged<double> onFontSizeCommitted;
  final Widget child;

  @override
  State<_AgentChatZoomSurface> createState() => _AgentChatZoomSurfaceState();
}

class _AgentChatZoomSurfaceState extends State<_AgentChatZoomSurface> {
  double? _gestureBaseFontSize;
  double? _localFontSize;
  bool _isPinching = false;
  bool _pinchChangedFontSize = false;

  @override
  void didUpdateWidget(_AgentChatZoomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isPinching && oldWidget.fontSize != widget.fontSize) {
      _localFontSize = null;
    }
  }

  void _handlePinchStart() {
    final current = _localFontSize ?? widget.fontSize;
    _gestureBaseFontSize = current;
    _pinchChangedFontSize = false;
    setState(() => _isPinching = true);
  }

  void _handlePinchUpdate(double scale) {
    final base = _gestureBaseFontSize;
    if (base == null || !scale.isFinite || scale <= 0) {
      return;
    }
    final next = clampAgentChatFontSize(base * scale);
    if (_localFontSize == next) {
      return;
    }
    setState(() {
      _localFontSize = next;
      _pinchChangedFontSize = next != base;
    });
  }

  void _handlePinchEnd() {
    final committed = _localFontSize ?? widget.fontSize;
    final shouldCommit = _pinchChangedFontSize;
    _gestureBaseFontSize = null;
    _pinchChangedFontSize = false;
    setState(() => _isPinching = false);
    if (shouldCommit) {
      widget.onFontSizeCommitted(committed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = clampAgentChatFontSize(_localFontSize ?? widget.fontSize);
    final mediaQuery = MediaQuery.of(context);
    final inheritedScale = mediaQuery.textScaler.scale(14) / 14;
    final textScaler = TextScaler.linear(inheritedScale * fontSize / 14);
    final theme = Theme.of(context);
    final configuredMono = resolveMonospaceTextStyle(
      widget.fontFamily,
      platform: theme.platform,
    );
    final monoStyle = FluttyTheme.monoStyle.merge(configuredMono);
    final scaledTheme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: configuredMono.fontFamily),
      primaryTextTheme: theme.primaryTextTheme.apply(
        fontFamily: configuredMono.fontFamily,
      ),
    );

    Widget child = MediaQuery(
      data: mediaQuery.copyWith(textScaler: textScaler),
      child: Theme(
        data: scaledTheme,
        child: AcpChatTypography(monoStyle: monoStyle, child: widget.child),
      ),
    );
    if (_isPinching) {
      child = Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: 12,
            right: 12,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluttyTheme.spacingSm,
                    vertical: FluttyTheme.spacingXs,
                  ),
                  child: Text(
                    '${fontSize.toStringAsFixed(0)} pt',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return TerminalPinchZoomGestureHandler(
      onPinchStart: _handlePinchStart,
      onPinchUpdate: _handlePinchUpdate,
      onPinchEnd: _handlePinchEnd,
      child: child,
    );
  }
}

enum _ChatAction { settings, reconnect, detach, stop, fork, delete }
