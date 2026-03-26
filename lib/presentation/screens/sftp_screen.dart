import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/ssh_service.dart';

/// Normalizes an absolute remote path by collapsing `.`, `..`, and extra `/`.
@visibleForTesting
String? normalizeSftpAbsolutePath(String? path) {
  final trimmedPath = path?.trim();
  if (trimmedPath == null ||
      trimmedPath.isEmpty ||
      !trimmedPath.startsWith('/')) {
    return null;
  }

  final segments = <String>[];
  for (final segment in trimmedPath.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }

  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

/// Joins a remote directory and child path using POSIX separators.
@visibleForTesting
String joinSftpPath(String directory, String name) {
  if (directory == '/') {
    return '/$name';
  }
  return '$directory/$name';
}

/// Resolves a requested SFTP path against terminal context.
@visibleForTesting
String? resolveRequestedSftpPath(
  String? requestedPath, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  final trimmedPath = requestedPath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) {
    return null;
  }

  if (trimmedPath.startsWith('/')) {
    return normalizeSftpAbsolutePath(trimmedPath);
  }

  if (trimmedPath == '~' || trimmedPath.startsWith('~/')) {
    final normalizedHomeDirectory = normalizeSftpAbsolutePath(homeDirectory);
    if (normalizedHomeDirectory == null) {
      return null;
    }
    if (trimmedPath == '~') {
      return normalizedHomeDirectory;
    }
    return normalizeSftpAbsolutePath(
      joinSftpPath(normalizedHomeDirectory, trimmedPath.substring(2)),
    );
  }

  final normalizedWorkingDirectory = normalizeSftpAbsolutePath(
    workingDirectory,
  );
  if (normalizedWorkingDirectory == null) {
    return null;
  }

  return normalizeSftpAbsolutePath(
    joinSftpPath(normalizedWorkingDirectory, trimmedPath),
  );
}

/// SFTP file browser screen.
class SftpScreen extends ConsumerStatefulWidget {
  /// Creates a new [SftpScreen].
  const SftpScreen({
    required this.hostId,
    this.initialPath,
    this.initialWorkingDirectory,
    super.key,
  });

  /// The host ID to connect to.
  final int hostId;

  /// Optional remote path to open when the browser loads.
  final String? initialPath;

  /// Optional terminal working directory used to resolve relative paths.
  final String? initialWorkingDirectory;

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  SftpClient? _sftp;
  String _currentPath = '/';
  List<SftpName> _files = [];
  bool _isLoading = true;
  String? _error;
  final List<String> _pathHistory = ['/'];
  String? _pendingInitialPath;
  String? _highlightedDirectoryPath;
  String? _highlightedFileName;
  String? _homeDirectoryPath;

  @override
  void initState() {
    super.initState();
    _pendingInitialPath = _sanitizeRequestedPath(widget.initialPath);
    _connect();
  }

