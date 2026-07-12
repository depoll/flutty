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
import '../../domain/services/acp_attachment_service.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/local_notification_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/ssh_service.dart';
import '../controllers/acp_composer_controller.dart';
import '../models/acp_attachment_picker_adapters.dart';
import '../models/acp_timeline.dart' as ui;
import '../models/acp_timeline_mapper.dart';
import '../widgets/acp_composer.dart';
import '../widgets/acp_concurrency_choice.dart';
import '../widgets/acp_config_option_controls.dart';
import '../widgets/acp_message_thread.dart';
import '../widgets/acp_new_session_sheet.dart';
import '../widgets/acp_permission_surface.dart';
import '../widgets/acp_session_presentation.dart';
import '../widgets/acp_session_switcher.dart';
import '../widgets/brand_error_state.dart';
import 'sftp_screen.dart';

/// Builds the attachment picker actions for a chat session. Overridable in
/// tests so the composer can be exercised without platform pickers.
typedef AcpChatAttachmentActionsBuilder =
    AcpComposerAttachmentActions Function(int hostId, int? connectionId);

/// Wide-layout breakpoint for the session rail.
const double kAgentChatWideBreakpoint = 600;

/// Full-screen agent chat for one ACP session.
class AgentChatScreen extends ConsumerStatefulWidget {
  /// Creates an agent chat screen from its opaque session identifiers.
  const AgentChatScreen({
    required this.hostId,
    required this.providerId,
    required this.bridgeId,
    required this.acpSessionId,
    this.attachmentActionsBuilder,
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

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen> {
  late final AcpSessionKey _key;
  late final AcpComposerController _composer;
  final ScrollController _scroll = ScrollController();

  var _autoScroll = true;
  var _showJumpToLatest = false;
  var _connecting = true;
  AcpSessionError? _connectError;
  SftpClient? _sftpClient;
  var _openingSftp = false;

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
    final client = _sftpClient;
    if (client == null) {
      return null;
    }
    return SftpAcpAttachmentUploader(sftp: client);
  }

  Future<void> _ensureConnected() async {
    final manager = ref.read(acpSessionManagerProvider);
    final existing = manager.state.byKeyValue(_key.value);
    if (existing != null && existing.isLive) {
      unawaited(manager.selectSession(_key));
      unawaited(_openSftp());
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
        case AcpSessionLaunchStarted():
          unawaited(manager.selectSession(_key));
          unawaited(_openSftp());
          setState(() => _connecting = false);
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
    // Ensure the SSH connection is available before attaching the bridge.
    await ref.read(activeSessionsProvider.notifier).connect(widget.hostId);
    final result = await manager.reconnectSession(
      hostId: widget.hostId,
      providerId: widget.providerId,
      bridgeId: widget.bridgeId,
      acpSessionId: widget.acpSessionId,
      cwd: cwd,
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

  Future<void> _openSftp() async {
    if (_sftpClient != null || _openingSftp) {
      return;
    }
    final session = ref
        .read(sshServiceProvider)
        .getSessionsForHost(widget.hostId)
        .firstOrNull;
    if (session == null) {
      return;
    }
    _openingSftp = true;
    try {
      final client = await session.sftp();
      if (mounted) {
        _sftpClient = client;
      }
    } on Object {
      // Remote-upload fallback simply stays unavailable until retried.
    } finally {
      _openingSftp = false;
    }
  }

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
    final files = await ImagePicker().pickMultiImage();
    return [
      for (final file in files) await acpAttachmentCandidateFromXFile(file),
    ];
  }

  Future<List<AcpAttachmentCandidate>> _pickFiles(BuildContext context) async {
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
    return [
      for (final pending in session.pendingPermissions)
        acpToolPromptFromSession(
          pending,
          onSelect: (optionId) =>
              manager.respondToPermission(_key, pending.requestKey, optionId),
          onCancel: () => manager.cancelPermission(_key, pending.requestKey),
        ),
      for (final write in session.pendingWrites)
        AcpWritePermissionPrompt(
          stableKey: 'write:${write.sessionId}:${write.requestKey}',
          fileName: _basename(write.path),
          contentBytes: write.contentByteLength,
          onApprove: () => manager.approveWrite(_key, write.requestKey),
          onReject: () => manager.rejectWrite(_key, write.requestKey),
        ),
    ];
  }

  void _openImageViewer(ui.AcpImageContent image) {
    final bytes = image.bytes;
    final uri = image.uri;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(FluttyTheme.spacingMd),
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: bytes != null
                      ? Image.memory(bytes, fit: BoxFit.contain)
                      : (uri != null
                            ? Image.network(uri, fit: BoxFit.contain)
                            : const SizedBox.shrink()),
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
          unawaited(_openSftp());
        }
      },
    );

    final managerState = ref
        .watch(acpSessionManagerStateProvider)
        .asData
        ?.value;
    final session = managerState?.byKeyValue(_key.value);
    final isWide = MediaQuery.sizeOf(context).width >= kAgentChatWideBreakpoint;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            AcpSessionRail(currentKey: _key),
            Expanded(child: _buildConversation(session, showBack: true)),
          ],
        ),
      );
    }
    return _buildConversation(session, showBack: true);
  }

  Widget _buildConversation(
    AcpSessionState? session, {
    required bool showBack,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: Text('Agent', style: FluttyTheme.displayMono())),
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
    _scheduleAutoScroll();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        titleSpacing: 0,
        title: InkWell(
          onTap: () => showAcpSessionSwitcher(context, currentKey: _key),
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
                        '${acpStatusDisplay(session.status).label}',
                        style: FluttyTheme.monoStyle.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Session settings',
            icon: const Icon(Icons.tune),
            onPressed: session.status == AcpConnectionStatus.ready
                ? () => _openConfig(session)
                : null,
          ),
          _buildOverflowMenu(session),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  AcpMessageThread(
                    entries: entries,
                    controller: _scroll,
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
                      child: FloatingActionButton.small(
                        heroTag: 'acp-jump-latest',
                        onPressed: _jumpToLatest,
                        child: const Icon(Icons.arrow_downward),
                      ),
                    ),
                ],
              ),
            ),
            if (prompts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: FluttyTheme.spacingMd,
                ),
                child: AcpPermissionSurface(prompts: prompts),
              ),
            AcpComposer(
              controller: _composer,
              attachmentActions: _attachmentActions(session),
              onOpenConfig: session.status == AcpConnectionStatus.ready
                  ? () => _openConfig(session)
                  : null,
            ),
          ],
        ),
      ),
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
              onPressed: () => context.go(buildAgentsOverviewLocation()),
              icon: const Icon(Icons.hub),
              label: const Text('Back to agents'),
            ),
          ],
        ),
      ),
    );
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
    context.push<void>('/terminal/${widget.hostId}');
  }

  Widget _buildOverflowMenu(AcpSessionState session) {
    final sessionCaps = session.capabilities.session;
    return PopupMenuButton<_ChatAction>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => _handleAction(action, session),
      itemBuilder: (context) => [
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

  Future<void> _handleAction(
    _ChatAction action,
    AcpSessionState session,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    switch (action) {
      case _ChatAction.reconnect:
        await _ensureConnected();
      case _ChatAction.detach:
        await manager.detachSession(_key);
        if (mounted) {
          context.go(buildAgentsOverviewLocation());
        }
      case _ChatAction.stop:
        await manager.stopSession(_key);
        if (mounted) {
          context.go(buildAgentsOverviewLocation());
        }
      case _ChatAction.fork:
        final result = await manager.forkSession(_key);
        if (result is AcpSessionLaunchStarted && mounted) {
          context.replace(
            buildAgentChatLocation(
              hostId: result.key.hostId,
              providerId: result.key.providerId,
              bridgeId: result.key.bridgeId,
              acpSessionId: result.key.acpSessionId,
            ),
          );
        }
      case _ChatAction.delete:
        await manager.deleteSession(_key);
        if (mounted) {
          context.go(buildAgentsOverviewLocation());
        }
    }
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

enum _ChatAction { reconnect, detach, stop, fork, delete }
