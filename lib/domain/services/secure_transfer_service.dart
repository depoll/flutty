import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';

/// Supported transfer payload types.
enum TransferPayloadType {
  /// Host transfer payload.
  host,

  /// SSH key transfer payload.
  key,

  /// Full migration payload.
  fullMigration,
}

/// Full migration import mode.
enum MigrationImportMode {
  /// Keep existing data and add imported records.
  merge,

  /// Replace existing data with imported records.
  replace,
}

/// Decrypted transfer payload.
class TransferPayload {
  /// Creates a new [TransferPayload].
  const TransferPayload({
    required this.type,
    required this.schemaVersion,
    required this.createdAt,
    required this.data,
  });

  /// Builds payload from JSON.
  factory TransferPayload.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String?;
    final type = switch (rawType) {
      'host' => TransferPayloadType.host,
      'key' => TransferPayloadType.key,
      'full-migration' => TransferPayloadType.fullMigration,
      _ => throw const FormatException('Unsupported transfer payload type'),
    };

    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (createdAt == null) {
      throw const FormatException('Invalid transfer payload timestamp');
    }

    final rawData = json['data'];
    if (rawData is! Map) {
      throw const FormatException('Invalid transfer payload data');
    }

    return TransferPayload(
      type: type,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      createdAt: createdAt,
      data: Map<String, dynamic>.from(rawData),
    );
  }

  /// Payload type.
  final TransferPayloadType type;

  /// Payload schema version.
  final int schemaVersion;

  /// Creation timestamp.
  final DateTime createdAt;

  /// Payload data.
  final Map<String, dynamic> data;

  /// Converts payload to JSON.
  Map<String, dynamic> toJson() => {
    'type': switch (type) {
      TransferPayloadType.host => 'host',
      TransferPayloadType.key => 'key',
      TransferPayloadType.fullMigration => 'full-migration',
    },
    'schemaVersion': schemaVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'data': data,
  };
}

/// Human-readable migration preview counts.
class MigrationPreview {
  /// Creates a new [MigrationPreview].
  const MigrationPreview({
    required this.settingsCount,
    required this.hostCount,
    required this.keyCount,
    required this.groupCount,
    required this.snippetCount,
    required this.snippetFolderCount,
    required this.portForwardCount,
    required this.knownHostCount,
  });

  /// Number of settings records.
  final int settingsCount;

  /// Number of host records.
  final int hostCount;

  /// Number of SSH key records.
  final int keyCount;

  /// Number of host groups.
  final int groupCount;

  /// Number of snippets.
  final int snippetCount;

  /// Number of snippet folders.
  final int snippetFolderCount;

  /// Number of port forwards.
  final int portForwardCount;

  /// Number of known hosts.
  final int knownHostCount;
}

/// Service that encrypts and imports offline transfer payloads.
class SecureTransferService {
  /// Creates a new [SecureTransferService].
  SecureTransferService(this._db, this._keyRepository, this._hostRepository);

  final AppDatabase _db;
  final KeyRepository _keyRepository;
  final HostRepository _hostRepository;
  final _random = Random.secure();
  final _aesGcm = AesGcm.with256bits();
  final _sha256 = Sha256();

  static const _payloadPrefix = 'MSSH1:';
  static const _schemaVersion = 1;
  static const _envelopeVersion = 1;
  static const _saltBytes = 16;
  static const _nonceBytes = 12;
  static const _pbkdf2Iterations = 120000;
  static const _maxPbkdf2Iterations = 1000000;

  /// Creates an encrypted host transfer payload.
  Future<String> createHostPayload({
    required Host host,
    required String transferPassphrase,
    bool includeReferencedKey = false,
  }) async {
    SshKey? referencedKey;
    if (includeReferencedKey && host.keyId != null) {
      referencedKey = await _keyRepository.getById(host.keyId!);
    }

    final hostData = Map<String, dynamic>.from(host.toJson())
      ..['keyId'] = referencedKey == null ? null : host.keyId
      ..['groupId'] = null
      ..['jumpHostId'] = null;

    final payload = TransferPayload(
      type: TransferPayloadType.host,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: {'host': hostData, 'referencedKey': referencedKey?.toJson()},
    );
    return _encryptPayload(payload, transferPassphrase);
  }