  @override
  void didUpdateWidget(covariant SftpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    final nextInitialPath = _sanitizeRequestedPath(widget.initialPath);
    if (oldWidget.initialPath == widget.initialPath &&
        oldWidget.initialWorkingDirectory == widget.initialWorkingDirectory) {
      return;
    }

    _pendingInitialPath = nextInitialPath;
    if (_sftp != null && nextInitialPath != null) {
      unawaited(_openRequestedPath(nextInitialPath));
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
      var connectionId = sessionsNotifier.getPreferredConnectionForHost(
        widget.hostId,
      );
      var session = connectionId == null
          ? null
          : sessionsNotifier.getSession(connectionId);

      // Connect if not already connected
      if (session == null) {
        final result = await sessionsNotifier.connect(widget.hostId);
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
        setState(() {
          _isLoading = false;
          _error = 'Session not found';
        });
        return;
      }

      await sessionsNotifier.syncBackgroundStatus();
      _sftp = await session.sftp();
      final requestedPath = _pendingInitialPath;
      if (requestedPath != null) {
        _pendingInitialPath = null;
        await _openRequestedPath(requestedPath);
        return;
      }
      if (await _loadDirectory(_currentPath)) {
        return;
      }
      final homeDirectoryPath = await _resolveHomeDirectoryPath();
      if (homeDirectoryPath != null &&
          await _loadDirectory(homeDirectoryPath, showError: false)) {
        _replacePathHistory(homeDirectoryPath);
        return;
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Failed to open SFTP browser';
        });
      }
    } on Exception catch (e) {
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
        await _sftp!.absolute('.'),
      );
      if (resolvedPath != null) {
        _homeDirectoryPath = resolvedPath;
      }
      return resolvedPath;
    } on Exception {
      return null;
    }
  }

  Future<void> _openFallbackDirectory() async {
    final candidatePaths = <String>[];

    void addCandidate(String? path) {
      final normalizedPath = normalizeSftpAbsolutePath(path);
      if (normalizedPath == null || candidatePaths.contains(normalizedPath)) {
        return;
      }
      candidatePaths.add(normalizedPath);
    }

    addCandidate(widget.initialWorkingDirectory);
    addCandidate(_currentPath);
    addCandidate(await _resolveHomeDirectoryPath());
    addCandidate('/');

    for (final candidatePath in candidatePaths) {
      if (await _loadDirectory(candidatePath, showError: false)) {
        _replacePathHistory(candidatePath);
        _pendingInitialPath = null;
        return;
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
        _error = 'Failed to open SFTP browser';
      });
    }
  }

  Future<bool> _loadDirectory(String path, {bool showError = true}) async {
    if (_sftp == null) {
      return false;
    }

    setState(() => _isLoading = true);

    try {
      final items = await _sftp!.listdir(path);
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
        _isLoading = false;
        _error = null;
        if (_highlightedDirectoryPath != path) {
          _highlightedDirectoryPath = null;
          _highlightedFileName = null;
        }
      });
      return true;
    } on Exception catch (e) {
      setState(() {
        _isLoading = false;
        if (showError) {
          _error = 'Failed to list directory: $e';
        }
      });
      return false;
    }
  }

  void _navigateTo(String path) {
    _pathHistory.add(path);
    _loadDirectory(path);
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    final parts = _currentPath.split('/')..removeLast();
    final parentPath = parts.isEmpty ? '/' : parts.join('/');
    _pathHistory.add(parentPath);
    _loadDirectory(parentPath);
  }

  void _goBack() {
    if (_pathHistory.length > 1) {
      _pathHistory.removeLast();
      final previousPath = _pathHistory.last;
      _loadDirectory(previousPath);
    }
  }

  Future<bool> _openRequestedPath(String requestedPath) async {
    final normalizedPath = resolveRequestedSftpPath(
      requestedPath,
      workingDirectory: widget.initialWorkingDirectory,
      homeDirectory: await _resolveHomeDirectoryPath(),
    );
    if (normalizedPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not resolve "$requestedPath" in SFTP')),
        );
      }
      await _openFallbackDirectory();
      return false;
    }

    if (await _loadDirectory(normalizedPath, showError: false)) {
      _replacePathHistory(normalizedPath);
      return true;
    }

    final parentPath = _parentRemotePath(normalizedPath);
    final fileName = _basename(normalizedPath);
    if (parentPath == null || fileName == null) {
      await _openFallbackDirectory();
      return false;
    }

    if (await _loadDirectory(parentPath, showError: false)) {
      _replacePathHistory(parentPath);
      if (!mounted) {
        return true;
      }
      setState(() {
        _highlightedDirectoryPath = parentPath;
        _highlightedFileName = fileName;
      });
      return true;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open "$normalizedPath" in SFTP')),
      );
    }
    await _openFallbackDirectory();
    return false;
  }

  void _replacePathHistory(String path) {
    if (!mounted) {
      _pathHistory
        ..clear()
        ..add(path);
      return;
    }

    setState(() {
      _pathHistory
        ..clear()
        ..add(path);
    });
  }

  String? _sanitizeRequestedPath(String? path) {
    if (path == null) {
      return null;
    }

    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      return null;
    }
    return trimmedPath;
  }

  String? _parentRemotePath(String path) {
    final normalizedPath = normalizeSftpAbsolutePath(path);
    if (normalizedPath == null || normalizedPath == '/') {
      return null;
    }

    final lastSlash = normalizedPath.lastIndexOf('/');
    if (lastSlash <= 0) {
      return '/';
    }
    return normalizedPath.substring(0, lastSlash);
  }

  String? _basename(String path) {
    final normalizedPath = normalizeSftpAbsolutePath(path);
    if (normalizedPath == null || normalizedPath == '/') {
      return null;
    }

    final lastSlash = normalizedPath.lastIndexOf('/');
    if (lastSlash < 0 || lastSlash == normalizedPath.length - 1) {
      return null;
    }
    return normalizedPath.substring(lastSlash + 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('SFTP Browser'),
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
        // Breadcrumb navigation
        _buildBreadcrumbs(),
        // File list
        Expanded(child: _buildFileList()),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _showUploadDialog,
      child: const Icon(Icons.upload_file),
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
            onPressed: _pathHistory.length > 1 ? _goBack : null,
            tooltip: 'Back',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: _currentPath != '/' ? _navigateUp : null,
            tooltip: 'Up',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _loadDirectory('/'),
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
                        _loadDirectory(path);
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
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.builder(
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
    if (file.attr.isDirectory) {
      _navigateTo(_joinRemotePath(_currentPath, file.filename));
    } else {
      _showFileOptions(file);
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
            _InfoRow('Size', _formatSize(file.attr.size ?? 0)),
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

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save ${file.filename}',
      fileName: file.filename,
    );
    if (savePath == null) {
      return;
    }

    try {
      final remotePath = _joinRemotePath(_currentPath, file.filename);
      final remoteFile = await _sftp!.open(remotePath);
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in remoteFile.read()) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
        await remoteFile.close();
      }

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

    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null || result.files.isEmpty) {
      return;
    }

    final file = result.files.single;
    final readStream =
        file.readStream ??
        (file.path == null ? null : File(file.path!).openRead());
    if (readStream == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to read selected file')),
        );
      }
      return;
    }

    try {
      final remotePath = _joinRemotePath(_currentPath, file.name);
      final remoteFile = await _sftp!.open(
        remotePath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await remoteFile
            .write(
              readStream.map(
                (chunk) =>
                    chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
              ),
            )
            .done;
      } finally {
        await remoteFile.close();
      }
      await _loadDirectory(_currentPath);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Uploaded "${file.name}"')));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<void> _editTextFile(SftpName file) async {
    if (_sftp == null) {
      return;
    }

    const maxEditableBytes = 1024 * 1024;
    if ((file.attr.size ?? 0) > maxEditableBytes) {
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
        bytes = await remoteFile.readBytes(length: maxEditableBytes + 1);
      } finally {
        await remoteFile.close();
      }

      if (bytes.length > maxEditableBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File is too large to edit here (max 1 MB)'),
            ),
          );
        }
        return;
      }

      if (_looksBinary(bytes)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Binary files cannot be edited here')),
          );
        }
        return;
      }

      final controller = TextEditingController(
        text: utf8.decode(bytes, allowMalformed: true),
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      final updated = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Edit ${file.filename}'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 20,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save'),
            ),
          ],
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
      joinSftpPath(directory, name);

  bool _looksBinary(Uint8List bytes) {
    final sample = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
    return sample.contains(0);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.file,
    required this.isHighlighted,
    required this.onTap,
    required this.onLongPress,
  });

  final SftpName file;
  final bool isHighlighted;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirectory = file.attr.isDirectory;

    return ListTile(
      leading: Icon(
        isDirectory ? Icons.folder : _getFileIcon(file.filename),
        color: isDirectory
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      selected: isHighlighted,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      title: Text(file.filename),
      subtitle: isDirectory
          ? null
          : Text(
              _formatSize(file.attr.size ?? 0),
              style: theme.textTheme.bodySmall,
            ),
      trailing: isDirectory ? const Icon(Icons.chevron_right, size: 20) : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  IconData _getFileIcon(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'txt' || 'md' || 'log' => Icons.description,
      'pdf' => Icons.picture_as_pdf,
      'jpg' || 'jpeg' || 'png' || 'gif' => Icons.image,
      'mp3' || 'wav' || 'flac' => Icons.audio_file,
      'mp4' || 'mov' || 'avi' => Icons.video_file,
      'zip' || 'tar' || 'gz' || 'rar' => Icons.archive,
      'sh' || 'bash' => Icons.terminal,
      'py' || 'js' || 'dart' || 'java' || 'go' => Icons.code,
      'json' || 'yaml' || 'yml' || 'xml' => Icons.data_object,
      _ => Icons.insert_drive_file,
    };
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
