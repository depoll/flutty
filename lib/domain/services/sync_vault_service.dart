import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'secure_transfer_service.dart';
import 'settings_service.dart';
import 'sync_vault_file_io.dart';

/// Conflict resolution choices when both local and remote sync vault data changed.
enum SyncVaultConflictResolution {
  /// Upload this device's local data to the encrypted sync vault.
  uploadLocal,

  /// Download the encrypted sync vault data and replace the local sync scope.
  downloadRemote,
}

/// High-level outcomes for a sync vault operation.
enum SyncVaultSyncOutcome {
  /// Sync is disabled on this device.
  disabled,

  /// The linked vault file needs to be reselected or recreated.
  needsRelink,

  /// No syncable changes were detected.
  noChanges,

  /// Local data was uploaded to the encrypted sync vault.
  uploadedLocal,

  /// Remote vault data was downloaded and applied locally.
  downloadedRemote,

  /// Both local and remote data changed since the last shared baseline.
  conflict,
}

/// Saved status for the optional encrypted sync vault feature.
class SyncVaultStatus {
  /// Creates a new [SyncVaultStatus].
  const SyncVaultStatus({
    required this.enabled,
    required this.hasRecoveryKey,
    this.filePath,
    this.lastSyncedAt,
    this.lastError,
  });

  /// Whether encrypted sync is enabled on this device.
  final bool enabled;

  /// Whether the local device still has recovery material cached securely.
  final bool hasRecoveryKey;

  /// Full path of the linked sync vault file, if configured.
  final String? filePath;

  /// Time of the last successful sync on this device.
  final DateTime? lastSyncedAt;

  /// Most recent sync-related error stored for the device.
  final String? lastError;

  /// Filename of the linked sync vault, if available.
  String? get fileName =>
      filePath == null || filePath!.isEmpty ? null : p.basename(filePath!);
}

/// Result of preparing a new encrypted sync vault for initial setup.
class SyncVaultProvisioning {
  /// Creates a new [SyncVaultProvisioning].
  const SyncVaultProvisioning({
    required this.recoveryKey,
    required this.encryptedVault,
    required this.snapshotHash,
    required this.updatedAt,
  });

  /// Recovery key the user must keep to enroll other devices or recover access.
  final String recoveryKey;

  /// Serialized encrypted sync vault contents to save into a file.
  final String encryptedVault;

  /// Canonical hash of the sync snapshot stored in the vault.
  final String snapshotHash;

  /// Timestamp associated with the prepared snapshot.
  final DateTime updatedAt;
}

/// Result of a sync attempt against the encrypted sync vault.
class SyncVaultSyncResult {
  /// Creates a new [SyncVaultSyncResult].
  const SyncVaultSyncResult({
    required this.outcome,
    required this.message,
    this.localUpdatedAt,
    this.remoteUpdatedAt,
    this.localPreview,
    this.remotePreview,
  });

  /// Outcome category for the sync attempt.
  final SyncVaultSyncOutcome outcome;

  /// Human-readable summary suitable for UI feedback.
  final String message;

  /// Local snapshot timestamp involved in the decision, if any.
  final DateTime? localUpdatedAt;

  /// Remote snapshot timestamp involved in the decision, if any.
  final DateTime? remoteUpdatedAt;

  /// Local snapshot preview counts, if relevant.
  final MigrationPreview? localPreview;

  /// Remote snapshot preview counts, if relevant.
  final MigrationPreview? remotePreview;
}

class _SyncVaultSnapshot {
  const _SyncVaultSnapshot({
    required this.schemaVersion,
    required this.updatedAt,
    required this.updatedByDeviceId,
    required this.snapshotHash,
    required this.data,
  });

  factory _SyncVaultSnapshot.fromJson(Map<String, dynamic> json) {
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final updatedByDeviceId = json['updatedByDeviceId'] as String?;
    final snapshotHash = json['snapshotHash'] as String?;
    final rawData = json['data'];
    if (updatedAt == null ||
        updatedByDeviceId == null ||
        updatedByDeviceId.isEmpty ||
        snapshotHash == null ||
        snapshotHash.isEmpty ||
        rawData is! Map) {
      throw const FormatException('Invalid sync vault payload');
    }

    return _SyncVaultSnapshot(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      updatedAt: updatedAt,
      updatedByDeviceId: updatedByDeviceId,
      snapshotHash: snapshotHash,
      data: Map<String, dynamic>.from(rawData),
    );
  }

  final int schemaVersion;
  final DateTime updatedAt;
  final String updatedByDeviceId;
  final String snapshotHash;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'updatedByDeviceId': updatedByDeviceId,
    'snapshotHash': snapshotHash,
    'data': data,
  };
}

