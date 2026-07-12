// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_timeline.dart';
import 'package:monkeyssh/domain/services/acp_bridge_connector.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_recent_sessions_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';

class _FakeConnector extends Fake implements AcpBridgeConnector {}

class _FakeProviderService extends Fake implements AcpProviderService {}

class _FakeRecent extends Fake implements AcpRecentSessionsService {}

/// A controllable [AcpSessionManager] test double that records the UI actions
/// invoked against it and lets tests drive the aggregate state stream.
class FakeAcpSessionManager extends AcpSessionManager {
  FakeAcpSessionManager({
    List<AcpSessionState> sessions = const <AcpSessionState>[],
    this.recents = const <AcpRecentSessionRef>[],
    bool isProUnlocked = false,
  }) : _current = AcpSessionManagerState(sessions: sessions),
       super(
         connector: _FakeConnector(),
         providerService: _FakeProviderService(),
         recentSessions: _FakeRecent(),
         isProUnlocked: () => isProUnlocked,
       );

  AcpSessionManagerState _current;
  List<AcpRecentSessionRef> recents;
  final StreamController<AcpSessionManagerState> _emitter =
      StreamController<AcpSessionManagerState>.broadcast();

  final List<String> stopped = <String>[];
  final List<String> detached = <String>[];
  final List<String> selected = <String>[];
  final List<(String, String)> permissionResponses = <(String, String)>[];
  final List<String> cancelledPermissions = <String>[];
  final List<String> approvedWrites = <String>[];
  final List<String> rejectedWrites = <String>[];

  void emit(AcpSessionManagerState state) {
    _current = state;
    _emitter.add(state);
  }

  @override
  AcpSessionManagerState get state => _current;

  @override
  Stream<AcpSessionManagerState> get states async* {
    yield _current;
    yield* _emitter.stream;
  }

  @override
  Future<List<AcpRecentSessionRef>> loadRecentSessions() async => recents;

  @override
  Future<AcpSessionKey?> loadLastSelected() async => null;

  @override
  Future<void> selectSession(AcpSessionKey key) async {
    selected.add(key.value);
  }

  @override
  Future<void> stopSession(AcpSessionKey key) async {
    stopped.add(key.value);
  }

  @override
  Future<void> detachSession(AcpSessionKey key) async {
    detached.add(key.value);
  }

  @override
  Future<void> respondToPermission(
    AcpSessionKey key,
    String requestKey,
    String optionId,
  ) async {
    permissionResponses.add((requestKey, optionId));
  }

  @override
  Future<void> cancelPermission(AcpSessionKey key, String requestKey) async {
    cancelledPermissions.add(requestKey);
  }

  @override
  Future<void> approveWrite(AcpSessionKey key, String requestKey) async {
    approvedWrites.add(requestKey);
  }

  @override
  Future<void> rejectWrite(AcpSessionKey key, String requestKey) async {
    rejectedWrites.add(requestKey);
  }

  @override
  Future<void> dispose() async {
    await _emitter.close();
  }
}

/// Builds a stable session key for tests.
AcpSessionKey fakeAcpKey({
  int hostId = 1,
  String providerId = 'builtin:copilot-cli',
  String bridgeId = 'bridge-1',
  String acpSessionId = 'session-1',
}) => AcpSessionKey.of(
  hostId: hostId,
  providerId: providerId,
  bridgeId: bridgeId,
  acpSessionId: acpSessionId,
);

/// Builds an in-memory session state for tests.
AcpSessionState fakeAcpSession({
  AcpSessionKey? key,
  String providerLabel = 'Copilot CLI',
  String cwd = '/home/dev/project',
  AcpConnectionStatus status = AcpConnectionStatus.ready,
  String? title,
  DateTime? lastActivityAt,
  List<AcpPendingPermission> pendingPermissions =
      const <AcpPendingPermission>[],
  List<AcpPendingWrite> pendingWrites = const <AcpPendingWrite>[],
  AcpTimeline timeline = const AcpTimeline.empty(),
}) {
  final now = lastActivityAt ?? DateTime(2026);
  return AcpSessionState(
    key: key ?? fakeAcpKey(),
    providerLabel: providerLabel,
    cwd: cwd,
    status: status,
    createdAt: DateTime(2025),
    lastActivityAt: now,
    title: title,
    pendingPermissions: pendingPermissions,
    pendingWrites: pendingWrites,
    timeline: timeline,
  );
}

/// Builds an agent message timeline entry.
AcpTimeline fakeAcpTimeline(String agentText) => AcpTimeline(
  entries: [
    AcpMessageEntry(
      order: 0,
      role: AcpMessageRole.agent,
      content: [AcpTextContent(agentText)],
    ),
  ],
);
