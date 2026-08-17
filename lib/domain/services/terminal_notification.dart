import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Action requested by a terminal notification protocol message.
enum TerminalNotificationAction {
  /// Show a new notification or replace one with the same identifier.
  show,

  /// Clear the notification with the matching identifier.
  close,
}

/// Urgency requested by the remote notification protocol.
enum TerminalNotificationUrgency {
  /// Deliver quietly and without interrupting the user.
  low,

  /// Use the platform default notification priority.
  normal,

  /// Use the highest priority available without privileged entitlements.
  critical,
}

/// Sound behavior requested by the remote notification protocol.
enum TerminalNotificationSound {
  /// Play the platform default notification sound.
  system,

  /// Deliver without a sound.
  silent,
}

/// A request to surface or clear a desktop notification emitted by the remote
/// terminal via an OSC escape sequence (OSC 9 / OSC 777 / OSC 99).
@immutable
class TerminalNotificationRequest {
  /// Creates a request to show or replace a notification.
  const TerminalNotificationRequest({
    required this.body,
    this.title,
    this.identifier,
    this.localIdentifier,
    this.reportsActivation = false,
    this.focusOnActivation = true,
    this.reportsClose = false,
    this.urgency = TerminalNotificationUrgency.normal,
    this.sound = TerminalNotificationSound.silent,
    this.timeout,
    this.action = TerminalNotificationAction.show,
  });

  /// Creates a request to clear a notification by protocol or local identity.
  const TerminalNotificationRequest.close({
    this.identifier,
    this.localIdentifier,
  }) : assert(identifier != null || localIdentifier != null),
       title = null,
       body = '',
       reportsActivation = false,
       focusOnActivation = true,
       reportsClose = false,
       urgency = TerminalNotificationUrgency.normal,
       sound = TerminalNotificationSound.silent,
       timeout = null,
       action = TerminalNotificationAction.close;

  /// The notification title. When `null`, the presenter supplies a default.
  final String? title;

  /// The notification body text.
  final String body;

  /// Kitty protocol identifier used for update, close, and activation reports.
  final String? identifier;

  /// Local-only identity for a request without a protocol identifier.
  ///
  /// This keeps unidentified Kitty notifications distinct and lets other OSC
  /// protocols address native records without entering Kitty alive state.
  final String? localIdentifier;

  /// Whether a tap should report activation to the foreground application.
  final bool reportsActivation;

  /// Whether a tap should focus the originating terminal.
  final bool focusOnActivation;

  /// Whether the sender requested a notification-close report.
  final bool reportsClose;

  /// Requested native notification urgency.
  final TerminalNotificationUrgency urgency;

  /// Requested native notification sound behavior.
  final TerminalNotificationSound sound;

  /// Requested automatic expiration, or null for the platform default.
  final Duration? timeout;

  /// Whether to show/update or clear the addressed notification.
  final TerminalNotificationAction action;

