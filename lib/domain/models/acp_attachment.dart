import 'package:flutter/foundation.dart';

/// Maximum image payload that the ACP timeline can safely display.
const int kAcpAttachmentImageDisplayMaxBytes = 10 * 1024 * 1024;

/// Opens a fresh byte stream for a local attachment.
typedef AcpAttachmentStreamFactory = Stream<List<int>> Function();

/// The source category of an attachment candidate.
enum AcpAttachmentSourceKind {
  /// Bytes already held in volatile memory.
  memory,

  /// A local file that is read only when a prompt is prepared.
  localFile,

  /// A remote file selected through SFTP.
  remoteFile,
}

/// A possible attachment selected by the user.
@immutable
sealed class AcpAttachmentCandidate {
  const AcpAttachmentCandidate({
    required this.name,
    required this.sizeBytes,
    required this.mimeType,
  });

  /// Creates an attachment backed by volatile in-memory bytes.
  factory AcpAttachmentCandidate.memory({
    required String name,
    required Uint8List bytes,
    String? mimeType,
  }) = AcpMemoryAttachmentCandidate;

  /// Creates a lazily read local-file attachment.
  const factory AcpAttachmentCandidate.localFile({
    required String name,
    required AcpAttachmentStreamFactory openRead,
    int? sizeBytes,
    String? mimeType,
  }) = AcpLocalFileAttachmentCandidate;

  /// Creates a remote SFTP attachment that is never downloaded.
  const factory AcpAttachmentCandidate.remoteFile({
    required String name,
    required String remotePath,
    int? sizeBytes,
    String? mimeType,
  }) = AcpRemoteFileAttachmentCandidate;

  /// User-visible file name.
  final String name;

  /// File size when known.
  final int? sizeBytes;

  /// Picker-provided MIME type when known.
  final String? mimeType;

  /// Attachment source category.
  AcpAttachmentSourceKind get sourceKind;
}

/// An attachment backed by volatile in-memory bytes.
@immutable
final class AcpMemoryAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates an in-memory attachment, defensively copying [bytes].
  AcpMemoryAttachmentCandidate({
    required super.name,
    required Uint8List bytes,
    super.mimeType,
  }) : _bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       super(sizeBytes: bytes.length);

  final Uint8List _bytes;

  /// Read-only attachment bytes.
  Uint8List get bytes => _bytes;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.memory;
}

/// A lazily read local-file attachment.
@immutable
final class AcpLocalFileAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates a local-file attachment.
  const AcpLocalFileAttachmentCandidate({
    required super.name,
    required this.openRead,
    super.sizeBytes,
    super.mimeType,
  });

  /// Opens the file byte stream.
  ///
  /// The preparation service invokes this at most once per preparation.
  final AcpAttachmentStreamFactory openRead;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.localFile;
}

/// A remote SFTP file attachment.
@immutable
final class AcpRemoteFileAttachmentCandidate extends AcpAttachmentCandidate {
  /// Creates a remote-file attachment.
  const AcpRemoteFileAttachmentCandidate({
    required super.name,
    required this.remotePath,
    super.sizeBytes,
    super.mimeType,
  });

  /// Absolute remote path reported by SFTP.
  final String remotePath;

  @override
  AcpAttachmentSourceKind get sourceKind => AcpAttachmentSourceKind.remoteFile;
}

/// Explicit fallback selected for a local attachment.
enum AcpAttachmentFallback {
  /// Reject content that cannot be embedded.
  reject,

  /// Upload content to the private MonkeySSH remote upload directory.
  remoteUpload,
}

/// One ordered item in an ACP prompt draft.
@immutable
sealed class AcpPromptDraftItem {
  const AcpPromptDraftItem();
}

/// Ordered prompt text.
@immutable
final class AcpPromptTextDraft extends AcpPromptDraftItem {
  /// Creates a text prompt item.
  const AcpPromptTextDraft(this.text);

  /// Prompt text.
  final String text;
}

