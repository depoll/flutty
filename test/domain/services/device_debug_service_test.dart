import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/device_debug_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _MockSshSession extends Mock implements SshSession {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockExecChannel extends Mock implements SSHSession {}

class _FakeAndroidDeviceDebugPlatform implements AndroidDeviceDebugPlatform {
  final endpoints = <AndroidAdbServiceKind, AndroidAdbEndpoint?>{};

  @override
  bool get supported => true;

  @override
  Future<AndroidAdbEndpoint?> discoverEndpoint(
    AndroidAdbServiceKind kind, {
    Duration timeout = const Duration(seconds: 6),
  }) async => endpoints[kind];

  @override
  Future<bool> openDeveloperOptions() async => true;
}

class _FakeRemoteAdbCommandRunner implements RemoteAdbCommandRunner {
  bool available = true;
  bool pairingSupported = true;
  RemoteListenerScope listenerScopeResult = RemoteListenerScope.loopback;
  DeviceDebugException? listenerScopeError;
  DeviceDebugException? connectError;
  Completer<RemoteAdbCommandResult>? pendingConnect;
  final connectResults = <RemoteAdbCommandResult>[];
  RemoteAdbCommandResult pairResult = const RemoteAdbCommandResult(
    exitCode: 0,
    output: 'Successfully paired to 127.0.0.1:41001',
  );
  final pairedCodes = <String>[];
  final connectAddresses = <String>[];
  final disconnectAddresses = <String>[];

  @override
  Future<RemoteAdbCommandResult> connect(
    SshSession session, {
    required String address,
  }) async {
    connectAddresses.add(address);
    if (connectError case final error?) {
      throw error;
    }
    if (pendingConnect case final pending?) {
      return pending.future;
    }
    return connectResults.removeAt(0);
  }

  @override
  Future<RemoteAdbCommandResult> disconnect(
    SshSession session, {
    required String address,
  }) async {
    disconnectAddresses.add(address);
    return const RemoteAdbCommandResult(exitCode: 0, output: 'disconnected');
  }

  @override
  Future<bool> isAvailable(SshSession session) async => available;

  @override
  Future<RemoteListenerScope> listenerScope(
    SshSession session,
    int port,
  ) async {
    if (listenerScopeError case final error?) {
      throw error;
    }
    return listenerScopeResult;
  }

  @override
  Future<bool> supportsPairing(SshSession session) async => pairingSupported;

  @override
  Future<RemoteAdbCommandResult> pair(
    SshSession session, {
    required String address,
    required String pairingCode,
  }) async {
    pairedCodes.add(pairingCode);
    return pairResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote ADB resolution', () {
    setUp(resetRemoteAdbPathCacheForTesting);
    tearDown(() {
      resetRemoteAdbPathCacheForTesting();
      resetQueuedSshExecsForTesting();
    });

    test('never sources profiles inline, which would exit a POSIX shell', () {
      final command = buildRemoteAdbResolutionCommand();

      expect(command, isNot(contains('. ~/.profile')));
      expect(command, isNot(contains('. ~/.zprofile')));
      expect(command, contains('command -v adb'));
      expect(command, contains('-lic'));
      expect(command, contains('-ic'));
      expect(
        command,
        contains(r'"$HOME/Library/Android/sdk/platform-tools/adb"'),
      );
      expect(command, contains('"/opt/homebrew/bin/adb"'));
    });

    test('parses the resolved path out of noisy login-shell output', () {
      expect(
        parseResolvedAdbPath(
          'Welcome to macOS\n'
          'MOTD greeting noise\n'
          '/opt/homebrew/bin/adb\n',
        ),
        '/opt/homebrew/bin/adb',
      );
      expect(
        parseResolvedAdbPath('/usr/bin/adb\n/Users/dev/Library/adb\n'),
        '/Users/dev/Library/adb',
      );
      expect(parseResolvedAdbPath('adb: aliased to /opt/adb\n'), isNull);
      expect(parseResolvedAdbPath('adb\nnot found\n'), isNull);
      expect(parseResolvedAdbPath(''), isNull);
    });

    test('runs ADB through the resolved path and caches it', () async {
      final client = _MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        executedCommands.add(command);
        final channel = _MockExecChannel();
        final output = command.contains('command -v adb')
            ? 'MOTD greeting noise\n/opt/homebrew/bin/adb\n'
            : 'Android Debug Bridge version 1.0.41';
        when(() => channel.stdout).thenAnswer(
          (_) =>
              Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(output))),
        );
        when(
          () => channel.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => channel.done).thenAnswer((_) async {});
        when(() => channel.exitCode).thenReturn(0);
        when(channel.close).thenReturn(null);
        return channel;
      });
      final session = SshSession(
        connectionId: 91,
        hostId: 3,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'mac-mini.example',
          port: 22,
          username: 'dev',
        ),
      );
      const runner = SshRemoteAdbCommandRunner();

      expect(await runner.isAvailable(session), isTrue);
      await runner.connect(session, address: '127.0.0.1:41002');

      expect(executedCommands, hasLength(3));
      expect(executedCommands.first, contains('command -v adb'));
      expect(executedCommands[1], "'/opt/homebrew/bin/adb' version");
      expect(
        executedCommands[2],
        "'/opt/homebrew/bin/adb' connect 127.0.0.1:41002",
      );
    });

    test('reports ADB as unavailable when resolution finds nothing', () async {
      final client = _MockSshClient();
      final executedCommands = <String>[];
      when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.6');
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        executedCommands.add(invocation.positionalArguments.single as String);
        final channel = _MockExecChannel();
        when(
          () => channel.stdout,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(
          () => channel.stderr,
        ).thenAnswer((_) => const Stream<Uint8List>.empty());
        when(() => channel.done).thenAnswer((_) async {});
        when(() => channel.exitCode).thenReturn(0);
        when(channel.close).thenReturn(null);
        return channel;
      });
      final session = SshSession(
        connectionId: 92,
        hostId: 3,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'mac-mini.example',
          port: 22,
          username: 'dev',
        ),
      );
      const runner = SshRemoteAdbCommandRunner();

      expect(await runner.isAvailable(session), isFalse);

      expect(executedCommands, hasLength(1));
      expect(executedCommands.single, contains('command -v adb'));
    });
  });

  test('parses a valid Android ADB endpoint', () {
    final endpoint = AndroidAdbEndpoint.fromPlatformValue(const {
      'serviceName': 'adb-device',
      'host': '192.0.2.10',
      'port': 37123,
    });

    expect(endpoint.serviceName, 'adb-device');
    expect(endpoint.host, '192.0.2.10');
    expect(endpoint.port, 37123);
  });

  test('rejects malformed Android ADB endpoints', () {
    expect(
      () => AndroidAdbEndpoint.fromPlatformValue(const {
        'serviceName': 'adb-device',
        'host': '',
        'port': 0,
      }),
      throwsFormatException,
    );
  });

  test('classifies Linux and Windows loopback listeners', () {
    expect(
      classifyRemoteListenerScope(
        'LISTEN 0 128 127.0.0.1:41002 0.0.0.0:*\n'
        'TCP [::1]:41002 [::]:0 LISTENING',
        41002,
      ),
      RemoteListenerScope.loopback,
    );
  });

  test('classifies wildcard and non-loopback listeners as exposed', () {
    expect(
      classifyRemoteListenerScope(
        'LISTEN 0 128 0.0.0.0:41002 0.0.0.0:*',
        41002,
      ),
      RemoteListenerScope.exposed,
    );
    expect(
      classifyRemoteListenerScope(
        'tcp4 0 0 192.0.2.20.41002 *.* LISTEN',
        41002,
      ),
      RemoteListenerScope.exposed,
    );
  });

  test('serializes Android NSD requests across sessions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('xyz.depollsoft.monkeyssh/device_debug'),
            null,
          );
    });
    const channel = MethodChannel('xyz.depollsoft.monkeyssh/device_debug');
    final pendingResponses = <Completer<Object?>>[];
    var discoveryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          if (call.method != 'discoverAdbEndpoint') {
            return null;
          }
          discoveryCalls++;
          final response = Completer<Object?>();
          pendingResponses.add(response);
          return response.future;
        });
    final platform = MethodChannelAndroidDeviceDebugPlatform();

    final first = platform.discoverEndpoint(AndroidAdbServiceKind.connect);
    await Future<void>.delayed(Duration.zero);
    final second = platform.discoverEndpoint(AndroidAdbServiceKind.pairing);
    await Future<void>.delayed(Duration.zero);

    expect(discoveryCalls, 1);
    pendingResponses.first.complete(null);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(discoveryCalls, 2);
    pendingResponses.last.complete(null);
    await second;
  });

  group('DeviceDebugSessionController', () {
    late _MockSshSession session;
    late _FakeAndroidDeviceDebugPlatform platform;
    late _FakeRemoteAdbCommandRunner remoteRunner;
    late List<ActiveTunnelInfo> activeTunnels;
    late List<int> stoppedTunnelIds;
    late Completer<void> closedCompleter;

    const connectEndpoint = AndroidAdbEndpoint(
      serviceName: 'adb-connect',
      host: '192.0.2.10',
      port: 37123,
    );
    const pairingEndpoint = AndroidAdbEndpoint(
      serviceName: 'adb-pairing',
      host: '192.0.2.10',
      port: 38947,
    );

    setUp(() {
      session = _MockSshSession();
      platform = _FakeAndroidDeviceDebugPlatform();
      remoteRunner = _FakeRemoteAdbCommandRunner();
      activeTunnels = [];
      stoppedTunnelIds = [];
      closedCompleter = Completer<void>();

      when(() => session.connectionId).thenReturn(7);
      when(() => session.closed).thenAnswer((_) => closedCompleter.future);
      when(() => session.activeTunnels).thenAnswer((_) => activeTunnels);
      when(() => session.stopForward(any())).thenAnswer((invocation) async {
        final tunnelId = invocation.positionalArguments.single as int;
        stoppedTunnelIds.add(tunnelId);
        activeTunnels.removeWhere((tunnel) => tunnel.portForwardId == tunnelId);
      });
      when(
        () => session.startRemoteForward(
          portForwardId: any(named: 'portForwardId'),
          remoteHost: any(named: 'remoteHost'),
          remotePort: any(named: 'remotePort'),
          localHost: any(named: 'localHost'),
          localPort: any(named: 'localPort'),
        ),
      ).thenAnswer((invocation) async {
        final tunnelId = invocation.namedArguments[#portForwardId]! as int;
        final remotePort = tunnelId == -2147483001 ? 41001 : 41002;
        activeTunnels.add(
          ActiveTunnelInfo(
            portForwardId: tunnelId,
            localHost: invocation.namedArguments[#localHost]! as String,
            localPort: invocation.namedArguments[#localPort]! as int,
            remoteHost: '127.0.0.1',
            remotePort: remotePort,
            isLocal: false,
          ),
        );
        return true;
      });
    });

    test('connects an already-paired SSH host and tears it down', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectResults.add(
        const RemoteAdbCommandResult(
          exitCode: 0,
          output: 'connected to 127.0.0.1:41002',
        ),
      );
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(controller.state.remoteAddress, '127.0.0.1:41002');
      verify(
        () => session.startRemoteForward(
          portForwardId: -2147483002,
          remoteHost: '127.0.0.1',
          remotePort: 0,
          localHost: connectEndpoint.host,
          localPort: connectEndpoint.port,
        ),
      ).called(1);

      await controller.stop();

      expect(controller.state.phase, DeviceDebugPhase.off);
      expect(remoteRunner.disconnectAddresses, ['127.0.0.1:41002']);
      expect(stoppedTunnelIds, contains(-2147483002));
    });

    test('pairs the remote ADB identity before connecting', () async {
      platform.endpoints
        ..[AndroidAdbServiceKind.connect] = connectEndpoint
        ..[AndroidAdbServiceKind.pairing] = pairingEndpoint;
      remoteRunner.connectResults.addAll([
        const RemoteAdbCommandResult(
          exitCode: 1,
          output: 'failed to authenticate to 127.0.0.1:41002',
        ),
        const RemoteAdbCommandResult(
          exitCode: 0,
          output: 'connected to 127.0.0.1:41002',
        ),
      ]);
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);

      await controller.pair('123456');

      expect(controller.state.phase, DeviceDebugPhase.active);
      expect(remoteRunner.pairedCodes, ['123456']);
      expect(stoppedTunnelIds, contains(-2147483001));
      expect(remoteRunner.connectAddresses, [
        '127.0.0.1:41002',
        '127.0.0.1:41002',
      ]);
    });

    test(
      'waits for Wireless debugging when no endpoint is advertised',
      () async {
        platform.endpoints[AndroidAdbServiceKind.connect] = null;
        final controller = DeviceDebugSessionController(
          session: session,
          platform: platform,
          remoteRunner: remoteRunner,
        );
        addTearDown(controller.dispose);

        await controller.enable();

        expect(
          controller.state.phase,
          DeviceDebugPhase.waitingForWirelessDebugging,
        );
      },
    );

    test('shows an actionable error when remote adb is unavailable', () async {
      remoteRunner.available = false;
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(controller.state.errorKind, DeviceDebugErrorKind.adbUnavailable);
    });

    test('requires a pairing-capable remote adb version', () async {
      remoteRunner.pairingSupported = false;
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(
        controller.state.message,
        contains('too old for Wireless debugging'),
      );
    });

    test('closes the connect tunnel when remote adb throws', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.connectError = const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'ADB failed.',
      );
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(stoppedTunnelIds, contains(-2147483002));
      expect(
        activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
        isEmpty,
      );
    });

    test('fails closed when the SSH server widens the listener', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.listenerScopeResult = RemoteListenerScope.exposed;
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(
        controller.state.errorKind,
        DeviceDebugErrorKind.remoteForwardExposed,
      );
      expect(stoppedTunnelIds, contains(-2147483002));
    });

    test('closes the tunnel when listener verification fails', () async {
      platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
      remoteRunner.listenerScopeError = const DeviceDebugException(
        kind: DeviceDebugErrorKind.remoteCommandFailed,
        message: 'Could not inspect listeners.',
      );
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.enable();

      expect(controller.state.phase, DeviceDebugPhase.error);
      expect(stoppedTunnelIds, contains(-2147483002));
      expect(
        activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
        isEmpty,
      );
    });

    test(
      'does not reactivate after being stopped during adb connect',
      () async {
        platform.endpoints[AndroidAdbServiceKind.connect] = connectEndpoint;
        final pendingConnect = Completer<RemoteAdbCommandResult>();
        remoteRunner.pendingConnect = pendingConnect;
        final controller = DeviceDebugSessionController(
          session: session,
          platform: platform,
          remoteRunner: remoteRunner,
        );
        addTearDown(controller.dispose);

        final enableFuture = controller.enable();
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.phase, DeviceDebugPhase.connecting);

        await controller.stop();
        pendingConnect.complete(
          const RemoteAdbCommandResult(
            exitCode: 0,
            output: 'connected to 127.0.0.1:41002',
          ),
        );
        await enableFuture;

        expect(controller.state.phase, DeviceDebugPhase.off);
        expect(
          activeTunnels.where((tunnel) => tunnel.portForwardId == -2147483002),
          isEmpty,
        );
      },
    );

    test('rejects pairing codes that are not six digits', () async {
      final controller = DeviceDebugSessionController(
        session: session,
        platform: platform,
        remoteRunner: remoteRunner,
      );
      addTearDown(controller.dispose);

      await controller.pair('123');

      expect(controller.state.phase, DeviceDebugPhase.waitingForPairingCode);
      expect(
        controller.state.errorKind,
        DeviceDebugErrorKind.pairingCodeInvalid,
      );
      expect(remoteRunner.pairedCodes, isEmpty);
    });
  });
}
