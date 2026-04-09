import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as path;

import '../../data/repositories/host_repository.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/remote_file_service.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/connection_preview_snippet.dart';
import '../widgets/syntax_highlight_controller.dart';
import '../widgets/syntax_highlight_language.dart';
import '../widgets/syntax_highlight_theme.dart';
import 'remote_text_editor_screen.dart';

const _maxEditableBytes = 1024 * 1024;
const _maxPreviewBytes = 10 * 1024 * 1024;
const _requestedPathLookupTimeout = Duration(seconds: 5);
const _sftpFileRowExtentEstimate = 64.0;
const _sftpHighlightedFileScrollPadding = 16.0;
const _sftpScrollAnimationDuration = Duration(milliseconds: 220);

/// Returns the parent directory for a POSIX remote path.
@visibleForTesting
String parentRemotePath(String remotePath) {
  final parent = path.posix.dirname(remotePath);
  return parent.isEmpty || parent == '.' ? '/' : parent;
}

/// Appends a visited remote path to browser history without duplicating the top.
@visibleForTesting
List<String> pushSftpPathHistory(List<String> history, String remotePath) {
  final nextHistory = List<String>.from(history);
  if (nextHistory.isEmpty || nextHistory.last != remotePath) {
    nextHistory.add(remotePath);
  }
  return nextHistory;
}

/// Pops browser history while always retaining at least one location.
@visibleForTesting
List<String> popSftpPathHistory(List<String> history) {
  if (history.length <= 1) {
    return history.isEmpty ? ['/'] : List<String>.from(history);
  }
  return List<String>.from(history)..removeLast();
}

/// Resolves the list offset needed to reveal a highlighted file row.
@visibleForTesting
double resolveSftpHighlightedFileScrollOffset({
  required int highlightedIndex,
  required double currentOffset,
  required double itemExtentEstimate,
  required double viewportExtent,
  required double maxScrollExtent,
  double padding = _sftpHighlightedFileScrollPadding,
}) {
  final itemTop = highlightedIndex * itemExtentEstimate;
  final itemBottom = itemTop + itemExtentEstimate;
  final viewportTop = currentOffset;
  final viewportBottom = currentOffset + viewportExtent;

  if (itemTop - padding < viewportTop) {
    return (itemTop - padding).clamp(0.0, maxScrollExtent);
  }
  if (itemBottom + padding > viewportBottom) {
    return (itemBottom + padding - viewportExtent).clamp(0.0, maxScrollExtent);
  }
  return currentOffset.clamp(0.0, maxScrollExtent);
}

/// Resolves how a requested path should open in the browser.
@visibleForTesting
({String directoryPath, String? highlightedFileName})
resolveRequestedSftpNavigationTarget(
  String normalizedPath, {
  required bool isDirectory,
}) => (
  directoryPath: isDirectory
      ? normalizedPath
      : parentRemotePath(normalizedPath),
  highlightedFileName: isDirectory ? null : path.posix.basename(normalizedPath),
);

/// Whether the file name should be previewable as an image.
@visibleForTesting
bool isPreviewableImageFileName(String filename) {
  final extension = path.extension(filename).toLowerCase();
  return {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
  }.contains(extension);
}

/// Whether the file name is an SVG image.
@visibleForTesting
bool isSvgFileName(String filename) =>
    path.extension(filename).toLowerCase() == '.svg';

/// Resolves the picker request used for local SFTP uploads.
@visibleForTesting
({bool allowMultiple, bool withReadStream}) resolveSftpUploadPickerRequest() =>
    (allowMultiple: true, withReadStream: true);

/// Resolves a readable stream for a picked SFTP upload file when available.
@visibleForTesting
Stream<List<int>>? resolvePickedSftpUploadReadStream(PlatformFile file) =>
    file.readStream ?? (file.path == null ? null : File(file.path!).openRead());

/// Resolves the error message shown when selected SFTP upload files are unreadable.
@visibleForTesting
String resolveUnreadableSftpUploadMessage(List<PlatformFile> files) {
  if (files.length == 1) {
    final name = files.single.name.trim();
    return name.isEmpty
        ? 'Unable to read the selected file'
        : 'Unable to read "$name"';
  }
  return 'Unable to read ${files.length} selected files';
}