class _CanonicalRecords {
  const _CanonicalRecords({
    required this.records,
    required this.signaturesById,
  });

  final List<Map<String, dynamic>> records;
  final Map<int, String> signaturesById;
}

class _CanonicalHosts {
  const _CanonicalHosts({
    required this.records,
    required this.baseSignaturesById,
  });

  final List<Map<String, dynamic>> records;
  final Map<int, String> baseSignaturesById;
}

/// Service for optional end-to-end encrypted sync via a user-managed vault file.
class SyncVaultService {
  /// Creates a new [SyncVaultService].
  SyncVaultService(
    this._settings,
    this._transferService, {
    FlutterSecureStorage? storage,
    AesGcm? algorithm,
    Random? random,
    Uuid? uuid,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _algorithm = algorithm ?? AesGcm.with256bits(),
       _random = random ?? Random.secure(),
       _uuid = uuid ?? const Uuid();

  final SettingsService _settings;
  final SecureTransferService _transferService;
  final FlutterSecureStorage _storage;
  final AesGcm _algorithm;
  final Random _random;
  final Uuid _uuid;
  final _sha256 = Sha256();

  static const _storageRecoveryKey = 'monkeyssh_sync_vault_recovery_key_v1';
  static const _vaultPrefix = 'MSYNC1:';
  static const _schemaVersion = 1;
  static const _envelopeVersion = 1;
  static const _recoverySeedBytes = 20;
  static const _nonceBytes = 12;

  static const Set<String> _syncedSettingsKeys = {
    SettingKeys.themeMode,
    SettingKeys.terminalFont,
    SettingKeys.terminalFontSize,
    SettingKeys.defaultTerminalThemeLight,
    SettingKeys.defaultTerminalThemeDark,
    SettingKeys.customTerminalThemes,
    SettingKeys.cursorStyle,
    SettingKeys.bellSound,
    SettingKeys.hapticFeedback,
    SettingKeys.keyboardToolbar,
    SettingKeys.autoReconnect,
    SettingKeys.keepAliveInterval,
    SettingKeys.defaultPort,
    SettingKeys.defaultUsername,
  };

  /// Returns the current encrypted sync vault status for the device.
  Future<SyncVaultStatus> getStatus() async {
    final enabled = await _settings.getBool(SettingKeys.syncVaultEnabled);
    final filePath = await _settings.getString(SettingKeys.syncVaultPath);
    final lastSyncedRaw = await _settings.getString(
      SettingKeys.syncVaultLastSyncedAt,
    );
    final lastError = await _settings.getString(SettingKeys.syncVaultLastError);
    final recoveryKey = await _storage.read(key: _storageRecoveryKey);

    return SyncVaultStatus(
      enabled: enabled,
      hasRecoveryKey: recoveryKey != null && recoveryKey.isNotEmpty,
      filePath: filePath,
      lastSyncedAt: DateTime.tryParse(lastSyncedRaw ?? ''),
      lastError: lastError,
    );
  }

  /// Generates a new encrypted sync vault and recovery key for first-time setup.
  Future<SyncVaultProvisioning> prepareNewVault() async {
    final recoverySeed = _randomBytes(_recoverySeedBytes);
    final recoveryKey = _formatRecoveryKey(recoverySeed);
    final deviceId = await _getOrCreateDeviceId();
    final snapshot = await _createSnapshot(deviceId: deviceId);
    final encryptedVault = await _encryptSnapshot(
      snapshot: snapshot,
      recoverySeed: recoverySeed,
    );

    return SyncVaultProvisioning(
      recoveryKey: recoveryKey,
      encryptedVault: encryptedVault,
      snapshotHash: snapshot.snapshotHash,
      updatedAt: snapshot.updatedAt,
    );
  }

  /// Persists local enrollment after a newly created vault file is saved.
  Future<void> enablePreparedVault({
    required String vaultPath,
    required SyncVaultProvisioning provisioning,
  }) async {
    await _storage.write(
      key: _storageRecoveryKey,
      value: _normalizeRecoveryKey(provisioning.recoveryKey),
    );
    await _settings.setString(SettingKeys.syncVaultPath, vaultPath);
    await _settings.setBool(SettingKeys.syncVaultEnabled, value: true);
    await _settings.setString(
      SettingKeys.syncVaultLastSnapshotHash,
      provisioning.snapshotHash,
    );
    await _settings.setString(
      SettingKeys.syncVaultLastSyncedAt,
      provisioning.updatedAt.toUtc().toIso8601String(),
    );
    await _settings.delete(SettingKeys.syncVaultLastError);
    await _getOrCreateDeviceId();
  }

  /// Enrolls this device into an existing encrypted sync vault.
  Future<void> linkExistingVault({
    required String vaultPath,
    required String encryptedVault,
    required String recoveryKey,
  }) async {
    final normalizedRecoveryKey = _normalizeRecoveryKey(recoveryKey);
    final recoverySeed = _parseRecoveryKey(normalizedRecoveryKey);
    await _decryptVault(encryptedVault, recoverySeed: recoverySeed);
    await _storage.write(
      key: _storageRecoveryKey,
      value: normalizedRecoveryKey,
    );
    await _settings.setString(SettingKeys.syncVaultPath, vaultPath);
    await _settings.setBool(SettingKeys.syncVaultEnabled, value: true);
    await _settings.delete(SettingKeys.syncVaultLastSnapshotHash);
    await _settings.delete(SettingKeys.syncVaultLastSyncedAt);
    await _settings.delete(SettingKeys.syncVaultLastError);
    await _getOrCreateDeviceId();
  }

  /// Updates the linked sync vault file path after verifying it can be opened.
  Future<void> relinkVault({
    required String vaultPath,
    required String encryptedVault,
  }) async {
    final recoveryKey = await _readStoredRecoveryKey();
    if (recoveryKey == null) {
      throw const FormatException(
        'Recovery key is not available on this device',
      );
    }
    final recoverySeed = _parseRecoveryKey(recoveryKey);
    await _decryptVault(encryptedVault, recoverySeed: recoverySeed);
    await _settings.setString(SettingKeys.syncVaultPath, vaultPath);
    await _settings.delete(SettingKeys.syncVaultLastError);
  }

  /// Returns the locally cached recovery key in display format.
  Future<String> getRecoveryKey() async {
    final recoveryKey = await _readStoredRecoveryKey();
    if (recoveryKey == null) {
      throw const FormatException(
        'Recovery key is not available on this device',
      );
    }
    return _displayRecoveryKey(recoveryKey);
  }

  /// Disables encrypted sync on this device without deleting local app data.
  Future<void> disableSync() async {
    await _storage.delete(key: _storageRecoveryKey);
    await _settings.delete(SettingKeys.syncVaultEnabled);
    await _settings.delete(SettingKeys.syncVaultPath);
    await _settings.delete(SettingKeys.syncVaultLastSyncedAt);
    await _settings.delete(SettingKeys.syncVaultLastSnapshotHash);
    await _settings.delete(SettingKeys.syncVaultLastError);
  }

  /// Runs a manual sync against the linked encrypted sync vault.
  Future<SyncVaultSyncResult> syncNow({
    SyncVaultConflictResolution? resolution,
  }) async {
    final status = await getStatus();
    if (!status.enabled) {
      return const SyncVaultSyncResult(
        outcome: SyncVaultSyncOutcome.disabled,
        message: 'Encrypted sync is disabled on this device',
      );
    }

    final vaultPath = status.filePath;
    if (vaultPath == null || vaultPath.isEmpty) {
      return const SyncVaultSyncResult(
        outcome: SyncVaultSyncOutcome.needsRelink,
        message: 'Select the encrypted sync vault file again',
      );
    }

    final recoveryKey = await _readStoredRecoveryKey();
    if (recoveryKey == null) {
      return _storeFailureResult(
        const SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.needsRelink,
          message: 'Recovery key is not available on this device',
        ),
      );
    }

    try {
      final recoverySeed = _parseRecoveryKey(recoveryKey);
      final deviceId = await _getOrCreateDeviceId();
      final localSnapshot = await _createSnapshot(deviceId: deviceId);
      final localPreview = _transferService.previewMigrationData(
        localSnapshot.data,
        includeKnownHosts: false,
      );
      final localHasData = _hasPreviewData(localPreview);
      final lastSyncedHash = await _settings.getString(
        SettingKeys.syncVaultLastSnapshotHash,
      );

      final vaultFile = File(vaultPath);
      // ignore: avoid_slow_async_io
      if (!await vaultFile.exists()) {
        return _storeFailureResult(
          const SyncVaultSyncResult(
            outcome: SyncVaultSyncOutcome.needsRelink,
            message: 'The linked sync vault file is missing',
          ),
        );
      }

      final vaultLength = await vaultFile.length();
      if (vaultLength > maxSyncVaultBytes) {
        return _storeFailureResult(
          const SyncVaultSyncResult(
            outcome: SyncVaultSyncOutcome.needsRelink,
            message:
                'The linked sync vault file is too large and needs to be relinked',
          ),
        );
      }

      final encryptedVault = await vaultFile.readAsString();
      if (encryptedVault.trim().isEmpty) {
        final uploadedVault = await _encryptSnapshot(
          snapshot: localSnapshot,
          recoverySeed: recoverySeed,
        );
        await _writeVaultAtomically(vaultFile, uploadedVault);
        await _recordSuccessfulSync(
          snapshotHash: localSnapshot.snapshotHash,
          syncedAt: localSnapshot.updatedAt,
        );
        return const SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.uploadedLocal,
          message: 'Uploaded this device data into the encrypted sync vault',
        );
      }

      final remoteSnapshot = await _decryptVault(
        encryptedVault,
        recoverySeed: recoverySeed,
      );
      final remotePreview = _transferService.previewMigrationData(
        remoteSnapshot.data,
        includeKnownHosts: false,
      );
      final remoteHasData = _hasPreviewData(remotePreview);

      if (localSnapshot.snapshotHash == remoteSnapshot.snapshotHash) {
        await _recordSuccessfulSync(
          snapshotHash: remoteSnapshot.snapshotHash,
          syncedAt: DateTime.now().toUtc(),
        );
        return const SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.noChanges,
          message: 'Encrypted sync is already up to date',
        );
      }

      final localChanged = lastSyncedHash == null
          ? localHasData
          : localSnapshot.snapshotHash != lastSyncedHash;
      final remoteChanged = lastSyncedHash == null
          ? remoteHasData
          : remoteSnapshot.snapshotHash != lastSyncedHash;

      if (!localChanged && remoteChanged) {
        return _downloadRemoteSnapshot(
          snapshot: remoteSnapshot,
          remotePreview: remotePreview,
        );
      }

      if (localChanged && !remoteChanged) {
        return _uploadLocalSnapshot(
          vaultFile: vaultFile,
          snapshot: localSnapshot,
          recoverySeed: recoverySeed,
        );
      }

      if (!localChanged && !remoteChanged) {
        await _recordSuccessfulSync(
          snapshotHash: remoteSnapshot.snapshotHash,
          syncedAt: DateTime.now().toUtc(),
        );
        return const SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.noChanges,
          message: 'Encrypted sync is already up to date',
        );
      }