  /// Namespaced identity used only for the platform notification record.
  ///
  /// Local records must not alias a remote Kitty identifier with the same
  /// printable text.
  String? get platformIdentifier {
    if (identifier != null) return 'kitty:$identifier';
    if (localIdentifier != null) return 'local:$localIdentifier';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalNotificationRequest &&
          title == other.title &&
          body == other.body &&
          identifier == other.identifier &&
          localIdentifier == other.localIdentifier &&
          reportsActivation == other.reportsActivation &&
          focusOnActivation == other.focusOnActivation &&
          reportsClose == other.reportsClose &&
          urgency == other.urgency &&
          sound == other.sound &&
          timeout == other.timeout &&
          action == other.action;

  @override
  int get hashCode => Object.hash(
    title,
    body,
    identifier,
    localIdentifier,
    reportsActivation,
    focusOnActivation,
    reportsClose,
    urgency,
    sound,
    timeout,
    action,
  );

  @override
  String toString() =>
      'TerminalNotificationRequest(title: $title, body: $body, '
      'identifier: $identifier, localIdentifier: $localIdentifier, '
      'reportsActivation: $reportsActivation, '
      'focusOnActivation: $focusOnActivation, reportsClose: $reportsClose, '
      'urgency: $urgency, sound: $sound, timeout: $timeout, '
      'action: $action)';
}

/// Builds a Kitty OSC 99 capability response when [args] contain `p=?`.
String? buildKittyNotificationCapabilityResponse(List<String> args) {
  final metadata = _parseKittyNotificationMetadata(
    args.isNotEmpty ? args.first : '',
  );
  if (metadata['p'] != '?') return null;
  final id = _validatedKittyIdentifier(metadata['i'] ?? '');
  return '\x1b]99;${id.isEmpty ? '' : 'i=$id:'}p=?;'
      'a=focus,report:o=always:p=title,body:'
      's=system,silent:u=0,1,2:w=1\x1b\\';
}

/// Builds the activation report required by Kitty's `a=report` action.
String buildKittyNotificationActivationReport(String? identifier) =>
    '\x1b]99;i=${(identifier?.isNotEmpty ?? false) ? identifier : '0'};\x1b\\';

/// Builds the Kitty report emitted when a notification is closed.
String buildKittyNotificationCloseReport(
  String? identifier, {
  bool untracked = false,
}) =>
    '\x1b]99;i=${(identifier?.isNotEmpty ?? false) ? identifier : '0'}:'
    'p=close;${untracked ? 'untracked' : ''}\x1b\\';

/// Builds a Kitty response listing notification identifiers still active.
String? buildKittyNotificationAliveResponse(
  List<String> args,
  Iterable<String> activeIdentifiers,
) {
  final metadata = _parseKittyNotificationMetadata(
    args.isNotEmpty ? args.first : '',
  );
  if (metadata['p'] != 'alive') return null;
  final queryId = _validatedKittyIdentifier(metadata['i'] ?? '');
  final active =
      activeIdentifiers
          .map(_validatedKittyIdentifier)
          .where((identifier) => identifier.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  return '\x1b]99;${queryId.isEmpty ? '' : 'i=$queryId:'}p=alive;'
      '${active.join(',')}\x1b\\';
}

/// Parses terminal desktop-notification OSC sequences into requests.
class TerminalNotificationParser {
  static const _maxPending = 8;
  static const _maxActiveIdentifiers = 128;
  static const _maxFieldLength = 1024;
  static const _maxTimeoutMilliseconds = 7 * 24 * 60 * 60 * 1000;

  final Map<String, _PendingKittyNotification> _pending = {};
  final Set<String> _activeIdentifiers = <String>{};
  int _unidentifiedSequence = 0;

  /// Identified notifications known to have been presented and not closed.
  Iterable<String> get activeIdentifiers => _activeIdentifiers;

  /// Marks an identified notification as successfully presented.
  void markPresented(String? identifier) {
    final validated = _validatedKittyIdentifier(identifier ?? '');
    if (validated.isEmpty) return;
    _activeIdentifiers
      ..remove(validated)
      ..add(validated);
    while (_activeIdentifiers.length > _maxActiveIdentifiers) {
      _activeIdentifiers.remove(_activeIdentifiers.first);
    }
  }

  /// Marks an identified notification as no longer active.
  void markClosed(String? identifier) {
    final validated = _validatedKittyIdentifier(identifier ?? '');
    if (validated.isNotEmpty) _activeIdentifiers.remove(validated);
  }

  /// Clears shell-scoped multipart and active notification state.
  ///
  /// The unidentified sequence remains connection-scoped because native
  /// notifications from a previous shell can outlive that shell. Reusing an
  /// identity after opening another shell would overwrite the older record.
  void reset() {
    _pending.clear();
    _activeIdentifiers.clear();
  }

  /// Handles one OSC notification sequence.
  TerminalNotificationRequest? handleOsc(String code, List<String> args) {
    switch (code) {
      case '9':
        return _handleOsc9(args);
      case '777':
        return _handleOsc777(args);
      case '99':
        return _handleOsc99(args);
      default:
        return null;
    }
  }

  TerminalNotificationRequest? _handleOsc9(List<String> args) {
    if (args.isEmpty) return null;
    // Numeric OSC 9 subcommands belong to ConEmu/Windows Terminal metadata.
    if (args.length >= 2 && int.tryParse(args.first.trim()) != null) {
      return null;
    }
    final message = _sanitize(args.join(';'));
    return message.isEmpty ? null : TerminalNotificationRequest(body: message);
  }

  TerminalNotificationRequest? _handleOsc777(List<String> args) {
    if (args.isEmpty || args.first != 'notify') return null;
    final title = _sanitize(args.length > 1 ? args[1] : '');
    final body = _sanitize(args.length > 2 ? args.sublist(2).join(';') : '');
    return _build(title: title, body: body);
  }

  TerminalNotificationRequest? _handleOsc99(List<String> args) {
    final metadata = _parseKittyNotificationMetadata(
      args.isNotEmpty ? args.first : '',
    );
    final rawIdentifier = metadata['i'] ?? '';
    final id = _validatedKittyIdentifier(rawIdentifier);
    if (rawIdentifier.isNotEmpty && id.isEmpty) return null;
    final payloadType = metadata['p'] ?? 'title';
    if (payloadType == '?' || payloadType == 'alive') return null;
    if (payloadType == 'close') {
      _pending.remove(id);
      markClosed(id);
      return id.isEmpty
          ? null
          : TerminalNotificationRequest.close(identifier: id);
    }
    if (payloadType != 'title' && payloadType != 'body') return null;

    final isBase64 = metadata['e'] == '1';
    var payload = _joinCapped(
      args.skip(1),
      isBase64 ? _maxEncodedPayloadLength : _maxFieldLength,
    );
    if (isBase64 && payload.isNotEmpty) {
      payload = _decodeBase64(
        payload,
        maxDecodedBytes: _maxDecodedPayloadBytes,
      );
    }

    final pending = _pending.putIfAbsent(id, _PendingKittyNotification.new);
    final reportsActivation = _updatedActivationReporting(
      metadata['a'],
      pending.reportsActivation,
    );
    final focusOnActivation = _updatedFocusOnActivation(
      metadata['a'],
      pending.focusOnActivation,
    );
    final urgency = _parseKittyUrgency(metadata['u']) ?? pending.urgency;
    final sound = _parseKittySound(metadata['s']) ?? pending.sound;
    final rawTimeout = metadata['w'];
    final timeoutMilliseconds = rawTimeout == null
        ? null
        : int.tryParse(rawTimeout);
    pending
      ..reportsActivation = reportsActivation
      ..focusOnActivation = focusOnActivation
      ..urgency = urgency
      ..sound = sound;
    if (timeoutMilliseconds != null && timeoutMilliseconds >= -1) {
      pending.timeout = timeoutMilliseconds <= 0
          ? null
          : Duration(
              milliseconds: timeoutMilliseconds.clamp(
                1,
                _maxTimeoutMilliseconds,
              ),
            );
    }
    final closeReporting = metadata['c'];
    if (closeReporting != null) {
      pending.reportsClose = closeReporting != '0';
    }
    if (payloadType == 'body') {
      pending.body = _appendCapped(pending.body, payload);
    } else {
      pending.title = _appendCapped(pending.title, payload);
    }

    final done = (metadata['d'] ?? '1') != '0';
    if (!done) {
      _enforcePendingBound(id);
      return null;
    }

    _pending.remove(id);
    return _build(
      title: _sanitize(pending.title),
      body: _sanitize(pending.body),
      identifier: id.isEmpty ? null : id,
      localIdentifier: id.isEmpty
          ? 'kitty-unidentified-${_unidentifiedSequence++}'
          : null,
      reportsActivation: pending.reportsActivation,
      focusOnActivation: pending.focusOnActivation,
      reportsClose: pending.reportsClose,
      urgency: pending.urgency,
      sound: pending.sound,
      timeout: pending.timeout,
    );
  }

  TerminalNotificationRequest? _build({
    required String title,
    required String body,
    String? identifier,
    String? localIdentifier,
    bool reportsActivation = false,
    bool focusOnActivation = true,
    bool reportsClose = false,
    TerminalNotificationUrgency urgency = TerminalNotificationUrgency.normal,
    TerminalNotificationSound sound = TerminalNotificationSound.silent,
    Duration? timeout,
  }) {
    if (title.isEmpty && body.isEmpty) return null;
    if (body.isEmpty) {
      return TerminalNotificationRequest(
        body: title,
        identifier: identifier,
        localIdentifier: localIdentifier,
        reportsActivation: reportsActivation,
        focusOnActivation: focusOnActivation,
        reportsClose: reportsClose,
        urgency: urgency,
        sound: sound,
        timeout: timeout,
      );
    }
    return TerminalNotificationRequest(
      title: title.isEmpty ? null : title,
      body: body,
      identifier: identifier,
      localIdentifier: localIdentifier,
      reportsActivation: reportsActivation,
      focusOnActivation: focusOnActivation,
      reportsClose: reportsClose,
      urgency: urgency,
      sound: sound,
      timeout: timeout,
    );
  }

  bool _updatedActivationReporting(String? actions, bool previous) {
    var reports = previous;
    for (final action in (actions ?? '').split(',')) {
      switch (action.trim()) {
        case 'report':
          reports = true;
        case '-report':
          reports = false;
      }
    }
    return reports;
  }

  bool _updatedFocusOnActivation(String? actions, bool previous) {
    var focuses = previous;
    for (final action in (actions ?? '').split(',')) {
      switch (action.trim()) {
        case 'focus':
          focuses = true;
        case '-focus':
          focuses = false;
      }
    }
    return focuses;
  }

  TerminalNotificationUrgency? _parseKittyUrgency(String? value) =>
      switch (value) {
        '0' => TerminalNotificationUrgency.low,
        '1' => TerminalNotificationUrgency.normal,
        '2' => TerminalNotificationUrgency.critical,
        _ => null,
      };

  TerminalNotificationSound? _parseKittySound(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    return switch (_decodeBase64(encoded, maxDecodedBytes: 32)) {
      'system' => TerminalNotificationSound.system,
      'silent' => TerminalNotificationSound.silent,
      _ => null,
    };
  }

  static const _maxDecodedPayloadBytes = _maxFieldLength * 4;
  static const _maxEncodedPayloadLength =
      ((_maxDecodedPayloadBytes + 2) ~/ 3) * 4 + 4;

  String _decodeBase64(String value, {required int maxDecodedBytes}) {
    final maxEncodedLength = ((maxDecodedBytes + 2) ~/ 3) * 4 + 4;
    if (value.length > maxEncodedLength) return '';
    try {
      final decoded = base64.decode(base64.normalize(value));
      if (decoded.length > maxDecodedBytes) return '';
      return utf8.decode(decoded, allowMalformed: true);
    } on FormatException {
      return '';
    }
  }

  String _joinCapped(Iterable<String> values, int maxLength) {
    final buffer = StringBuffer();
    for (final value in values) {
      if (buffer.isNotEmpty) {
        if (buffer.length >= maxLength) break;
        buffer.write(';');
      }
      final remaining = maxLength - buffer.length;
      if (remaining <= 0) break;
      buffer.write(
        value.length <= remaining ? value : value.substring(0, remaining),
      );
      if (value.length > remaining) break;
    }
    return buffer.toString();
  }

  String _appendCapped(String current, String addition) {
    if (current.length >= _maxFieldLength) return current;
    final combined = current + addition;
    return combined.length > _maxFieldLength
        ? combined.substring(0, _maxFieldLength)
        : combined;
  }

  void _enforcePendingBound(String keepId) {
    if (_pending.length <= _maxPending) return;
    final removable = _pending.keys.firstWhere(
      (key) => key != keepId,
      orElse: () => keepId,
    );
    if (removable != keepId) _pending.remove(removable);
  }

  String _sanitize(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    return cleaned.length > _maxFieldLength
        ? cleaned.substring(0, _maxFieldLength)
        : cleaned;
  }
}

Map<String, String> _parseKittyNotificationMetadata(String raw) {
  final result = <String, String>{};
  if (raw.isEmpty) return result;
  for (final pair in raw.split(':')) {
    final separator = pair.indexOf('=');
    if (separator <= 0) continue;
    result[pair.substring(0, separator)] = pair.substring(separator + 1);
  }
  return result;
}

String _validatedKittyIdentifier(String value) {
  if (value.isEmpty || value.length > 128) return '';
  return RegExp(r'[\x00-\x1F\x7F]').hasMatch(value) ? '' : value;
}

class _PendingKittyNotification {
  String title = '';
  String body = '';
  bool reportsActivation = false;
  bool focusOnActivation = true;
  bool reportsClose = false;
  TerminalNotificationUrgency urgency = TerminalNotificationUrgency.normal;
  TerminalNotificationSound sound = TerminalNotificationSound.system;
  Duration? timeout;
}
