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
    this.action = TerminalNotificationAction.show,
  });

  /// Creates a Kitty request to clear a previously identified notification.
  const TerminalNotificationRequest.close({required String identifier})
    : this(
        body: '',
        identifier: identifier,
        action: TerminalNotificationAction.close,
      );

  /// The notification title. When `null`, the presenter supplies a default
  /// (typically the host or session name).
  final String? title;

  /// The notification body text.
  final String body;

  /// Protocol identifier used to replace or close this notification.
  final String? identifier;

  /// Whether to show/update or clear the addressed notification.
  final TerminalNotificationAction action;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalNotificationRequest &&
          title == other.title &&
          body == other.body &&
          identifier == other.identifier &&
          action == other.action;

  @override
  int get hashCode => Object.hash(title, body, identifier, action);

  @override
  String toString() =>
      'TerminalNotificationRequest(title: $title, body: $body, '
      'identifier: $identifier, action: $action)';
}

/// Parses terminal desktop-notification OSC sequences into
/// [TerminalNotificationRequest]s.
///
/// Supports:
/// * **OSC 9** (iTerm2): `OSC 9 ; <message> ST`.
/// * **OSC 777** (rxvt-unicode): `OSC 777 ; notify ; <title> ; <body> ST`.
/// * **OSC 99** (kitty): `OSC 99 ; <metadata> ; <payload> ST`, including
///   multi-chunk assembly keyed by the `i=` identifier.
///
/// The parser holds the partial state needed to assemble chunked OSC 99
/// notifications, so a single instance must be used per terminal session.
class TerminalNotificationParser {
  /// Maximum number of in-flight (chunked) OSC 99 notifications retained.
  static const _maxPending = 8;

  /// Maximum length retained for an assembled title or body.
  static const _maxFieldLength = 1024;

  final Map<String, _PendingKittyNotification> _pending = {};

  /// Handles an OSC notification sequence. [code] is the OSC number (e.g. `'9'`)
  /// and [args] are the remaining `;`-separated parameters.
  ///
  /// Returns a [TerminalNotificationRequest] when a complete notification is
  /// available, or `null` when the sequence is not a (complete) notification.
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
    // ConEmu reuses OSC 9 for structured commands (`OSC 9 ; <n> ; ...`, e.g.
    // progress or working directory). Those start with a numeric sub-command,
    // so don't treat them as iTerm2 notifications.
    if (args.length >= 2 && int.tryParse(args.first.trim()) != null) {
      return null;
    }
    final message = _sanitize(args.join(';'));
    if (message.isEmpty) return null;
    return TerminalNotificationRequest(body: message);
  }

  TerminalNotificationRequest? _handleOsc777(List<String> args) {
    if (args.isEmpty || args.first != 'notify') return null;
    final title = _sanitize(args.length > 1 ? args[1] : '');
    final body = _sanitize(args.length > 2 ? args.sublist(2).join(';') : '');
    return _build(title: title, body: body);
  }

  TerminalNotificationRequest? _handleOsc99(List<String> args) {
    final metadata = _parseMetadata(args.isNotEmpty ? args.first : '');
    final id = _sanitizeIdentifier(metadata['i'] ?? '');
    final action = metadata['a'];
    if (action == 'close') {
      _pending.remove(id);
      return id.isEmpty
          ? null
          : TerminalNotificationRequest.close(identifier: id);
    }
    // Capability, focus, and activation reports require a bidirectional
    // protocol exchange and must not produce local notifications.
    if (action != null && action != 'create' && action != 'update') {
      _pending.remove(id);
      return null;
    }

    var payload = args.length > 1 ? args.sublist(1).join(';') : '';
    if (metadata['e'] == '1' && payload.isNotEmpty) {
      payload = _decodeBase64(payload);
    }

    final pending = _pending.putIfAbsent(id, _PendingKittyNotification.new);
    final isBody = metadata['p'] == 'body';
    if (isBody) {
      pending.body = _appendCapped(pending.body, payload);
    } else {
      pending.title = _appendCapped(pending.title, payload);
    }

    // `d=0` means more chunks follow; anything else (default) completes it.
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
    );
  }

  /// Builds a request, demoting a title-only notification to a body so the
  /// presenter can supply a default title.
  TerminalNotificationRequest? _build({
    required String title,
    required String body,
    String? identifier,
  }) {
    if (title.isEmpty && body.isEmpty) return null;
    if (body.isEmpty) {
      return TerminalNotificationRequest(body: title, identifier: identifier);
    }
    return TerminalNotificationRequest(
      title: title.isEmpty ? null : title,
      body: body,
      identifier: identifier,
    );
  }

  Map<String, String> _parseMetadata(String raw) {
    final result = <String, String>{};
    if (raw.isEmpty) return result;
    for (final pair in raw.split(':')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      result[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    return result;
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
    if (removable != keepId) {
      _pending.remove(removable);
    }
  }

  String _sanitizeIdentifier(String value) {
    final bounded = value.length > 128 ? value.substring(0, 128) : value;
    final sanitized = bounded.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_').trim();
    return sanitized.length > 128 ? sanitized.substring(0, 128) : sanitized;
  }

  /// Strips control characters and trims, so remote output can't inject control
  /// sequences into the notification UI.
  String _sanitize(String value) {
    final cleaned = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    return cleaned.length > _maxFieldLength
        ? cleaned.substring(0, _maxFieldLength)
        : cleaned;
  }
}

class _PendingKittyNotification {
  String title = '';
  String body = '';
}
