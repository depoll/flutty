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

import '../../domain/services/remote_file_service.dart';
import '../../domain/services/ssh_service.dart';

const _maxEditableBytes = 1024 * 1024;
const _maxPreviewBytes = 10 * 1024 * 1024;

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

/// SFTP file browser screen.
class SftpScreen extends ConsumerStatefulWidget {
  /// Creates a new [SftpScreen].
  const SftpScreen({required this.hostId, this.connectionId, super.key});

  /// The host ID to connect to.
  final int hostId;

  /// Optional existing connection ID to reuse.
  final int? connectionId;

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
  String? _hostLabel;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
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
      await _loadDirectory(initialPath, nextHistory: [initialPath]);
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

  Future<void> _loadDirectory(String path, {List<String>? nextHistory}) async {
    if (_sftp == null) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final items = await _sftp!.listdir(path);
      if (!mounted) {
        return;
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
        _isLoading = false;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = 'Failed to list directory: $e';
      });
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
            onTap: () => _handleFileTap(file),
            onLongPress: () => _showFileOptions(file),
          );
        },
      ),
    );
  }

  void _handleFileTap(SftpName file) {
    if (file.attr.isDirectory) {
      unawaited(_navigateTo(_joinRemotePath(_currentPath, file.filename)));
    } else if (isPreviewableImageFileName(file.filename)) {
      unawaited(_previewImageFile(file));
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

    final savePath = await FilePicker.platform.saveFile(
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
      await ref
          .read(remoteFileServiceProvider)
          .uploadStream(
            sftp: _sftp!,
            remotePath: remotePath,
            stream: readStream,
          );
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

      final controller = TextEditingController(
        text: utf8.decode(bytes, allowMalformed: true),
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      final updated = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => _RemoteTextEditorScreen(
            fileName: file.filename,
            controller: controller,
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
  });

  final SftpName file;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirectory = file.attr.isDirectory;

    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minVerticalPadding: 2,
      minLeadingWidth: 32,
      leading: Icon(
        isDirectory ? Icons.folder : _getFileIcon(file.filename),
        color: isDirectory
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(file.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: isDirectory
          ? null
          : Text(
              formatRemoteFileSize(file.attr.size ?? 0),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: isDirectory ? const Icon(Icons.chevron_right, size: 20) : null,
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

class _RemoteTextEditorScreen extends StatefulWidget {
  const _RemoteTextEditorScreen({
    required this.fileName,
    required this.controller,
  });

  final String fileName;
  final TextEditingController controller;

  @override
  State<_RemoteTextEditorScreen> createState() =>
      _RemoteTextEditorScreenState();
}

class _RemoteTextEditorScreenState extends State<_RemoteTextEditorScreen> {
  bool _wrapLines = false;
  final ScrollController _horizontalScrollController = ScrollController();

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editor = TextField(
      controller: widget.controller,
      autofocus: true,
      expands: true,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: const InputDecoration(
        border: InputBorder.none,
        isCollapsed: true,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('Edit ${widget.fileName}'),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _wrapLines = !_wrapLines;
              });
            },
            icon: const Icon(Icons.wrap_text),
            tooltip: _wrapLines ? 'Disable line wrap' : 'Enable line wrap',
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, widget.controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox.expand(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: theme.colorScheme.outline),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (_wrapLines) {
                    return editor;
                  }

                  return ClipRect(
                    child: Scrollbar(
                      controller: _horizontalScrollController,
                      thumbVisibility: true,
                      notificationPredicate: (notification) =>
                          notification.metrics.axis == Axis.horizontal,
                      child: SingleChildScrollView(
                        controller: _horizontalScrollController,
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth,
                          ),
                          child: IntrinsicWidth(
                            child: SizedBox(
                              height: constraints.maxHeight,
                              child: editor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
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