  /// Creates an encrypted SSH key transfer payload.
  Future<String> createKeyPayload({
    required SshKey key,
    required String transferPassphrase,
  }) async {
    final payload = TransferPayload(
      type: TransferPayloadType.key,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: {'key': key.toJson()},
    );
    return _encryptPayload(payload, transferPassphrase);
  }

  /// Creates an encrypted full migration payload.
  Future<String> createFullMigrationPayload({
    required String transferPassphrase,
  }) async {
    final settings = await _db.select(_db.settings).get();
    final groups = await _db.select(_db.groups).get();
    final keys = await _keyRepository.getAll();
    final hosts = await _hostRepository.getAll();
    final snippetFolders = await _db.select(_db.snippetFolders).get();
    final snippets = await _db.select(_db.snippets).get();
    final portForwards = await _db.select(_db.portForwards).get();
    final knownHosts = await _db.select(_db.knownHosts).get();

    final payload = TransferPayload(
      type: TransferPayloadType.fullMigration,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now().toUtc(),
      data: {
        'settings': {
          for (final setting in settings) setting.key: setting.value,
        },
        'groups': groups.map((item) => item.toJson()).toList(growable: false),
        'keys': keys.map((item) => item.toJson()).toList(growable: false),
        'hosts': hosts.map((item) => item.toJson()).toList(growable: false),
        'snippetFolders': snippetFolders
            .map((item) => item.toJson())
            .toList(growable: false),
        'snippets': snippets
            .map((item) => item.toJson())
            .toList(growable: false),
        'portForwards': portForwards
            .map((item) => item.toJson())
            .toList(growable: false),
        'knownHosts': knownHosts
            .map((item) => item.toJson())
            .toList(growable: false),
      },
    );

    return _encryptPayload(payload, transferPassphrase);
  }

  /// Decrypts and parses an encrypted payload.
  Future<TransferPayload> decryptPayload({
    required String encodedPayload,
    required String transferPassphrase,
  }) async {
    final normalized = encodedPayload.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Transfer payload is empty');
    }

    if (transferPassphrase.trim().isEmpty) {
      throw const FormatException('Transfer passphrase is required');
    }

    final compactPayload = normalized.startsWith(_payloadPrefix)
        ? normalized.substring(_payloadPrefix.length)
        : normalized;
    final envelopeJson = utf8.decode(
      base64Url.decode(base64Url.normalize(compactPayload)),
    );
    final envelope = jsonDecode(envelopeJson);
    if (envelope is! Map) {
      throw const FormatException('Invalid transfer envelope');
    }

    final envelopeMap = Map<String, dynamic>.from(envelope);
    final versionValue = envelopeMap['v'];
    if (versionValue is! num || versionValue.toInt() != _envelopeVersion) {
      throw const FormatException('Unsupported transfer envelope version');
    }
    final envelopeIterations =
        _optionalInt(envelopeMap['iter']) ?? _pbkdf2Iterations;
    if (envelopeIterations <= 0 || envelopeIterations > _maxPbkdf2Iterations) {
      throw const FormatException('Invalid transfer envelope');
    }

    final salt = _decodeEnvelopeField(envelopeMap, 'salt');
    final nonce = _decodeEnvelopeField(envelopeMap, 'nonce');
    final cipherText = _decodeEnvelopeField(envelopeMap, 'ciphertext');
    final macBytes = _decodeEnvelopeField(envelopeMap, 'mac');
    if (salt.length != _saltBytes ||
        nonce.length != _nonceBytes ||
        macBytes.length < 16) {
      throw const FormatException('Invalid transfer envelope');
    }

