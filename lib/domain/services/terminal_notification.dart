import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Action requested by a terminal notification protocol message.
enum TerminalNotificationAction {
  /// Show a new notification or replace one with the same identifier.
  show,

  /// Clear the notification with the matching identifier.
  close,
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
    this.action = TerminalNotificationAction.show,
  });

  /// Creates a Kitty request to clear a previously identified notification.
  const TerminalNotificationRequest.close({required String identifier})
    : this(
        body: '',
        identifier: identifier,
        action: TerminalNotificationAction.close,
      );

  /// The notification title. When `null`, the presenter supplies a default.
  final String? title;

  /// The notification body text.
  final String body;

  /// Kitty protocol identifier used for update, close, and activation reports.
  final String? identifier;

  /// Local-only identity for an unidentified Kitty notification.
  ///
  /// Kitty requires notifications without `i=` to remain distinct rather than
  /// replacing one another.
  final String? localIdentifier;

  /// Whether a tap should report activation to the foreground application.
  final bool reportsActivation;

  /// Whether to show/update or clear the addressed notification.
  final TerminalNotificationAction action;

  /// Identity used only for the platform notification record.
  String? get platformIdentifier => identifier ?? localIdentifier;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalNotificationRequest &&
          title == other.title &&
          body == other.body &&
          identifier == other.identifier &&
          localIdentifier == other.localIdentifier &&
          reportsActivation == other.reportsActivation &&
          action == other.action;

  @override
  int get hashCode => Object.hash(
    title,
    body,
    identifier,
    localIdentifier,
    reportsActivation,
    action,
  );

  @override
  String toString() =>
      'TerminalNotificationRequest(title: $title, body: $body, '
      'identifier: $identifier, localIdentifier: $localIdentifier, '
      'reportsActivation: $reportsActivation, action: $action)';
}

/// Builds a Kitty OSC 99 capability response when [args] contain `p=?`.
String? buildKittyNotificationCapabilityResponse(List<String> args) {
  final metadata = _parseKittyNotificationMetadata(
    args.isNotEmpty ? args.first : '',
  );
  if (metadata['p'] != '?') return null;
  final id = _sanitizeKittyIdentifier(metadata['i'] ?? '');
  return '\x1b]99;${id.isEmpty ? '' : 'i=$id:'}p=?;'
      'a=focus,report:o=always:p=title,body\x1b\\';
}

/// Builds the activation report required by Kitty's `a=report` action.
String buildKittyNotificationActivationReport(String? identifier) =>
    '\x1b]99;i=${(identifier?.isNotEmpty ?? false) ? identifier : '0'};\x1b\\';

/// Parses terminal desktop-notification OSC sequences into requests.
class TerminalNotificationParser {
  static const _maxPending = 8;
  static const _maxFieldLength = 1024;

  final Map<String, _PendingKittyNotification> _pending = {};
  int _unidentifiedSequence = 0;

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
    final id = _sanitizeKittyIdentifier(metadata['i'] ?? '');
    final payloadType = metadata['p'] ?? 'title';
    if (payloadType == '?' || payloadType == 'alive') return null;
    if (payloadType == 'close') {
      _pending.remove(id);
      return id.isEmpty
          ? null
          : TerminalNotificationRequest.close(identifier: id);
    }
    if (payloadType != 'title' && payloadType != 'body') return null;

    var payload = args.length > 1 ? args.sublist(1).join(';') : '';
    if (metadata['e'] == '1' && payload.isNotEmpty) {
      payload = _decodeBase64(payload);
    }

    final pending = _pending.putIfAbsent(id, _PendingKittyNotification.new);
    pending.reportsActivation =
        pending.reportsActivation || _reportsActivation(metadata['a']);
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
    );
  }

  TerminalNotificationRequest? _build({
    required String title,
    required String body,
    String? identifier,
    String? localIdentifier,
    bool reportsActivation = false,
  }) {
    if (title.isEmpty && body.isEmpty) return null;
    if (body.isEmpty) {
      return TerminalNotificationRequest(
        body: title,
        identifier: identifier,
        localIdentifier: localIdentifier,
        reportsActivation: reportsActivation,
      );
    }
    return TerminalNotificationRequest(
      title: title.isEmpty ? null : title,
      body: body,
      identifier: identifier,
      localIdentifier: localIdentifier,
      reportsActivation: reportsActivation,
    );
  }

  bool _reportsActivation(String? actions) {
    var reports = false;
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

  String _decodeBase64(String value) {
    try {
      return utf8.decode(base64.decode(value), allowMalformed: true);
    } on FormatException {
      return '';
    }
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

String _sanitizeKittyIdentifier(String value) {
  final bounded = value.length > 128 ? value.substring(0, 128) : value;
  return bounded.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_').trim();
}

class _PendingKittyNotification {
  String title = '';
  String body = '';
  bool reportsActivation = false;
}