/// How a file row tap should behave in the SFTP browser.
@visibleForTesting
enum SftpFileTapIntent {
  /// Navigate into a tapped directory.
  navigate,

  /// Preview a tapped image file.
  preview,

  /// Open a tapped non-image file in the editor.
  edit,
}

/// Resolves the primary action for tapping an SFTP entry.
@visibleForTesting
SftpFileTapIntent resolveSftpFileTapIntent({
  required bool isDirectory,
  required String filename,
}) {
  if (isDirectory) {
    return SftpFileTapIntent.navigate;
  }
  if (isPreviewableImageFileName(filename)) {
    return SftpFileTapIntent.preview;
  }
  return SftpFileTapIntent.edit;
}

/// SFTP file browser screen.
class SftpScreen extends ConsumerStatefulWidget {
  /// Creates a new [SftpScreen].
  const SftpScreen({
    required this.hostId,
    this.connectionId,
    this.initialPath,
    this.initialWorkingDirectory,
    super.key,
  });

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

  /// Optional remote path to open when the browser loads.
  final String? initialPath;

  /// Optional terminal working directory used to resolve relative paths.
  final String? initialWorkingDirectory;

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  SftpClient? _sftp;
  final ScrollController _breadcrumbScrollController = ScrollController();
  final ScrollController _fileListScrollController = ScrollController();
  String _currentPath = '/';
  List<SftpName> _files = [];
  bool _isLoading = true;
  String? _error;
  final List<String> _pathHistory = ['/'];
  String? _hostLabel;
  String? _pendingInitialPath;
  String? _highlightedDirectoryPath;
  String? _highlightedFileName;
  String? _homeDirectoryPath;
  String? _fallbackDirectoryPath;

  @override
  void initState() {
    super.initState();
    _pendingInitialPath = _sanitizeRequestedPath(widget.initialPath);
    _connect();
  }

  @override
  void didUpdateWidget(covariant SftpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.initialPath == widget.initialPath &&
        oldWidget.initialWorkingDirectory == widget.initialWorkingDirectory) {
      return;
    }

