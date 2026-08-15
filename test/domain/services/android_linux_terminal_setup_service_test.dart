import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/android_linux_terminal_launcher.dart';
import 'package:monkeyssh/domain/services/android_linux_terminal_setup_service.dart';
import 'package:monkeyssh/domain/services/key_service.dart';
import 'package:monkeyssh/domain/services/local_notification_service.dart';

class _FakeNotifications extends LocalNotificationService {
  int showCount = 0;
  int clearCount = 0;
  LinuxTerminalSetupNotificationPayload? launchPayload;

  @override
  Future<void> showLinuxTerminalSetup({
    required String title,
    required String body,
    bool ongoing = true,
  }) async {
    showCount += 1;
  }

  @override
  Future<void> clearLinuxTerminalSetup() async {
    clearCount += 1;
  }

  @override
  Future<LinuxTerminalSetupNotificationPayload?>
  consumeLaunchLinuxTerminalSetup() async {
    final payload = launchPayload;
    launchPayload = null;
    return payload;
  }
}

class _FakeLauncher extends AndroidLinuxTerminalLauncher {
  @override
  bool get isSupported => true;

  @override
  Future<AndroidLinuxTerminalStatus> getStatus() async =>
      const AndroidLinuxTerminalStatus(
        installed: true,
        enabled: true,
        canLaunch: true,
        packageName: 'com.android.virtualization.terminal',
      );

  @override
  Future<bool> openTerminal() async => true;

  @override
  Future<bool> openDeveloperOptions() async => true;

  @override
  Future<bool> openPortForwardingSettings() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData' ||
              call.method == 'Clipboard.getData') {
            return null;
          }
          return null;
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('buildAndroidLinuxTerminalSetupScript', () {
    test('embeds the public key and readiness marker', () {
      const publicKey =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey monkeyssh';
      final script = buildAndroidLinuxTerminalSetupScript(
        publicKey: publicKey,
        username: androidLinuxTerminalSetupUsername,
        port: androidLinuxTerminalSetupPort,
      );

      expect(script, contains('openssh-server'));
      expect(script, contains('Port $androidLinuxTerminalSetupPort'));
      expect(script, contains(publicKey));
      expect(
        script,
        contains(
          'MONKEYSSH_AVF_READY user=$androidLinuxTerminalSetupUsername port=$androidLinuxTerminalSetupPort',
        ),
      );
      expect(script, contains(shellSingleQuote(publicKey)));
    });
  });

  group('shellSingleQuote', () {
    test('escapes embedded single quotes', () {
      expect(shellSingleQuote("a'b"), equals("'a'\"'\"'b'"));
    });
  });

  group('isAndroidLinuxTerminalHost', () {
    Host host({required String label, String? notes}) => Host(
      id: 1,
      label: label,
      hostKind: 'ssh',
      hostname: '127.0.0.1',
      port: 8022,
      username: 'droid',
      isFavorite: false,
      autoConnectRequiresConfirmation: false,
      autoForwardPorts: false,
      sortOrder: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      notes: notes,
    );

    test('matches setup label and notes marker', () {
      expect(
        isAndroidLinuxTerminalHost(host(label: androidLinuxTerminalHostLabel)),
        isTrue,
      );
      expect(
        isAndroidLinuxTerminalHost(
          host(
            label: 'Other',
            notes: '$androidLinuxTerminalHostNotesMarker details',
          ),
        ),
        isTrue,
      );
      expect(isAndroidLinuxTerminalHost(host(label: 'Prod box')), isFalse);
    });
  });

  group('AndroidLinuxTerminalSetupService', () {
    late AppDatabase database;
    late HostRepository hostRepository;
    late KeyRepository keyRepository;
    late KeyService keyService;
    late _FakeNotifications notifications;
    late AndroidLinuxTerminalSetupService service;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final encryption = SecretEncryptionService.forTesting();
      hostRepository = HostRepository(database, encryption);
      keyRepository = KeyRepository(database, encryption);
      keyService = KeyService(keyRepository);
      notifications = _FakeNotifications();
    });

    tearDown(() async {
      service.dispose();
      await database.close();
    });

    AndroidLinuxTerminalSetupService buildService({
      required Future<bool> Function(String host, int port) probeSsh,
    }) => AndroidLinuxTerminalSetupService(
      hostRepository: hostRepository,
      keyRepository: keyRepository,
      keyService: keyService,
      notificationService: notifications,
      launcher: _FakeLauncher(),
      probeSsh: probeSsh,
    );

    test('creates a single host when finish is called concurrently', () async {
      final gate = Completer<void>();
      var probeCalls = 0;
      service = buildService(
        probeSsh: (host, port) async {
          probeCalls += 1;
          await gate.future;
          return true;
        },
      );

      await service.beginSetup();
      expect(
        service.state.phase,
        AndroidLinuxTerminalSetupPhase.waitingForUser,
      );

      final first = service.testConnectionAndFinish();
      final second = service.testConnectionAndFinish();
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(
        results.where(
          (state) => state.phase == AndroidLinuxTerminalSetupPhase.succeeded,
        ),
        isNotEmpty,
      );

      final hosts = await hostRepository.getAll();
      expect(hosts.where(isAndroidLinuxTerminalHost), hasLength(1));
      expect(probeCalls, greaterThanOrEqualTo(1));
      expect(notifications.clearCount, greaterThanOrEqualTo(1));
    });

    test(
      'does not overwrite unrelated localhost hosts on setup success',
      () async {
        service = buildService(probeSsh: (host, port) async => true);
        final unrelatedKey = await keyService.generateKey(
          name: 'other',
          keyType: SshKeyType.ed25519,
        );
        final unrelatedId = await hostRepository.insert(
          HostsCompanion.insert(
            label: 'My local sshd',
            hostname: '127.0.0.1',
            port: const Value(androidLinuxTerminalSetupPort),
            username: 'me',
            keyId: Value(unrelatedKey!.id),
          ),
        );

        await service.beginSetup();
        final finished = await service.testConnectionAndFinish();
        expect(finished.phase, AndroidLinuxTerminalSetupPhase.succeeded);

        final hosts = await hostRepository.getAll();
        final unrelated = hosts.singleWhere((host) => host.id == unrelatedId);
        expect(unrelated.label, 'My local sshd');
        expect(unrelated.username, 'me');
        expect(unrelated.keyId, unrelatedKey.id);

        final linuxHosts = hosts.where(isAndroidLinuxTerminalHost).toList();
        expect(linuxHosts, hasLength(1));
        expect(linuxHosts.single.id, isNot(unrelatedId));
        expect(linuxHosts.single.username, androidLinuxTerminalSetupUsername);
      },
    );

    test(
      'updates existing setup host instead of inserting duplicates',
      () async {
        service = buildService(probeSsh: (host, port) async => true);
        await service.beginSetup();
        final first = await service.testConnectionAndFinish();
        expect(first.phase, AndroidLinuxTerminalSetupPhase.succeeded);

        service.dispose();
        service = buildService(probeSsh: (host, port) async => true);
        await service.beginSetup();
        final second = await service.testConnectionAndFinish();
        expect(second.phase, AndroidLinuxTerminalSetupPhase.succeeded);

        final hosts = await hostRepository.getAll();
        expect(hosts.where(isAndroidLinuxTerminalHost), hasLength(1));
        expect(second.hostId, first.hostId);
      },
    );
  });
}