      if (resolution == null) {
        return SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.conflict,
          message: 'Both this device and the vault changed since the last sync',
          localUpdatedAt: localSnapshot.updatedAt,
          remoteUpdatedAt: remoteSnapshot.updatedAt,
          localPreview: localPreview,
          remotePreview: remotePreview,
        );
      }

      return switch (resolution) {
        SyncVaultConflictResolution.uploadLocal => _uploadLocalSnapshot(
          vaultFile: vaultFile,
          snapshot: localSnapshot,
          recoverySeed: recoverySeed,
        ),
        SyncVaultConflictResolution.downloadRemote => _downloadRemoteSnapshot(
          snapshot: remoteSnapshot,
          remotePreview: remotePreview,
        ),
      };
    } on FileSystemException {
      return _storeFailureResult(
        const SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.needsRelink,
          message: 'Could not access the linked sync vault file',
        ),
      );
    } on FormatException catch (error) {
      return _storeFailureResult(
        SyncVaultSyncResult(
          outcome: SyncVaultSyncOutcome.needsRelink,
          message: error.message,
        ),
      );
    }
  }

  Future<SyncVaultSyncResult> _uploadLocalSnapshot({
    required File vaultFile,
    required _SyncVaultSnapshot snapshot,
    required List<int> recoverySeed,
  }) async {
    final encryptedVault = await _encryptSnapshot(
      snapshot: snapshot,
      recoverySeed: recoverySeed,
    );
    await _writeVaultAtomically(vaultFile, encryptedVault);
    await _recordSuccessfulSync(
      snapshotHash: snapshot.snapshotHash,
      syncedAt: snapshot.updatedAt,
    );
    return const SyncVaultSyncResult(
      outcome: SyncVaultSyncOutcome.uploadedLocal,
      message: 'Uploaded local changes to the encrypted sync vault',
    );
  }

  Future<SyncVaultSyncResult> _downloadRemoteSnapshot({
    required _SyncVaultSnapshot snapshot,
    required MigrationPreview remotePreview,
  }) async {
    await _transferService.importMigrationData(
      data: snapshot.data,
      mode: MigrationImportMode.replace,
      allowedSettingsKeys: _syncedSettingsKeys,
      includeKnownHosts: false,
    );
    await _recordSuccessfulSync(
      snapshotHash: snapshot.snapshotHash,
      syncedAt: DateTime.now().toUtc(),
    );
    return SyncVaultSyncResult(
      outcome: SyncVaultSyncOutcome.downloadedRemote,
      message: 'Downloaded encrypted sync vault changes to this device',
      remoteUpdatedAt: snapshot.updatedAt,
      remotePreview: remotePreview,
    );
  }

  Future<void> _recordSuccessfulSync({
    required String snapshotHash,
    required DateTime syncedAt,
  }) async {
    await _settings.setString(
      SettingKeys.syncVaultLastSnapshotHash,
      snapshotHash,
    );
    await _settings.setString(
      SettingKeys.syncVaultLastSyncedAt,
      syncedAt.toUtc().toIso8601String(),
    );
    await _settings.delete(SettingKeys.syncVaultLastError);
  }

  Future<SyncVaultSyncResult> _storeFailureResult(
    SyncVaultSyncResult result,
  ) async {
    await _settings.setString(SettingKeys.syncVaultLastError, result.message);
    return result;
  }

  Future<_SyncVaultSnapshot> _createSnapshot({required String deviceId}) async {
    final data = await _transferService.createMigrationData(
      allowedSettingsKeys: _syncedSettingsKeys,
      includeKnownHosts: false,
    );
    final snapshotHash = await _hashSyncData(data);
    return _SyncVaultSnapshot(
      schemaVersion: _schemaVersion,
      updatedAt: DateTime.now().toUtc(),
      updatedByDeviceId: deviceId,
      snapshotHash: snapshotHash,
      data: data,
    );
  }

  Future<String> _encryptSnapshot({
    required _SyncVaultSnapshot snapshot,
    required List<int> recoverySeed,
  }) async {
    final payloadBytes = utf8.encode(jsonEncode(snapshot.toJson()));
    final nonce = _randomBytes(_nonceBytes);
    final secretKey = await _deriveVaultKey(recoverySeed);
    final encryptedBox = await _algorithm.encrypt(
      payloadBytes,
      secretKey: secretKey,
      nonce: nonce,
    );
    final envelope = {
      'v': _envelopeVersion,
      'alg': 'AES-GCM-256',
      'nonce': base64Url.encode(nonce),
      'ciphertext': base64Url.encode(encryptedBox.cipherText),
      'mac': base64Url.encode(encryptedBox.mac.bytes),
    };
    return '$_vaultPrefix${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
  }

  Future<_SyncVaultSnapshot> _decryptVault(
    String encryptedVault, {
    required List<int> recoverySeed,
  }) async {
    final normalized = encryptedVault.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Sync vault file is empty');
    }

    final compactPayload = normalized.startsWith(_vaultPrefix)
        ? normalized.substring(_vaultPrefix.length)
        : normalized;
    late Map<String, dynamic> envelopeMap;
    try {
      final envelopeJson = utf8.decode(
        base64Url.decode(base64Url.normalize(compactPayload)),
      );
      final envelope = jsonDecode(envelopeJson);
      if (envelope is! Map) {
        throw const FormatException('Invalid sync vault envelope');
      }
      envelopeMap = Map<String, dynamic>.from(envelope);
    } on FormatException catch (error) {
      if (error.message == 'Invalid sync vault envelope') {
        rethrow;
      }
      throw const FormatException('Invalid sync vault envelope');
    }

    final version = (envelopeMap['v'] as num?)?.toInt();
    if (version != _envelopeVersion) {
      throw const FormatException('Unsupported sync vault version');
    }

    final nonce = _decodeEnvelopeField(envelopeMap, 'nonce');
    final cipherText = _decodeEnvelopeField(envelopeMap, 'ciphertext');
    final macBytes = _decodeEnvelopeField(envelopeMap, 'mac');
    if (nonce.length != _nonceBytes || macBytes.length < 16) {
      throw const FormatException('Invalid sync vault envelope');
    }

    final secretKey = await _deriveVaultKey(recoverySeed);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

    late List<int> payloadBytes;
    try {
      payloadBytes = await _algorithm.decrypt(secretBox, secretKey: secretKey);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Invalid recovery key or sync vault file');
    }

    late _SyncVaultSnapshot snapshot;
    try {
      final payloadJson = jsonDecode(utf8.decode(payloadBytes));
      if (payloadJson is! Map) {
        throw const FormatException('Invalid sync vault payload');
      }
      snapshot = _SyncVaultSnapshot.fromJson(
        Map<String, dynamic>.from(payloadJson),
      );
    } on FormatException catch (error) {
      if (error.message == 'Invalid sync vault payload') {
        rethrow;
      }
      throw const FormatException('Invalid sync vault payload');
    }

    late String computedHash;
    try {
      computedHash = await _hashSyncData(snapshot.data);
    } on FormatException catch (error) {
      if (error.message == 'Invalid sync vault payload') {
        rethrow;
      }
      throw const FormatException('Invalid sync vault payload');
    }
    if (computedHash != snapshot.snapshotHash) {
      throw const FormatException('Sync vault payload hash mismatch');
    }
    return snapshot;
  }

  Future<SecretKey> _deriveVaultKey(List<int> recoverySeed) async {
    final hash = await _sha256.hash(recoverySeed);
    return SecretKey(hash.bytes);
  }

  Future<String> _hashSyncData(Map<String, dynamic> data) async {
    final bytes = utf8.encode(jsonEncode(_canonicalizeSnapshotData(data)));
    final hash = await _sha256.hash(bytes);
    return base64Url.encode(hash.bytes);
  }

  Map<String, dynamic> _canonicalizeSnapshotData(Map<String, dynamic> data) {
    final groups = _canonicalizeHierarchicalRecords(
      _listFromSnapshot(data, 'groups'),
      parentKey: 'parentId',
      fields: const ['name', 'sortOrder', 'color', 'icon', 'createdAt'],
    );
    final keys = _canonicalizeFlatRecords(
      _listFromSnapshot(data, 'keys'),
      fields: const [
        'name',
        'keyType',
        'publicKey',
        'privateKey',
        'passphrase',
        'fingerprint',
        'createdAt',
      ],
    );
    final snippetFolders = _canonicalizeHierarchicalRecords(
      _listFromSnapshot(data, 'snippetFolders'),
      parentKey: 'parentId',
      fields: const ['name', 'sortOrder', 'createdAt'],
    );
    final snippets = _canonicalizeFlatRecords(
      _listFromSnapshot(data, 'snippets'),
      fields: const [
        'name',
        'command',
        'description',
        'autoExecute',
        'sortOrder',
        'createdAt',
        'lastUsedAt',
        'usageCount',
      ],
      referenceResolvers: {'folderId': snippetFolders.signaturesById},
      referenceNames: const {'folderId': 'folder'},
    );
    final hosts = _canonicalizeHosts(
      _listFromSnapshot(data, 'hosts'),
      groupSignaturesById: groups.signaturesById,
      keySignaturesById: keys.signaturesById,
      snippetSignaturesById: snippets.signaturesById,
    );
    final portForwards = _canonicalizeFlatRecords(
      _listFromSnapshot(data, 'portForwards'),
      fields: const [
        'name',
        'forwardType',
        'localHost',
        'localPort',
        'remoteHost',
        'remotePort',
        'autoStart',
        'createdAt',
      ],
      referenceResolvers: {'hostId': hosts.baseSignaturesById},
      referenceNames: const {'hostId': 'host'},
    );

    return <String, dynamic>{
      'settings': _canonicalizeScalarMap(_mapFromSnapshot(data, 'settings')),
      'groups': groups.records,
      'keys': keys.records,
      'hosts': hosts.records,
      'snippetFolders': snippetFolders.records,
      'snippets': snippets.records,
      'portForwards': portForwards.records,
    };
  }

  _CanonicalRecords _canonicalizeFlatRecords(
    List<Map<String, dynamic>> records, {
    required List<String> fields,
    Map<String, Map<int, String>> referenceResolvers = const {},
    Map<String, String> referenceNames = const {},
  }) {
    final normalizedEntries = <MapEntry<int, Map<String, dynamic>>>[];
    for (var index = 0; index < records.length; index += 1) {
      final record = records[index];
      final normalized = <String, dynamic>{};
      for (final field in fields) {
        normalized[field] = record[field];
      }
      for (final entry in referenceResolvers.entries) {
        final referenceId = _optionalInt(record[entry.key]);
        normalized[referenceNames[entry.key] ?? entry.key] = referenceId == null
            ? null
            : entry.value[referenceId];
      }
      final canonical = _canonicalizeScalarMap(normalized);
      normalizedEntries.add(MapEntry(index, canonical));
    }

    _sortCanonicalEntries(normalizedEntries);

    final signaturesById = <int, String>{};
    final canonicalRecords = <Map<String, dynamic>>[];
    for (final entry in normalizedEntries) {
      final record = records[entry.key];
      final signature = _signatureForRecord(entry.value);
      final oldId = _optionalInt(record['id']);
      if (oldId != null) {
        signaturesById[oldId] = signature;
      }
      canonicalRecords.add(entry.value);
    }

    return _CanonicalRecords(
      records: canonicalRecords,
      signaturesById: signaturesById,
    );
  }

  _CanonicalRecords _canonicalizeHierarchicalRecords(
    List<Map<String, dynamic>> records, {
    required String parentKey,
    required List<String> fields,
  }) {
    final recordsById = <int, Map<String, dynamic>>{
      for (final record in records)
        if (_optionalInt(record['id']) case final int id) id: record,
    };
    final cache = <int, Map<String, dynamic>>{};

    Map<String, dynamic> normalizeRecord(int id, Set<int> activePath) {
      final cached = cache[id];
      if (cached != null) {
        return cached;
      }
      if (!activePath.add(id)) {
        throw const FormatException('Invalid sync snapshot hierarchy');
      }

      try {
        final record = recordsById[id];
        if (record == null) {
          throw const FormatException('Invalid sync snapshot hierarchy');
        }

        final normalized = <String, dynamic>{};
        for (final field in fields) {
          normalized[field] = record[field];
        }
        final parentId = _optionalInt(record[parentKey]);
        normalized['parent'] = parentId == null
            ? null
            : normalizeRecord(parentId, activePath);
        final canonical = _canonicalizeScalarMap(normalized);
        cache[id] = canonical;
        return canonical;
      } finally {
        activePath.remove(id);
      }
    }

    final normalizedEntries = <MapEntry<int, Map<String, dynamic>>>[];
    for (var index = 0; index < records.length; index += 1) {
      final record = records[index];
      final oldId = _optionalInt(record['id']);
      if (oldId != null) {
        normalizedEntries.add(MapEntry(index, normalizeRecord(oldId, <int>{})));
        continue;
      }

      final normalized = <String, dynamic>{};
      for (final field in fields) {
        normalized[field] = record[field];
      }
      normalized['parent'] = null;
      normalizedEntries.add(
        MapEntry(index, _canonicalizeScalarMap(normalized)),
      );
    }

    _sortCanonicalEntries(normalizedEntries);

    final signaturesById = <int, String>{};
    final canonicalRecords = <Map<String, dynamic>>[];
    for (final entry in normalizedEntries) {
      final oldId = _optionalInt(records[entry.key]['id']);
      if (oldId != null) {
        signaturesById[oldId] = _signatureForRecord(entry.value);
      }
      canonicalRecords.add(entry.value);
    }

    return _CanonicalRecords(
      records: canonicalRecords,
      signaturesById: signaturesById,
    );
  }

  _CanonicalHosts _canonicalizeHosts(
    List<Map<String, dynamic>> hosts, {
    required Map<int, String> groupSignaturesById,
    required Map<int, String> keySignaturesById,
    required Map<int, String> snippetSignaturesById,
  }) {
    final baseEntries = <MapEntry<int, Map<String, dynamic>>>[];
    for (var index = 0; index < hosts.length; index += 1) {
      final host = hosts[index];
      final normalized = _canonicalizeScalarMap({
        'label': host['label'],
        'hostname': host['hostname'],
        'port': host['port'],
        'username': host['username'],
        'password': host['password'],
        'group': _referenceSignature(groupSignaturesById, host['groupId']),
        'key': _referenceSignature(keySignaturesById, host['keyId']),
        'isFavorite': host['isFavorite'],
        'color': host['color'],
        'notes': host['notes'],
        'tags': host['tags'],
        'sortOrder': host['sortOrder'],
        'createdAt': host['createdAt'],
        'updatedAt': host['updatedAt'],
        'lastConnectedAt': host['lastConnectedAt'],
        'terminalThemeLightId': host['terminalThemeLightId'],
        'terminalThemeDarkId': host['terminalThemeDarkId'],
        'terminalFontFamily': host['terminalFontFamily'],
        'autoConnectCommand': host['autoConnectCommand'],
        'autoConnectSnippet': _referenceSignature(
          snippetSignaturesById,
          host['autoConnectSnippetId'],
        ),
        'autoConnectRequiresConfirmation':
            host['autoConnectRequiresConfirmation'],
      });
      baseEntries.add(MapEntry(index, normalized));
    }

    _sortCanonicalEntries(baseEntries);

    final baseSignaturesById = <int, String>{};
    for (final entry in baseEntries) {
      final oldId = _optionalInt(hosts[entry.key]['id']);
      if (oldId != null) {
        baseSignaturesById[oldId] = _signatureForRecord(entry.value);
      }
    }

    final canonicalRecords = <Map<String, dynamic>>[];
    for (final entry in baseEntries) {
      final host = hosts[entry.key];
      canonicalRecords.add(
        _canonicalizeScalarMap({
          ...entry.value,
          'jumpHost': _referenceSignature(
            baseSignaturesById,
            host['jumpHostId'],
          ),
        }),
      );
    }

    return _CanonicalHosts(
      records: canonicalRecords,
      baseSignaturesById: baseSignaturesById,
    );
  }

  List<Map<String, dynamic>> _listFromSnapshot(
    Map<String, dynamic> data,
    String key,
  ) {
    if (!data.containsKey(key)) {
      return const <Map<String, dynamic>>[];
    }
    final raw = data[key];
    if (raw is! List) {
      throw const FormatException('Invalid sync vault payload');
    }
    return raw
        .map((item) {
          if (item is! Map) {
            throw const FormatException('Invalid sync vault payload');
          }
          return Map<String, dynamic>.from(item);
        })
        .toList(growable: false);
  }

  Map<String, dynamic> _mapFromSnapshot(Map<String, dynamic> data, String key) {
    if (!data.containsKey(key)) {
      return <String, dynamic>{};
    }
    final raw = data[key];
    if (raw is! Map) {
      throw const FormatException('Invalid sync vault payload');
    }
    return Map<String, dynamic>.from(raw);
  }

  Map<String, dynamic> _canonicalizeScalarMap(Map<String, dynamic> values) {
    final entries = values.entries.toList(growable: false)
      ..sort((first, second) => first.key.compareTo(second.key));
    return <String, dynamic>{
      for (final entry in entries)
        entry.key: switch (entry.value) {
          final Map<String, dynamic> value => _canonicalizeScalarMap(value),
          _ => entry.value,
        },
    };
  }

  String? _referenceSignature(Map<int, String> signaturesById, Object? rawId) {
    final id = _optionalInt(rawId);
    return id == null ? null : signaturesById[id];
  }

  void _sortCanonicalEntries(
    List<MapEntry<int, Map<String, dynamic>>> entries,
  ) {
    final encodedRecordsByIndex = <int, String>{
      for (final entry in entries) entry.key: jsonEncode(entry.value),
    };
    entries.sort((first, second) {
      final encodedComparison = encodedRecordsByIndex[first.key]!.compareTo(
        encodedRecordsByIndex[second.key]!,
      );
      if (encodedComparison != 0) {
        return encodedComparison;
      }
      return first.key.compareTo(second.key);
    });
  }

  String _signatureForRecord(Map<String, dynamic> record) => jsonEncode(record);

  int? _optionalInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }

  Future<void> _writeVaultAtomically(File vaultFile, String encryptedVault) =>
      writeStringToFileAtomically(vaultFile, encryptedVault);

  Future<String> _getOrCreateDeviceId() async {
    final existing = await _settings.getString(SettingKeys.syncVaultDeviceId);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final created = _uuid.v4();
    await _settings.setString(SettingKeys.syncVaultDeviceId, created);
    return created;
  }

  Future<String?> _readStoredRecoveryKey() =>
      _storage.read(key: _storageRecoveryKey);

  String _normalizeRecoveryKey(String recoveryKey) {
    final trimmed = recoveryKey.trim().toUpperCase();
    final withoutPrefix = trimmed.startsWith('MSYNC1')
        ? trimmed.replaceFirst(RegExp('^MSYNC1-?'), '')
        : trimmed;
    final hex = withoutPrefix.replaceAll(RegExp('[^A-F0-9]'), '');
    if (hex.length != _recoverySeedBytes * 2) {
      throw const FormatException(
        'Recovery key must contain 40 hex characters',
      );
    }
    return 'MSYNC1-$hex';
  }

  List<int> _parseRecoveryKey(String recoveryKey) {
    final normalized = _normalizeRecoveryKey(recoveryKey);
    final hex = normalized.substring('MSYNC1-'.length);
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  String _formatRecoveryKey(List<int> recoverySeed) {
    final hex = recoverySeed
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return _displayRecoveryKey('MSYNC1-$hex');
  }

  String _displayRecoveryKey(String normalizedRecoveryKey) {
    final hex = _normalizeRecoveryKey(
      normalizedRecoveryKey,
    ).substring('MSYNC1-'.length);
    final grouped = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      grouped.add(hex.substring(i, min(i + 4, hex.length)));
    }
    return 'MSYNC1-${grouped.join('-')}';
  }

  List<int> _decodeEnvelopeField(Map<String, dynamic> envelope, String key) {
    final value = envelope[key];
    if (value is! String || value.isEmpty) {
      throw const FormatException('Invalid sync vault envelope');
    }
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('Invalid sync vault envelope');
    }
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256), growable: false);

  bool _hasPreviewData(MigrationPreview preview) =>
      preview.settingsCount > 0 ||
      preview.hostCount > 0 ||
      preview.keyCount > 0 ||
      preview.groupCount > 0 ||
      preview.snippetCount > 0 ||
      preview.snippetFolderCount > 0 ||
      preview.portForwardCount > 0;
}

/// Provider for [SyncVaultService].
final syncVaultServiceProvider = Provider<SyncVaultService>(
  (ref) => SyncVaultService(
    ref.watch(settingsServiceProvider),
    ref.watch(secureTransferServiceProvider),
  ),
);

/// Provider for the current encrypted sync vault status.
final syncVaultStatusProvider = FutureProvider<SyncVaultStatus>((ref) async {
  final service = ref.watch(syncVaultServiceProvider);
  try {
    return await service.getStatus();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'sync_vault_service',
        context: ErrorDescription('while loading encrypted sync vault status'),
      ),
    );
    rethrow;
  }
});