/// Ordered attachment plus the user's explicit fallback choice.
@immutable
final class AcpAttachmentDraft extends AcpPromptDraftItem {
  /// Creates an attachment draft.
  const AcpAttachmentDraft({
    required this.candidate,
    this.fallback = AcpAttachmentFallback.reject,
  });

  /// Selected attachment.
  final AcpAttachmentCandidate candidate;

  /// Behavior when the attachment cannot be embedded.
  final AcpAttachmentFallback fallback;
}

/// An immutable, ordered ACP prompt draft.
@immutable
final class AcpPromptDraft {
  /// Creates a prompt draft and snapshots its ordered [items].
  AcpPromptDraft(Iterable<AcpPromptDraftItem> items)
    : items = List<AcpPromptDraftItem>.unmodifiable(items);

  /// Ordered prompt text and attachments.
  final List<AcpPromptDraftItem> items;
}

/// Attachment safety and resource limits.
@immutable
final class AcpAttachmentLimits {
  /// Creates attachment limits.
  const AcpAttachmentLimits({
    this.maxCount = 10,
    this.maxFileBytes = 50 * 1024 * 1024,
    this.maxTotalBytes = 100 * 1024 * 1024,
    this.maxEmbeddedBytes = 5 * 1024 * 1024,
    this.maxImageBytes = kAcpAttachmentImageDisplayMaxBytes,
    this.maxFileNameBytes = 255,
    this.maxMimeTypeBytes = 127,
    this.mimeSniffBytes = 512,
  }) : assert(maxCount > 0),
       assert(maxFileBytes > 0),
       assert(maxTotalBytes > 0),
       assert(maxEmbeddedBytes > 0),
       assert(maxImageBytes > 0),
       assert(maxImageBytes <= kAcpAttachmentImageDisplayMaxBytes),
       assert(maxFileNameBytes > 0),
       assert(maxMimeTypeBytes > 0),
       assert(mimeSniffBytes > 0);

  /// Maximum attachments per prompt.
  final int maxCount;

  /// Maximum bytes for one attachment, including upload fallbacks.
  final int maxFileBytes;

  /// Maximum known or read attachment bytes across the prompt.
  final int maxTotalBytes;

  /// Maximum bytes embedded as a text or blob resource.
  final int maxEmbeddedBytes;

  /// Maximum bytes embedded as an ACP image.
  final int maxImageBytes;

  /// Maximum UTF-8 bytes in a file name.
  final int maxFileNameBytes;

  /// Maximum UTF-8 bytes in a MIME type.
  final int maxMimeTypeBytes;

  /// Maximum prefix bytes used for MIME detection.
  final int mimeSniffBytes;
}

/// Attachment preparation failure category.
enum AcpAttachmentFailure {
  /// Too many attachments were selected.
  countLimit,

  /// One attachment exceeds the per-file limit.
  fileSizeLimit,

  /// Prompt attachments exceed the total byte limit.
  totalSizeLimit,

  /// An image exceeds the safe display limit.
  imageSizeLimit,

  /// A file name is empty, unsafe, or too long.
  invalidFileName,

  /// A MIME type is malformed or too long.
  invalidMimeType,

  /// A local file cannot be read.
  unreadable,

  /// Text resource bytes are not valid UTF-8.
  invalidUtf8,

  /// The agent cannot accept the attachment inline.
  unsupportedCapability,

  /// The attachment is too large to embed and upload was not selected.
  inlineSizeLimit,

  /// Remote upload was selected but no uploader is available.
  uploadUnavailable,

  /// Remote upload failed.
  uploadFailed,

  /// Preparation was cancelled.
  cancelled,
}

/// Safe attachment preparation exception.
final class AcpAttachmentException implements Exception {
  /// Creates an attachment exception with no file names, paths, or content.
  const AcpAttachmentException(this.failure, this.message);

  /// Failure category.
  final AcpAttachmentFailure failure;

  /// User-facing, content-free explanation.
  final String message;

  @override
  String toString() => 'AcpAttachmentException(${failure.name}): $message';
}
