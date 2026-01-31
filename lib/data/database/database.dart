import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Hosts table - stores SSH connection configurations.
class Hosts extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Display label for the host.
  TextColumn get label => text().withLength(min: 1, max: 255)();

  /// Hostname or IP address.
  TextColumn get hostname => text().withLength(min: 1, max: 255)();

  /// SSH port (default 22).
  IntColumn get port => integer().withDefault(const Constant(22))();

  /// Username for authentication.
  TextColumn get username => text().withLength(min: 1, max: 255)();

  /// Optional password (stored encrypted).
  TextColumn get password => text().nullable()();

  /// Reference to SSH key for authentication.
  IntColumn get keyId => integer().nullable().references(SshKeys, #id)();

  /// Reference to parent group.
  IntColumn get groupId => integer().nullable().references(Groups, #id)();

  /// Reference to jump host for proxy connections.
  IntColumn get jumpHostId => integer().nullable().references(Hosts, #id)();

  /// Whether this host is marked as favorite.
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  /// Custom color for the host (hex string).
  TextColumn get color => text().nullable()();

  /// Additional notes.
  TextColumn get notes => text().nullable()();

  /// Comma-separated tags.
  TextColumn get tags => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Last modified timestamp.
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// Last connection timestamp.
  DateTimeColumn get lastConnectedAt => dateTime().nullable()();
}

/// SSH Keys table - stores SSH key pairs.
class SshKeys extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Display name for the key.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Key type (ed25519, rsa, etc.).
  TextColumn get keyType => text().withLength(min: 1, max: 50)();

  /// Public key content.
  TextColumn get publicKey => text()();

  /// Private key content (stored encrypted).
  TextColumn get privateKey => text()();

  /// Optional passphrase for the key (stored encrypted).
  TextColumn get passphrase => text().nullable()();

  /// Key fingerprint for display.
  TextColumn get fingerprint => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Groups table - organizes hosts into folders.
class Groups extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Group name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Parent group for nested folders.
  IntColumn get parentId => integer().nullable().references(Groups, #id)();

  /// Display order within parent.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Custom color for the group (hex string).
  TextColumn get color => text().nullable()();

  /// Custom icon name.
  TextColumn get icon => text().nullable()();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Snippets table - stores reusable command snippets.
class Snippets extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Snippet name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// The command content.
  TextColumn get command => text()();

  /// Optional description.
  TextColumn get description => text().nullable()();

  /// Reference to parent folder.
  IntColumn get folderId =>
      integer().nullable().references(SnippetFolders, #id)();

  /// Whether to auto-execute on selection.
  BoolColumn get autoExecute => boolean().withDefault(const Constant(false))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Last used timestamp.
  DateTimeColumn get lastUsedAt => dateTime().nullable()();

  /// Usage count for sorting by frequency.
  IntColumn get usageCount => integer().withDefault(const Constant(0))();
}

/// Snippet folders for organizing snippets.
class SnippetFolders extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Folder name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Parent folder for nesting.
  IntColumn get parentId =>
      integer().nullable().references(SnippetFolders, #id)();

  /// Display order.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Port forwarding rules table.
class PortForwards extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Rule name.
  TextColumn get name => text().withLength(min: 1, max: 255)();

  /// Associated host.
  IntColumn get hostId => integer().references(Hosts, #id)();

  /// Forward type: 'local' or 'remote'.
  TextColumn get forwardType => text().withLength(min: 1, max: 10)();

  /// Local bind address.
  TextColumn get localHost => text().withDefault(const Constant('127.0.0.1'))();

  /// Local port.
  IntColumn get localPort => integer()();

  /// Remote host.
  TextColumn get remoteHost => text()();

  /// Remote port.
  IntColumn get remotePort => integer()();

  /// Whether to auto-start on host connection.
  BoolColumn get autoStart => boolean().withDefault(const Constant(false))();

  /// Creation timestamp.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// Known hosts for SSH host key verification.
class KnownHosts extends Table {
  /// Unique identifier.
  IntColumn get id => integer().autoIncrement()();

  /// Hostname or IP.
  TextColumn get hostname => text()();

  /// Port number.
  IntColumn get port => integer()();

  /// Host key type.
  TextColumn get keyType => text()();

  /// Host key fingerprint.
  TextColumn get fingerprint => text()();

  /// Full host key.
  TextColumn get hostKey => text()();

  /// When the key was first seen.
  DateTimeColumn get firstSeen => dateTime().withDefault(currentDateAndTime)();

  /// When the key was last verified.
  DateTimeColumn get lastSeen => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column<Object>>>? get uniqueKeys => [
    {hostname, port},
  ];
}

/// App settings table for key-value storage.
class Settings extends Table {
  /// Setting key.
  TextColumn get key => text()();

  /// Setting value (JSON encoded for complex values).
  TextColumn get value => text()();

  @override
  Set<Column<Object>>? get primaryKey => {key};
}

/// The main database class.
@DriftDatabase(
  tables: [
    Hosts,
    SshKeys,
    Groups,
    Snippets,
    SnippetFolders,
    PortForwards,
    KnownHosts,
    Settings,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// Creates a new database instance.
  AppDatabase() : super(_openConnection());

  /// Creates a database for testing with an in-memory database.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Handle future migrations here
    },
  );
}

LazyDatabase _openConnection() => LazyDatabase(() async {
  final dbFolder = await getApplicationDocumentsDirectory();
  final file = File(p.join(dbFolder.path, 'flutty.db'));
  return NativeDatabase.createInBackground(file);
});

/// Provider for the app database.
final databaseProvider = Provider<AppDatabase>((ref) => AppDatabase());
