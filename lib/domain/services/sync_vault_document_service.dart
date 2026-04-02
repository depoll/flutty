import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Result of selecting an existing encrypted sync vault document.
class PickedSyncVaultDocument {
  /// Creates a new [PickedSyncVaultDocument].
  const PickedSyncVaultDocument({
    required this.contents,
    required this.path,
    required this.bookmark,
  });

  /// Full encrypted vault contents.
  final String contents;

  /// Provider-backed file path returned by the native iOS document picker.
  final String path;

  /// Security-scoped bookmark for reopening the document across launches.
  final String bookmark;
}

/// Result of creating a new encrypted sync vault document.
class SavedSyncVaultDocument {
  /// Creates a new [SavedSyncVaultDocument].
  const SavedSyncVaultDocument({required this.path, required this.bookmark});

  /// Provider-backed file path returned by the native iOS document picker.
  final String path;

  /// Security-scoped bookmark for reopening the document across launches.
  final String bookmark;
}

/// Accesses iOS-native sync-vault document pickers.
class SyncVaultDocumentService {
  static const _channel = MethodChannel(
    'xyz.depollsoft.monkeyssh/sync_vault_document',
  );

  /// Creates a new cloud-backed encrypted sync vault document on iOS.
  ///
  /// Returns `null` when the user cancels the picker, or when the current
  /// platform should fall back to generic file-picking behavior.
  Future<SavedSyncVaultDocument?> createLinkedVault({
    required String encryptedVault,
    required String suggestedFileName,
  }) async {
    if (!_shouldUseNativeIosDocumentPicker) {
      return null;
    }

    final result = await _invokeOptionalMap(
      'createLinkedVault',
      <String, Object?>{
        'encryptedVault': encryptedVault,
        'suggestedFileName': suggestedFileName,
      },
    );
    if (result == null) {
      return null;
    }

    return SavedSyncVaultDocument(
      path: _requiredString(result, 'path'),
      bookmark: _requiredString(result, 'bookmark'),
    );
  }

  /// Opens an existing cloud-backed encrypted sync vault document on iOS.
  ///
  /// Returns `null` when the user cancels the picker, or when the current
  /// platform should fall back to generic file-picking behavior.
  Future<PickedSyncVaultDocument?> pickLinkedVault() async {
    if (!_shouldUseNativeIosDocumentPicker) {
      return null;
    }

    final result = await _invokeOptionalMap('pickLinkedVault');
    if (result == null) {
      return null;
    }

    return PickedSyncVaultDocument(
      contents: _requiredString(result, 'contents'),
      path: _requiredString(result, 'path'),
      bookmark: _requiredString(result, 'bookmark'),
    );
  }

  /// Reads the current encrypted sync vault contents using a stored bookmark.
  Future<PickedSyncVaultDocument> readLinkedVault({
    required String bookmark,
  }) async {
    if (!_shouldUseNativeIosDocumentPicker) {
      throw const FileSystemException('Could not access the linked sync vault');
    }

    final result = await _invokeOptionalMap(
      'readLinkedVault',
      <String, Object?>{'bookmark': bookmark},
    );
    if (result == null) {
      throw const FileSystemException('Could not access the linked sync vault');
    }

    return PickedSyncVaultDocument(
      contents: _requiredString(result, 'contents'),
      path: _requiredString(result, 'path'),
      bookmark: _requiredString(result, 'bookmark'),
    );
  }

  /// Writes encrypted sync vault contents using a stored bookmark.
  Future<SavedSyncVaultDocument> writeLinkedVault({
    required String bookmark,
    required String encryptedVault,
  }) async {
    if (!_shouldUseNativeIosDocumentPicker) {
      throw const FileSystemException('Could not access the linked sync vault');
    }

    final result = await _invokeOptionalMap(
      'writeLinkedVault',
      <String, Object?>{'bookmark': bookmark, 'encryptedVault': encryptedVault},
    );
    if (result == null) {
      throw const FileSystemException('Could not access the linked sync vault');
    }

    return SavedSyncVaultDocument(
      path: _requiredString(result, 'path'),
      bookmark: _requiredString(result, 'bookmark'),
    );
  }

  bool get _shouldUseNativeIosDocumentPicker =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<Map<Object?, Object?>?> _invokeOptionalMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
    } on PlatformException catch (error) {
      throw _translatePlatformException(error);
    } on MissingPluginException {
      throw const FileSystemException('Could not access the linked sync vault');
    }
  }

  Exception _translatePlatformException(
    PlatformException error,
  ) => switch (error.code) {
    'invalid_extension' => const FormatException(
      'Select a .monkeysync sync vault file',
    ),
    'file_too_large' => const FormatException('Sync vault file is too large'),
    'invalid_format' => const FormatException('Invalid sync vault file format'),
    _ => FileSystemException(
      error.message ?? 'Could not access the linked sync vault',
    ),
  };

  String _requiredString(Map<Object?, Object?> result, String key) {
    final value = result[key];
    if (value is! String || value.isEmpty) {
      throw const FileSystemException('Could not access the linked sync vault');
    }
    return value;
  }
}

/// Provider for [SyncVaultDocumentService].
final syncVaultDocumentServiceProvider = Provider<SyncVaultDocumentService>(
  (ref) => SyncVaultDocumentService(),
);
