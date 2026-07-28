import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Media capture options supported by the embedded browser file picker.
enum BrowserMediaCaptureType {
  /// Capture a still image with the camera.
  image,

  /// Capture a video with the camera.
  video,
}

/// Native file picker settings resolved from an HTML file input accept list.
@immutable
class BrowserFilePickerFilter {
  /// Creates native file picker settings.
  const BrowserFilePickerFilter({required this.type, this.allowedExtensions});

  /// Broad native picker category.
  final FileType type;

  /// File extensions used when [type] is [FileType.custom].
  final List<String>? allowedExtensions;
}

/// Resolves the most specific native file picker filter for [acceptTypes].
BrowserFilePickerFilter resolveBrowserFilePickerFilter(
  Iterable<String> acceptTypes,
) {
  final normalizedTypes = _normalizeAcceptTypes(acceptTypes);
  if (normalizedTypes.isEmpty || normalizedTypes.any((type) => type == '*/*')) {
    return const BrowserFilePickerFilter(type: FileType.any);
  }
  if (normalizedTypes.every((type) => type.startsWith('image/'))) {
    return const BrowserFilePickerFilter(type: FileType.image);
  }
  if (normalizedTypes.every((type) => type.startsWith('video/'))) {
    return const BrowserFilePickerFilter(type: FileType.video);
  }
  if (normalizedTypes.every((type) => type.startsWith('audio/'))) {
    return const BrowserFilePickerFilter(type: FileType.audio);
  }
  if (normalizedTypes.every(
    (type) => type.startsWith('image/') || type.startsWith('video/'),
  )) {
    return const BrowserFilePickerFilter(type: FileType.media);
  }

  final extensionGroups = normalizedTypes
      .map(_extensionsForAcceptType)
      .toList(growable: false);
  final extensions = extensionGroups
      .whereType<List<String>>()
      .expand((extensions) => extensions)
      .toSet()
      .toList(growable: false);
  if (extensions.isNotEmpty &&
      extensionGroups.every((group) => group != null)) {
    return BrowserFilePickerFilter(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
  }
  return const BrowserFilePickerFilter(type: FileType.any);
}

/// Returns the camera capture mode requested by an HTML file input.
BrowserMediaCaptureType? preferredBrowserMediaCaptureType(
  Iterable<String> acceptTypes,
) {
  final normalizedTypes = _normalizeAcceptTypes(acceptTypes);
  if (normalizedTypes.isEmpty) {
    return null;
  }
  if (normalizedTypes.every((type) => type.startsWith('image/'))) {
    return BrowserMediaCaptureType.image;
  }
  if (normalizedTypes.every((type) => type.startsWith('video/'))) {
    return BrowserMediaCaptureType.video;
  }
  return null;
}

/// Returns a URI that Android WebView can use for an uploaded [file].
String? browserUploadUriForPlatformFile(PlatformFile file) {
  final identifier = file.identifier;
  if (identifier != null && identifier.isNotEmpty) {
    return identifier;
  }
  final path = file.path;
  return path == null || path.isEmpty ? null : Uri.file(path).toString();
}

List<String> _normalizeAcceptTypes(Iterable<String> acceptTypes) => acceptTypes
    .expand((type) => type.split(','))
    .map((type) => type.trim().toLowerCase())
    .where((type) => type.isNotEmpty)
    .toSet()
    .toList(growable: false);

List<String>? _extensionsForAcceptType(String acceptType) {
  if (RegExp(r'^\.[a-z0-9][a-z0-9.+_-]*$').hasMatch(acceptType)) {
    return [acceptType.substring(1)];
  }
  return _mimeTypeExtensions[acceptType];
}

const _mimeTypeExtensions = <String, List<String>>{
  'application/gzip': ['gz'],
  'application/json': ['json'],
  'application/msword': ['doc'],
  'application/pdf': ['pdf'],
  'application/rtf': ['rtf'],
  'application/vnd.ms-excel': ['xls'],
  'application/vnd.ms-powerpoint': ['ppt'],
  'application/vnd.oasis.opendocument.presentation': ['odp'],
  'application/vnd.oasis.opendocument.spreadsheet': ['ods'],
  'application/vnd.oasis.opendocument.text': ['odt'],
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': [
    'pptx',
  ],
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': ['xlsx'],
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': [
    'docx',
  ],
  'application/x-7z-compressed': ['7z'],
  'application/x-tar': ['tar'],
  'application/zip': ['zip'],
  'image/svg+xml': ['svg'],
  'text/calendar': ['ics'],
  'text/csv': ['csv'],
  'text/html': ['html', 'htm'],
  'text/markdown': ['md', 'markdown'],
  'text/plain': ['txt', 'text'],
  'text/xml': ['xml'],
};