    final secretKey = await _deriveKey(
      transferPassphrase,
      salt,
      iterations: envelopeIterations,
    );
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));

    late List<int> plaintext;
    try {
      plaintext = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Invalid passphrase or transfer payload');
    }

    final expectedChecksumValue = envelopeMap['checksum'];
    if (expectedChecksumValue != null) {
      if (expectedChecksumValue is! String || expectedChecksumValue.isEmpty) {
        throw const FormatException('Invalid transfer envelope');
      }
      final actualChecksum = await _sha256.hash(plaintext);
      final encodedChecksum = base64Url.encode(actualChecksum.bytes);
      if (encodedChecksum != expectedChecksumValue) {
        throw const FormatException('Transfer payload checksum mismatch');
      }
    }

    final payloadJson = jsonDecode(utf8.decode(plaintext));
    if (payloadJson is! Map) {
      throw const FormatException('Invalid decrypted payload');
    }

    return TransferPayload.fromJson(Map<String, dynamic>.from(payloadJson));
  }

  /// Imports a host payload and returns the created host.
  Future<Host> importHostPayload(TransferPayload payload) async {
    if (payload.type != TransferPayloadType.host) {
      throw const FormatException('Payload is not a host transfer');
    }

    final rawHost = payload.data['host'];
    if (rawHost is! Map) {
      throw const FormatException('Host payload data missing');
    }
    final hostData = Map<String, dynamic>.from(rawHost);
    return _db.transaction(() async {
      int? keyId;
      final rawReferencedKey = payload.data['referencedKey'];
      if (rawReferencedKey is Map) {
        final importedKey = await _importKeyMap(
          Map<String, dynamic>.from(rawReferencedKey),
        );
        keyId = importedKey.id;
      }

      final hostId = await _hostRepository.insert(
        HostsCompanion.insert(
          label: _requiredString(hostData, 'label'),
          hostname: _requiredString(hostData, 'hostname'),
          port: Value(_optionalInt(hostData['port']) ?? 22),
          username: _requiredString(hostData, 'username'),
          password: Value(_optionalString(hostData['password'])),
          keyId: Value(keyId),
          groupId: const Value(null),
          jumpHostId: const Value(null),
          isFavorite: Value((hostData['isFavorite'] as bool?) ?? false),
          color: Value(_optionalString(hostData['color'])),
          notes: Value(_optionalString(hostData['notes'])),
          tags: Value(_optionalString(hostData['tags'])),
          createdAt: Value(
            _optionalDateTime(hostData['createdAt']) ?? DateTime.now(),
          ),
          updatedAt: Value(
            _optionalDateTime(hostData['updatedAt']) ?? DateTime.now(),
          ),
          lastConnectedAt: Value(
            _optionalDateTime(hostData['lastConnectedAt']),
          ),
          terminalThemeLightId: Value(
            _optionalString(hostData['terminalThemeLightId']),
          ),
          terminalThemeDarkId: Value(
            _optionalString(hostData['terminalThemeDarkId']),
          ),
          terminalFontFamily: Value(
            _optionalString(hostData['terminalFontFamily']),
          ),
        ),
      );

      final createdHost = await _hostRepository.getById(hostId);
      if (createdHost == null) {
        throw const FormatException('Failed to import host');
      }
      return createdHost;
    });
  }

  /// Imports a key payload and returns the created key.
  Future<SshKey> importKeyPayload(TransferPayload payload) async {
    if (payload.type != TransferPayloadType.key) {
      throw const FormatException('Payload is not a key transfer');
    }
    final rawKey = payload.data['key'];
    if (rawKey is! Map) {
      throw const FormatException('Key payload data missing');
    }
    return _importKeyMap(Map<String, dynamic>.from(rawKey));
  }

  /// Produces a migration preview from a decrypted payload.
  MigrationPreview previewMigrationPayload(TransferPayload payload) {
    if (payload.type != TransferPayloadType.fullMigration) {
      throw const FormatException('Payload is not a full migration transfer');
    }

    final settingsMap = payload.data['settings'];
    final settingsCount = settingsMap is Map ? settingsMap.length : 0;

    return MigrationPreview(
      settingsCount: settingsCount,
      hostCount: _listFromData(payload.data, 'hosts').length,
      keyCount: _listFromData(payload.data, 'keys').length,
      groupCount: _listFromData(payload.data, 'groups').length,
      snippetCount: _listFromData(payload.data, 'snippets').length,
      snippetFolderCount: _listFromData(payload.data, 'snippetFolders').length,
      portForwardCount: _listFromData(payload.data, 'portForwards').length,
      knownHostCount: _listFromData(payload.data, 'knownHosts').length,
    );
  }

  /// Imports a full migration payload.
  Future<void> importFullMigrationPayload({
    required TransferPayload payload,
    required MigrationImportMode mode,
  }) async {
    if (payload.type != TransferPayloadType.fullMigration) {
      throw const FormatException('Payload is not a full migration transfer');
    }

    await _db.transaction(() async {
      if (mode == MigrationImportMode.replace) {
        await _db.customStatement('PRAGMA defer_foreign_keys = ON');
        await _clearMigrationTables();
      }

      final groupMapping = await _importGroups(
        _listFromData(payload.data, 'groups'),
      );
      final keyMapping = await _importKeys(_listFromData(payload.data, 'keys'));
      final hostMapping = await _importHosts(
        _listFromData(payload.data, 'hosts'),
        groupMapping: groupMapping,
        keyMapping: keyMapping,
      );
      final snippetFolderMapping = await _importSnippetFolders(
        _listFromData(payload.data, 'snippetFolders'),
      );
      await _importSnippets(
        _listFromData(payload.data, 'snippets'),
        snippetFolderMapping: snippetFolderMapping,
      );
      await _importPortForwards(
        _listFromData(payload.data, 'portForwards'),
        hostMapping: hostMapping,
      );
      await _importKnownHosts(_listFromData(payload.data, 'knownHosts'));
      await _importSettings(
        _settingsFromData(payload.data),
        clearExisting: mode == MigrationImportMode.replace,
      );
    });
  }

  Future<String> _encryptPayload(
    TransferPayload payload,
    String transferPassphrase,
  ) async {
    if (transferPassphrase.trim().isEmpty) {
      throw const FormatException('Transfer passphrase is required');
    }

    final payloadBytes = utf8.encode(jsonEncode(payload.toJson()));
    final salt = _randomBytes(_saltBytes);
    final nonce = _randomBytes(_nonceBytes);
    final secretKey = await _deriveKey(
      transferPassphrase,
      salt,
      iterations: _pbkdf2Iterations,
    );
    final encryptedBox = await _aesGcm.encrypt(
      payloadBytes,
      secretKey: secretKey,
      nonce: nonce,
    );
    final checksum = await _sha256.hash(payloadBytes);

    final envelope = {
      'v': _envelopeVersion,
      'alg': 'AES-GCM-256',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iter': _pbkdf2Iterations,
      'salt': base64Url.encode(salt),
      'nonce': base64Url.encode(nonce),
      'ciphertext': base64Url.encode(encryptedBox.cipherText),
      'mac': base64Url.encode(encryptedBox.mac.bytes),
      'checksum': base64Url.encode(checksum.bytes),
    };

    final encodedEnvelope = base64Url.encode(utf8.encode(jsonEncode(envelope)));
    return '$_payloadPrefix$encodedEnvelope';
  }

  Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt, {
    required int iterations,
  }) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _random.nextInt(256), growable: false);

  Future<SshKey> _importKeyMap(
    Map<String, dynamic> keyData, {
    List<SshKey>? existingKeysCache,
  }) async {
    final fingerprint = _optionalString(keyData['fingerprint']);
    final existingKeys = existingKeysCache ?? await _keyRepository.getAll();
    if (fingerprint != null && fingerprint.isNotEmpty) {
      for (final key in existingKeys) {
        if (key.fingerprint == fingerprint) {
          return key;
        }
      }
    }

    final publicKey = _requiredString(keyData, 'publicKey');
    final privateKey = _requiredString(keyData, 'privateKey');
    for (final key in existingKeys) {
      if (key.publicKey == publicKey && key.privateKey == privateKey) {
        return key;
      }
    }

    final keyId = await _keyRepository.insert(
      SshKeysCompanion.insert(
        name: _requiredString(keyData, 'name'),
        keyType: _requiredString(keyData, 'keyType'),
        publicKey: publicKey,
        privateKey: privateKey,
        passphrase: Value(_optionalString(keyData['passphrase'])),
        fingerprint: Value(fingerprint),
        createdAt: Value(
          _optionalDateTime(keyData['createdAt']) ?? DateTime.now(),
        ),
      ),
    );
    final createdKey = await _keyRepository.getById(keyId);
    if (createdKey == null) {
      throw const FormatException('Failed to import SSH key');
    }
    existingKeysCache?.add(createdKey);
    return createdKey;
  }

  Future<void> _clearMigrationTables() async {
    await _db.customStatement('DELETE FROM port_forwards');
    await _db.customStatement('DELETE FROM snippets');
    await _db.customStatement('DELETE FROM snippet_folders');
    await _db.customStatement('DELETE FROM hosts');
    await _db.customStatement('DELETE FROM ssh_keys');
    await _db.customStatement('DELETE FROM groups');
    await _db.customStatement('DELETE FROM known_hosts');
    await _db.customStatement('DELETE FROM settings');
  }

  Future<Map<int, int>> _importGroups(
    List<Map<String, dynamic>> rawGroups,
  ) async {
    final pending = <int, Map<String, dynamic>>{};
    for (final item in rawGroups) {
      final oldId = _optionalInt(item['id']);
      if (oldId != null) {
        pending[oldId] = item;
      }
    }

    final idMapping = <int, int>{};
    while (pending.isNotEmpty) {
      var progress = false;
      final pendingIds = pending.keys.toList(growable: false);
      for (final oldId in pendingIds) {
        final item = pending[oldId];
        if (item == null) {
          continue;
        }
        final parentOldId = _optionalInt(item['parentId']);
        if (parentOldId != null && !idMapping.containsKey(parentOldId)) {
          continue;
        }

        final newId = await _db
            .into(_db.groups)
            .insert(
              GroupsCompanion.insert(
                name: _requiredString(item, 'name'),
                parentId: Value(
                  parentOldId == null ? null : idMapping[parentOldId],
                ),
                sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
                color: Value(_optionalString(item['color'])),
                icon: Value(_optionalString(item['icon'])),
                createdAt: Value(
                  _optionalDateTime(item['createdAt']) ?? DateTime.now(),
                ),
              ),
            );
        idMapping[oldId] = newId;
        pending.remove(oldId);
        progress = true;
      }

      if (!progress) {
        throw const FormatException(
          'Invalid group hierarchy in migration payload',
        );
      }
    }

    return idMapping;
  }

  Future<Map<int, int>> _importKeys(List<Map<String, dynamic>> rawKeys) async {
    final idMapping = <int, int>{};
    final existingKeys = await _keyRepository.getAll();
    for (final item in rawKeys) {
      final oldId = _optionalInt(item['id']);
      final importedKey = await _importKeyMap(
        item,
        existingKeysCache: existingKeys,
      );
      if (oldId != null) {
        idMapping[oldId] = importedKey.id;
      }
    }
    return idMapping;
  }

  Future<Map<int, int>> _importHosts(
    List<Map<String, dynamic>> rawHosts, {
    required Map<int, int> groupMapping,
    required Map<int, int> keyMapping,
  }) async {
    final idMapping = <int, int>{};
    final jumpMapping = <int, int?>{};

    for (final item in rawHosts) {
      final oldId = _optionalInt(item['id']);
      final oldGroupId = _optionalInt(item['groupId']);
      final oldKeyId = _optionalInt(item['keyId']);
      final oldJumpId = _optionalInt(item['jumpHostId']);
      int? mappedGroupId;
      int? mappedKeyId;
      if (oldGroupId != null) {
        mappedGroupId = groupMapping[oldGroupId];
        if (mappedGroupId == null) {
          throw const FormatException(
            'Invalid group reference in migration payload',
          );
        }
      }
      if (oldKeyId != null) {
        mappedKeyId = keyMapping[oldKeyId];
        if (mappedKeyId == null) {
          throw const FormatException(
            'Invalid key reference in migration payload',
          );
        }
      }

      final newId = await _hostRepository.insert(
        HostsCompanion.insert(
          label: _requiredString(item, 'label'),
          hostname: _requiredString(item, 'hostname'),
          port: Value(_optionalInt(item['port']) ?? 22),
          username: _requiredString(item, 'username'),
          password: Value(_optionalString(item['password'])),
          keyId: Value(mappedKeyId),
          groupId: Value(mappedGroupId),
          jumpHostId: const Value(null),
          isFavorite: Value((item['isFavorite'] as bool?) ?? false),
          color: Value(_optionalString(item['color'])),
          notes: Value(_optionalString(item['notes'])),
          tags: Value(_optionalString(item['tags'])),
          createdAt: Value(
            _optionalDateTime(item['createdAt']) ?? DateTime.now(),
          ),
          updatedAt: Value(
            _optionalDateTime(item['updatedAt']) ?? DateTime.now(),
          ),
          lastConnectedAt: Value(_optionalDateTime(item['lastConnectedAt'])),
          terminalThemeLightId: Value(
            _optionalString(item['terminalThemeLightId']),
          ),
          terminalThemeDarkId: Value(
            _optionalString(item['terminalThemeDarkId']),
          ),
          terminalFontFamily: Value(
            _optionalString(item['terminalFontFamily']),
          ),
        ),
      );

      if (oldId != null) {
        idMapping[oldId] = newId;
      }
      jumpMapping[newId] = oldJumpId;
    }

    for (final entry in jumpMapping.entries) {
      final newHostId = entry.key;
      final oldJumpId = entry.value;
      if (oldJumpId == null) {
        continue;
      }
      final mappedJumpId = idMapping[oldJumpId];
      if (mappedJumpId == null) {
        throw const FormatException(
          'Invalid jump host reference in migration payload',
        );
      }
      await (_db.update(_db.hosts)..where((tbl) => tbl.id.equals(newHostId)))
          .write(HostsCompanion(jumpHostId: Value(mappedJumpId)));
    }

    return idMapping;
  }

  Future<Map<int, int>> _importSnippetFolders(
    List<Map<String, dynamic>> rawFolders,
  ) async {
    final pending = <int, Map<String, dynamic>>{};
    for (final item in rawFolders) {
      final oldId = _optionalInt(item['id']);
      if (oldId != null) {
        pending[oldId] = item;
      }
    }

    final idMapping = <int, int>{};
    while (pending.isNotEmpty) {
      var progress = false;
      final pendingIds = pending.keys.toList(growable: false);
      for (final oldId in pendingIds) {
        final item = pending[oldId];
        if (item == null) {
          continue;
        }
        final parentOldId = _optionalInt(item['parentId']);
        if (parentOldId != null && !idMapping.containsKey(parentOldId)) {
          continue;
        }

        final newId = await _db
            .into(_db.snippetFolders)
            .insert(
              SnippetFoldersCompanion.insert(
                name: _requiredString(item, 'name'),
                parentId: Value(
                  parentOldId == null ? null : idMapping[parentOldId],
                ),
                sortOrder: Value(_optionalInt(item['sortOrder']) ?? 0),
                createdAt: Value(
                  _optionalDateTime(item['createdAt']) ?? DateTime.now(),
                ),
              ),
            );
        idMapping[oldId] = newId;
        pending.remove(oldId);
        progress = true;
      }

      if (!progress) {
        throw const FormatException(
          'Invalid snippet folder hierarchy in migration payload',
        );
      }
    }

    return idMapping;
  }

  Future<void> _importSnippets(
    List<Map<String, dynamic>> rawSnippets, {
    required Map<int, int> snippetFolderMapping,
  }) async {
    for (final item in rawSnippets) {
      final oldFolderId = _optionalInt(item['folderId']);
      if (oldFolderId != null &&
          !snippetFolderMapping.containsKey(oldFolderId)) {
        throw const FormatException(
          'Invalid snippet folder reference in migration payload',
        );
      }
      await _db
          .into(_db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: _requiredString(item, 'name'),
              command: _requiredString(item, 'command'),
              description: Value(_optionalString(item['description'])),
              folderId: Value(
                oldFolderId == null ? null : snippetFolderMapping[oldFolderId],
              ),
              autoExecute: Value((item['autoExecute'] as bool?) ?? false),
              createdAt: Value(
                _optionalDateTime(item['createdAt']) ?? DateTime.now(),
              ),
              lastUsedAt: Value(_optionalDateTime(item['lastUsedAt'])),
              usageCount: Value(_optionalInt(item['usageCount']) ?? 0),
            ),
          );
    }
  }

  Future<void> _importPortForwards(
    List<Map<String, dynamic>> rawPortForwards, {
    required Map<int, int> hostMapping,
  }) async {
    for (final item in rawPortForwards) {
      final oldHostId = _optionalInt(item['hostId']);
      if (oldHostId == null) {
        throw const FormatException(
          'Missing host reference in migration payload',
        );
      }
      final mappedHostId = hostMapping[oldHostId];
      if (mappedHostId == null) {
        throw const FormatException(
          'Invalid host reference in migration payload',
        );
      }

      await _db
          .into(_db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              name: _requiredString(item, 'name'),
              hostId: mappedHostId,
              forwardType: _requiredString(item, 'forwardType'),
              localHost: Value(
                _optionalString(item['localHost']) ?? '127.0.0.1',
              ),
              localPort: _optionalInt(item['localPort']) ?? 0,
              remoteHost: _requiredString(item, 'remoteHost'),
              remotePort: _optionalInt(item['remotePort']) ?? 0,
              autoStart: Value((item['autoStart'] as bool?) ?? false),
              createdAt: Value(
                _optionalDateTime(item['createdAt']) ?? DateTime.now(),
              ),
            ),
          );
    }
  }

  Future<void> _importKnownHosts(
    List<Map<String, dynamic>> rawKnownHosts,
  ) async {
    for (final item in rawKnownHosts) {
      await _db
          .into(_db.knownHosts)
          .insert(
            KnownHostsCompanion.insert(
              hostname: _requiredString(item, 'hostname'),
              port: _optionalInt(item['port']) ?? 22,
              keyType: _requiredString(item, 'keyType'),
              fingerprint: _requiredString(item, 'fingerprint'),
              hostKey: _requiredString(item, 'hostKey'),
              firstSeen: Value(
                _optionalDateTime(item['firstSeen']) ?? DateTime.now(),
              ),
              lastSeen: Value(
                _optionalDateTime(item['lastSeen']) ?? DateTime.now(),
              ),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  Future<void> _importSettings(
    Map<String, String> settings, {
    required bool clearExisting,
  }) async {
    if (clearExisting) {
      await _db.customStatement('DELETE FROM settings');
    }
    for (final entry in settings.entries) {
      await _db
          .into(_db.settings)
          .insertOnConflictUpdate(
            SettingsCompanion.insert(key: entry.key, value: entry.value),
          );
    }
  }

  List<Map<String, dynamic>> _listFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final rawList = data[key];
    if (rawList is! List) {
      return <Map<String, dynamic>>[];
    }
    return rawList
        .map((item) {
          if (item is! Map) {
            throw FormatException('Invalid $key entry in migration payload');
          }
          return Map<String, dynamic>.from(item);
        })
        .toList(growable: false);
  }

  Map<String, String> _settingsFromData(Map<String, dynamic> data) {
    final rawSettings = data['settings'];
    if (rawSettings is! Map) {
      return <String, String>{};
    }
    final result = <String, String>{};
    for (final entry in rawSettings.entries) {
      if (entry.key is String && entry.value is String) {
        result[entry.key as String] = entry.value as String;
      }
    }
    return result;
  }

  String _requiredString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw FormatException('Missing required field: $key');
  }

  String? _optionalString(Object? value) => value is String ? value : null;

  int? _optionalInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime? _optionalDateTime(Object? value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  List<int> _decodeEnvelopeField(Map<String, dynamic> envelope, String key) {
    final value = envelope[key];
    if (value is! String || value.isEmpty) {
      throw const FormatException('Invalid transfer envelope');
    }
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('Invalid transfer envelope');
    }
  }
}

/// Provider for [SecureTransferService].
final secureTransferServiceProvider = Provider<SecureTransferService>(
  (ref) => SecureTransferService(
    ref.watch(databaseProvider),
    ref.watch(keyRepositoryProvider),
    ref.watch(hostRepositoryProvider),
  ),
);
