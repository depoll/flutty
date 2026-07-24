import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads Android clipboard metadata and content-URI entries.
///
/// The native side handles the `xyz.depollsoft.monkeyssh/clipboard_content`
/// channel. This service wraps that channel so the screen widget can be tested
/// without a live platform channel.
class ClipboardContentService {
  /// Creates a [ClipboardContentService] backed by the given [channel].
  ///
  /// The default value uses the production channel name so callers do not need
  /// to specify it in app code.
  const ClipboardContentService({
    MethodChannel channel = const MethodChannel(
      'xyz.depollsoft.monkeyssh/clipboard_content',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Reads text stored directly on an Android clipboard item.
  ///
  /// Unlike Flutter's plain-text clipboard API, this does not coerce a
  /// content URI into its string representation.
  Future<String?> readExplicitText() =>
      _channel.invokeMethod<String>('readExplicitText');

  /// Reads the content at [uri] and returns its file name and raw bytes.
  ///
  /// Throws a [PlatformException] if the native side returns an unexpected or
  /// incomplete response.
  Future<({String name, Uint8List bytes})> readContentUri(String uri) async {
    final response = await _channel.invokeMethod<Object>('readContentUri', {
      'uri': uri,
    });
    if (response is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Unexpected clipboard content response',
      );
    }

    final name = response['name'];
    final bytes = response['bytes'];
    if (name is! String || bytes is! Uint8List) {
      throw PlatformException(
        code: 'invalid_clipboard_content',
        message: 'Clipboard content response was incomplete',
      );
    }

    return (name: name, bytes: bytes);
  }
}

/// Provider for [ClipboardContentService].
final clipboardContentServiceProvider = Provider<ClipboardContentService>(
  (ref) => const ClipboardContentService(),
);