    final nextInitialPath = _sanitizeRequestedPath(widget.initialPath);
    _pendingInitialPath = nextInitialPath;
    if (_sftp != null && nextInitialPath != null) {
      final pathToOpen = nextInitialPath;
      _pendingInitialPath = null;
      unawaited(_openRequestedPath(pathToOpen));
    }
  }

  @override
  void dispose() {
    _breadcrumbScrollController.dispose();
    _fileListScrollController.dispose();
    _sftp?.close();
    _sftp = null;
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final remoteFileService = ref.read(remoteFileServiceProvider);
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      var connectionId =
          widget.connectionId ??
          sessionsNotifier.getPreferredConnectionForHost(widget.hostId);
      var session = connectionId == null
          ? null
          : sessionsNotifier.getSession(connectionId);

      // Connect if not already connected
      if (session == null) {
        final result = await sessionsNotifier.connect(widget.hostId);
        if (!mounted) {
          return;
        }
        if (!result.success) {
          setState(() {
            _isLoading = false;
            _error = result.error ?? 'Connection failed';
          });
          return;
        }
        connectionId = result.connectionId;
        if (connectionId != null) {
          session = sessionsNotifier.getSession(connectionId);
        }
      }

      if (session == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
          _error = 'Session not found';
        });
        return;
      }

      await sessionsNotifier.syncBackgroundStatus();
      if (!mounted) {
        return;
      }
      final sftp = await session.sftp();
      if (!mounted) {
        sftp.close();
        return;
      }
      _sftp?.close();
      _sftp = sftp;
      _hostLabel = session.config.hostname;
      final initialPath = await remoteFileService.resolveInitialDirectory(sftp);
      if (!mounted) {
        sftp.close();
        _sftp = null;
        return;
      }
      _fallbackDirectoryPath = normalizeSftpAbsolutePath(initialPath) ?? '/';
      final requestedPath = _pendingInitialPath;
      if (requestedPath != null) {
        _pendingInitialPath = null;
        await _openRequestedPath(requestedPath);
        return;
      }
      if (await _loadDirectory(
        _fallbackDirectoryPath!,
        nextHistory: [_fallbackDirectoryPath!],
        showError: false,
      )) {
        return;
      }
      await _openFallbackDirectory(preferredPath: _fallbackDirectoryPath);
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = 'SFTP connection failed: $e';
      });
    }
  }

  Future<String?> _resolveHomeDirectoryPath() async {
    if (_homeDirectoryPath != null) {
      return _homeDirectoryPath;
    }
    if (_sftp == null) {
      return null;
    }

    try {
      final resolvedPath = normalizeSftpAbsolutePath(
        await _sftp!.absolute('.').timeout(_requestedPathLookupTimeout),
      );
      if (resolvedPath != null) {
        _homeDirectoryPath = resolvedPath;
      }
      return resolvedPath;
    } on TimeoutException {
      return null;
    } on SftpStatusError {
      return null;
    }
  }

  Future<void> _openFallbackDirectory({String? preferredPath}) async {
    final candidatePaths = <String>[];

    void addCandidate(String? path) {
      final normalizedPath = normalizeSftpAbsolutePath(path);
      if (normalizedPath == null || candidatePaths.contains(normalizedPath)) {
        return;
      }
      candidatePaths.add(normalizedPath);
    }

    addCandidate(preferredPath);
    addCandidate(_fallbackDirectoryPath);
    addCandidate(widget.initialWorkingDirectory);
    addCandidate(_currentPath);
    addCandidate(await _resolveHomeDirectoryPath());
    addCandidate('/');

    for (final candidatePath in candidatePaths) {
      if (await _loadDirectory(
        candidatePath,
        nextHistory: [candidatePath],
        showError: false,
      )) {
        _pendingInitialPath = null;
        return;
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      _error = 'Failed to open SFTP browser';
    });
  }

  Future<bool> _loadDirectory(
    String path, {
    List<String>? nextHistory,
    bool showError = true,
  }) async {
    if (_sftp == null) {
      return false;
    }

    setState(() => _isLoading = true);

    try {
      final items = await _sftp!.listdir(path);
      if (!mounted) {
        return false;
      }
      setState(() {
        _currentPath = path;
        _files = items
          ..sort((a, b) {
            // Directories first, then by name
            final aIsDir = a.attr.isDirectory;
            final bIsDir = b.attr.isDirectory;
            if (aIsDir && !bIsDir) return -1;
            if (!aIsDir && bIsDir) return 1;
            return a.filename.compareTo(b.filename);
          });
        if (nextHistory != null) {
          _pathHistory
            ..clear()
            ..addAll(nextHistory);
        }
        if (_highlightedDirectoryPath != path) {
          _highlightedDirectoryPath = null;
          _highlightedFileName = null;
        }
        _isLoading = false;
        _error = null;
      });
      _queueScrollBreadcrumbTailIntoView();
      return true;
    } on Exception catch (e) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _isLoading = false;
        if (showError) {
          _error = 'Failed to list directory: $e';
        }
      });
      return false;
    }
  }

  Future<void> _navigateTo(String path) async {
    if (path == _currentPath) {
      return;
    }
    await _loadDirectory(
      path,
      nextHistory: pushSftpPathHistory(_pathHistory, path),
    );
  }

  Future<void> _navigateUp() async {
    if (_currentPath == '/') {
      return;
    }
    final parentPath = parentRemotePath(_currentPath);
    await _loadDirectory(
      parentPath,
      nextHistory: pushSftpPathHistory(_pathHistory, parentPath),
    );
  }

  Future<void> _goBack() async {
    if (_pathHistory.length <= 1) {
      return;
    }
    final nextHistory = popSftpPathHistory(_pathHistory);
    await _loadDirectory(nextHistory.last, nextHistory: nextHistory);
  }

  Future<bool> _openRequestedPath(String requestedPath) async {
    final homeDirectory = await _resolveHomeDirectoryPath();
    if (!mounted) {
      return false;
    }
    final normalizedPath = resolveRequestedSftpPath(
      requestedPath,
      workingDirectory: widget.initialWorkingDirectory,
      homeDirectory: homeDirectory,
    );
    if (normalizedPath == null) {
      _closeRequestedPathWithError(
        'Could not open "$requestedPath" in SFTP: could not resolve path',
      );
      return false;
    }

    if (normalizedPath == '/') {
      if (await _loadDirectory(
        normalizedPath,
        nextHistory: [normalizedPath],
        showError: false,
      )) {
        return true;
      }
      _closeRequestedPathWithError(
        'Could not open "$normalizedPath" in SFTP: failed to list directory',
      );
      return false;
    }

    final sftp = _sftp;
    if (sftp == null) {
      _closeRequestedPathWithError('Could not open "$requestedPath" in SFTP');
      return false;
    }

    late final SftpFileAttrs requestedPathStat;
    try {
      requestedPathStat = await sftp
          .stat(normalizedPath)
          .timeout(_requestedPathLookupTimeout);
    } on TimeoutException {
      _closeRequestedPathWithError(
        'Timed out opening "$normalizedPath" in SFTP',
      );
      return false;
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) {
        _closeRequestedPathWithError(
          'Could not open "$normalizedPath" in SFTP: path does not exist',
        );
        return false;
      }
      _closeRequestedPathWithError('Could not open "$normalizedPath" in SFTP');
      return false;
    }

    final navigationTarget = resolveRequestedSftpNavigationTarget(
      normalizedPath,
      isDirectory: requestedPathStat.isDirectory,
    );
    if (await _loadDirectory(
      navigationTarget.directoryPath,
      nextHistory: [navigationTarget.directoryPath],
      showError: false,
    )) {
      final fileName = navigationTarget.highlightedFileName;
      if (fileName == null) {
        return true;
      }

      SftpName? matchingEntry;
      for (final entry in _files) {
        if (entry.filename == fileName) {
          matchingEntry = entry;
          break;
        }
      }
      if (matchingEntry == null) {
        _closeRequestedPathWithError(
          'Could not open "$normalizedPath" in SFTP: path does not exist',
        );
        return false;
      }

      if (!mounted) {
        return true;
      }
      setState(() {
        _highlightedDirectoryPath = navigationTarget.directoryPath;
        _highlightedFileName = fileName;
      });
      _queueScrollHighlightedFileIntoView();
      return true;
    }

    _closeRequestedPathWithError('Could not open "$normalizedPath" in SFTP');
    return false;
  }

  void _closeRequestedPathWithError(String message) {
    if (!mounted) {
      return;
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(message);
      return;
    }

    setState(() {
      _isLoading = false;
      _error = message;
    });
    unawaited(_openFallbackDirectory(preferredPath: _currentPath));
  }

  void _queueScrollHighlightedFileIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _highlightedDirectoryPath != _currentPath ||
          _highlightedFileName == null ||
          !_fileListScrollController.hasClients) {
        return;
      }

      final highlightedIndex = _files.indexWhere(
        (file) => file.filename == _highlightedFileName,
      );
      if (highlightedIndex < 0) {
        return;
      }

      final position = _fileListScrollController.position;
      final targetOffset = resolveSftpHighlightedFileScrollOffset(
        highlightedIndex: highlightedIndex,
        currentOffset: _fileListScrollController.offset,
        itemExtentEstimate: _sftpFileRowExtentEstimate,
        viewportExtent: position.viewportDimension,
        maxScrollExtent: position.maxScrollExtent,
      );
      if ((targetOffset - _fileListScrollController.offset).abs() < 0.5) {
        return;
      }

      unawaited(
        _fileListScrollController.animateTo(
          targetOffset,
          duration: _sftpScrollAnimationDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _queueScrollBreadcrumbTailIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_breadcrumbScrollController.hasClients) {
        return;
      }

      final position = _breadcrumbScrollController.position;
      final targetOffset = position.maxScrollExtent;
      if ((targetOffset - _breadcrumbScrollController.offset).abs() < 0.5) {
        return;
      }

      unawaited(
        _breadcrumbScrollController.animateTo(
          targetOffset,
          duration: _sftpScrollAnimationDuration,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  String? _sanitizeRequestedPath(String? path) {
    final trimmedPath = path?.trim();
    if (trimmedPath == null || trimmedPath.isEmpty) {
      return null;
    }
    return trimmedPath;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _pathHistory.length <= 1,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _pathHistory.length > 1) {
        unawaited(_goBack());
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_hostLabel == null ? 'Files' : 'Files - $_hostLabel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadDirectory(_currentPath),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            onPressed: _showCreateDirectoryDialog,
            tooltip: 'New folder',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildBreadcrumbs(),
          Expanded(child: _buildFileList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showUploadDialog,
        child: const Icon(Icons.upload_file),
      ),
    ),
  );

  Widget _buildBreadcrumbs() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    final theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: _pathHistory.length > 1
                ? () => unawaited(_goBack())
                : null,
            tooltip: 'Back',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: _currentPath != '/'
                ? () => unawaited(_navigateUp())
                : null,
            tooltip: 'Up',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              controller: _breadcrumbScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => unawaited(_navigateTo('/')),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      child: Text('/'),
                    ),
                  ),
                  for (var i = 0; i < parts.length; i++) ...[
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    InkWell(
                      onTap: () {
                        final path = '/${parts.sublist(0, i + 1).join('/')}';
                        unawaited(_navigateTo(path));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Text(
                          parts[i],
                          style: i == parts.length - 1
                              ? TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _connect, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text('Directory is empty'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _loadDirectory(_currentPath);
      },
      child: ListView.builder(
        controller: _fileListScrollController,
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          // Skip . and ..
          if (file.filename == '.' || file.filename == '..') {
            return const SizedBox.shrink();
          }
          return _FileListTile(
            file: file,
            isHighlighted:
                _highlightedDirectoryPath == _currentPath &&
                _highlightedFileName == file.filename,
            onTap: () => _handleFileTap(file),
            onLongPress: () => _showFileOptions(file),
          );
        },
      ),
    );
  }

  void _handleFileTap(SftpName file) {
    switch (resolveSftpFileTapIntent(
      isDirectory: file.attr.isDirectory,
      filename: file.filename,
    )) {
      case SftpFileTapIntent.navigate:
        unawaited(_navigateTo(_joinRemotePath(_currentPath, file.filename)));
      case SftpFileTapIntent.preview:
        unawaited(_previewImageFile(file));
      case SftpFileTapIntent.edit:
        unawaited(_editTextFile(file));
    }
  }

  void _showFileOptions(SftpName file) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              onTap: () {
                Navigator.pop(context);
                _showFileInfo(file);
              },
            ),
            if (!file.attr.isDirectory &&
                isPreviewableImageFileName(file.filename))
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('View'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_previewImageFile(file));
                },
              ),
            if (!file.attr.isDirectory)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_editTextFile(file));
                },
              ),
            if (!file.attr.isDirectory)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_downloadFile(file));
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy as path'),
              onTap: () async {
                Navigator.pop(context);
                await _copyRemotePath(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(file);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(context);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFileInfo(SftpName file) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.filename),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow('Type', file.attr.isDirectory ? 'Directory' : 'File'),
            _InfoRow('Size', formatRemoteFileSize(file.attr.size ?? 0)),
            if (file.attr.modifyTime != null)
              _InfoRow(
                'Modified',
                DateTime.fromMillisecondsSinceEpoch(
                  (file.attr.modifyTime ?? 0) * 1000,
                ).toString().split('.').first,
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateDirectoryDialog() async {
    final controller = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Directory'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Directory name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty && _sftp != null) {
      try {
        await _sftp!.mkdir(_joinRemotePath(_currentPath, name));
        await _loadDirectory(_currentPath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Created "$name"')));
        }
      } on Exception catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Future<void> _showRenameDialog(SftpName file) async {
    final controller = TextEditingController(text: file.filename);

    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && _sftp != null) {
      try {
        await _sftp!.rename(
          _joinRemotePath(_currentPath, file.filename),
          _joinRemotePath(_currentPath, newName),
        );
        await _loadDirectory(_currentPath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Renamed to "$newName"')));
        }
      } on Exception catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Future<void> _deleteFile(SftpName file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${file.filename}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && _sftp != null) {
      try {
        final path = _joinRemotePath(_currentPath, file.filename);
        if (file.attr.isDirectory) {
          await _sftp!.rmdir(path);
        } else {
          await _sftp!.remove(path);
        }
        await _loadDirectory(_currentPath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Deleted "${file.filename}"')));
        }
      } on Exception catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Future<void> _downloadFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save ${file.filename}',
      fileName: file.filename,
    );
    if (savePath == null) {
      return;
    }

    try {
      final remotePath = _joinRemotePath(_currentPath, file.filename);
      await ref
          .read(remoteFileServiceProvider)
          .downloadFile(
            sftp: _sftp!,
            remotePath: remotePath,
            localPath: savePath,
          );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded "${file.filename}"')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  Future<void> _showUploadDialog() async {
    if (_sftp == null) {
      return;
    }

    final pickerRequest = resolveSftpUploadPickerRequest();
    final result = await FilePicker.pickFiles(
      allowMultiple: pickerRequest.allowMultiple,
      withReadStream: pickerRequest.withReadStream,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }

    final selectedFiles = result.files;
    final uploads = <({PlatformFile file, Stream<List<int>>? readStream})>[
      for (final file in selectedFiles)
        (file: file, readStream: resolvePickedSftpUploadReadStream(file)),
    ];
    final unreadableUploads = uploads
        .where((upload) => upload.readStream == null)
        .toList();
    if (unreadableUploads.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              resolveUnreadableSftpUploadMessage([
                for (final upload in unreadableUploads) upload.file,
              ]),
            ),
          ),
        );
      }
      return;
    }

    try {
      final remoteFileService = ref.read(remoteFileServiceProvider);
      for (final upload in uploads) {
        await remoteFileService.uploadStream(
          sftp: _sftp!,
          remotePath: _joinRemotePath(_currentPath, upload.file.name),
          stream: upload.readStream!,
        );
      }
      await _loadDirectory(_currentPath);
      if (mounted) {
        final message = selectedFiles.length == 1
            ? 'Uploaded "${selectedFiles.single.name}"'
            : 'Uploaded ${selectedFiles.length} files';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<void> _copyRemotePath(SftpName file) async {
    final remotePath = _joinRemotePath(_currentPath, file.filename);
    await Clipboard.setData(ClipboardData(text: shellEscapePosix(remotePath)));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied shell-safe path')));
  }

  Future<void> _previewImageFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    if ((file.attr.size ?? 0) > _maxPreviewBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is too large to preview here (max 10 MB)'),
          ),
        );
      }
      return;
    }

    final remotePath = _joinRemotePath(_currentPath, file.filename);
    try {
      final remoteFile = await _sftp!.open(remotePath);
      late final Uint8List bytes;
      try {
        bytes = await remoteFile.readBytes(length: _maxPreviewBytes + 1);
      } finally {
        await remoteFile.close();
      }

      if (bytes.length > _maxPreviewBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File is too large to preview here (max 10 MB)'),
            ),
          );
        }
        return;
      }

      if (!mounted) {
        return;
      }

      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => _RemoteImageViewerScreen(
            fileName: file.filename,
            bytes: bytes,
            isSvg: isSvgFileName(file.filename),
          ),
        ),
      );
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Preview failed: $e')));
    }
  }

  Future<void> _editTextFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    if ((file.attr.size ?? 0) > _maxEditableBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is too large to edit here (max 1 MB)'),
          ),
        );
      }
      return;
    }

    final remotePath = _joinRemotePath(_currentPath, file.filename);
    try {
      final remoteFile = await _sftp!.open(remotePath);
      late final Uint8List bytes;
      try {
        bytes = await remoteFile.readBytes(length: _maxEditableBytes + 1);
      } finally {
        await remoteFile.close();
      }

      if (bytes.length > _maxEditableBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File is too large to edit here (max 1 MB)'),
            ),
          );
        }
        return;
      }

      if (looksLikeBinaryContent(bytes)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Binary files cannot be edited here')),
          );
        }
        return;
      }

      final decodedText = utf8.decode(bytes, allowMalformed: true);
      final detectedLanguage = detectLanguageFromFilename(file.filename);
      final useHighlighting =
          detectedLanguage != null && bytes.length <= syntaxHighlightSizeLimit;

      if (!mounted) {
        return;
      }
      final brightness = Theme.of(context).brightness;
      final navigator = Navigator.of(context);
      final host = await ref
          .read(hostRepositoryProvider)
          .getById(widget.hostId);
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      final preferredConnectionId =
          widget.connectionId ??
          sessionsNotifier.getPreferredConnectionForHost(widget.hostId);
      final session = preferredConnectionId == null
          ? null
          : sessionsNotifier.getSession(preferredConnectionId);
      final terminalThemeSettings = ref.read(terminalThemeSettingsProvider);
      final terminalThemes =
          ref.read(allTerminalThemesProvider).asData?.value ??
          TerminalThemes.all;
      final editorTheme = resolveConnectionPreviewTheme(
        brightness: brightness,
        themeSettings: terminalThemeSettings,
        availableThemes: terminalThemes,
        lightThemeId:
            session?.terminalThemeLightId ?? host?.terminalThemeLightId,
        darkThemeId: session?.terminalThemeDarkId ?? host?.terminalThemeDarkId,
      );
      final fontFamily =
          host?.terminalFontFamily ??
          ref.read(fontFamilyNotifierProvider) ??
          'monospace';
      final initialFontSize =
          session?.terminalFontSize ?? ref.read(fontSizeNotifierProvider) ?? 14;

      final TextEditingController controller;
      if (useHighlighting) {
        final syntaxTheme = buildSyntaxThemeFromTerminal(editorTheme);
        controller = SyntaxHighlightController(
          text: decodedText,
          language: detectedLanguage,
          theme: syntaxTheme,
        );
      } else {
        controller = TextEditingController(text: decodedText);
      }

      if (!mounted) {
        controller.dispose();
        return;
      }
      final updated = await navigator.push<String>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => RemoteTextEditorScreen(
            fileName: file.filename,
            controller: controller,
            terminalTheme: editorTheme,
            fontFamily: fontFamily,
            initialFontSize: initialFontSize,
          ),
        ),
      );
      controller.dispose();
      if (updated == null) {
        return;
      }

      final saveFile = await _sftp!.open(
        remotePath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await saveFile.writeBytes(Uint8List.fromList(utf8.encode(updated)));
      } finally {
        await saveFile.close();
      }
      await _loadDirectory(_currentPath);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved "${file.filename}"')));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
      }
    }
  }

  String _joinRemotePath(String directory, String name) =>
      joinRemotePath(directory, name);
}

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.file,
    required this.onTap,
    required this.onLongPress,
    this.isHighlighted = false,
  });

  final SftpName file;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirectory = file.attr.isDirectory;
    final iconColor = isHighlighted
        ? theme.colorScheme.onPrimaryContainer
        : isDirectory
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final trailingIconColor = isHighlighted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minVerticalPadding: 2,
      minLeadingWidth: 32,
      tileColor: isHighlighted ? theme.colorScheme.primaryContainer : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(
        isDirectory ? Icons.folder : _getFileIcon(file.filename),
        color: iconColor,
      ),
      title: Text(
        file.filename,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isHighlighted
            ? theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              )
            : null,
      ),
      subtitle: isDirectory
          ? null
          : Text(
              formatRemoteFileSize(file.attr.size ?? 0),
              style: isHighlighted
                  ? theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    )
                  : theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: isDirectory
          ? Icon(Icons.chevron_right, size: 20, color: trailingIconColor)
          : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  IconData _getFileIcon(String filename) {
    if (isPreviewableImageFileName(filename)) {
      return Icons.image;
    }
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'txt' || 'md' || 'log' => Icons.description,
      'pdf' => Icons.picture_as_pdf,
      'mp3' || 'wav' || 'flac' => Icons.audio_file,
      'mp4' || 'mov' || 'avi' => Icons.video_file,
      'zip' || 'tar' || 'gz' || 'rar' => Icons.archive,
      'sh' || 'bash' => Icons.terminal,
      'py' || 'js' || 'dart' || 'java' || 'go' => Icons.code,
      'json' || 'yaml' || 'yml' || 'xml' => Icons.data_object,
      _ => Icons.insert_drive_file,
    };
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _RemoteImageViewerScreen extends StatelessWidget {
  const _RemoteImageViewerScreen({
    required this.fileName,
    required this.bytes,
    required this.isSvg,
  });

  final String fileName;
  final Uint8List bytes;
  final bool isSvg;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: Text(fileName)),
    body: InteractiveViewer(
      maxScale: 8,
      minScale: 0.5,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: isSvg
              ? Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: SvgPicture.memory(bytes),
                )
              : Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Text(
                    'Could not render image preview',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                  ),
                ),
        ),
      ),
    ),
  );
}
