import 'acp_json.dart';

/// Display hints attached to ACP content.
final class AcpAnnotations implements AcpExtensible {
  /// Creates ACP content annotations.
  const AcpAnnotations({
    this.audience = const <String>[],
    this.lastModified,
    this.priority,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses annotations from JSON.
  factory AcpAnnotations.fromJson(AcpJsonMap json) => AcpAnnotations(
    audience: AcpJson.strings(json['audience']),
    lastModified: AcpJson.string(json, 'lastModified'),
    priority: AcpJson.number(json, 'priority'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'audience',
      'lastModified',
      'priority',
    ]),
  );

  /// Intended content recipients.
  final List<String> audience;

  /// Last-modified timestamp supplied by the agent.
  final String? lastModified;

  /// Relative display priority.
  final num? priority;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  /// Encodes these annotations.
  AcpJsonMap toJson() => <String, Object?>{
    if (audience.isNotEmpty) 'audience': audience,
    if (lastModified != null) 'lastModified': lastModified,
    if (priority != null) 'priority': priority,
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Base class for ACP prompt and streamed content blocks.
sealed class AcpContentBlock implements AcpExtensible {
  const AcpContentBlock();

  /// Parses a known or extension content block.
  factory AcpContentBlock.fromJson(AcpJsonMap json) {
    final annotations = AcpJson.objectField(json, 'annotations');
    final parsedAnnotations = annotations == null
        ? null
        : AcpAnnotations.fromJson(annotations);
    return switch (AcpJson.string(json, 'type')) {
      'text' => AcpTextContent.fromJson(json, parsedAnnotations),
      'image' => AcpImageContent.fromJson(json, parsedAnnotations),
      'audio' => AcpAudioContent.fromJson(json, parsedAnnotations),
      'resource' => AcpResourceContent.fromJson(json, parsedAnnotations),
      'resource_link' => AcpResourceLinkContent.fromJson(
        json,
        parsedAnnotations,
      ),
      _ => AcpUnknownContent.fromJson(json, parsedAnnotations),
    };
  }

  /// Content discriminator.
  String get type;

  /// Optional display annotations.
  AcpAnnotations? get annotations;

  /// Encodes this content block.
  AcpJsonMap toJson();
}

/// Text content.
final class AcpTextContent extends AcpContentBlock {
  /// Creates text content.
  const AcpTextContent(
    this.text, {
    this.annotations,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses text content.
  factory AcpTextContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) => AcpTextContent(
    AcpJson.string(json, 'text') ?? '',
    annotations: annotations,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['type', 'text', 'annotations']),
  );

  /// Text payload.
  final String text;

  @override
  String get type => 'text';

  @override
  final AcpAnnotations? annotations;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'type': type,
    'text': text,
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Base class for base64-encoded media content.
sealed class AcpMediaContent extends AcpContentBlock {
  const AcpMediaContent({
    required this.data,
    required this.mimeType,
    required this.annotations,
    required this.meta,
    required this.extensions,
  });

  /// Base64-encoded media.
  final String data;

  /// Media MIME type.
  final String mimeType;

  @override
  final AcpAnnotations? annotations;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'type': type,
    'data': data,
    'mimeType': mimeType,
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Image content.
final class AcpImageContent extends AcpMediaContent {
  /// Creates image content.
  const AcpImageContent({
    required super.data,
    required super.mimeType,
    super.annotations,
    this.uri,
    super.meta = const <String, Object?>{},
    super.extensions = const <String, Object?>{},
  });

  /// Parses image content.
  factory AcpImageContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) => AcpImageContent(
    data: AcpJson.string(json, 'data') ?? '',
    mimeType: AcpJson.string(json, 'mimeType') ?? '',
    uri: AcpJson.string(json, 'uri'),
    annotations: annotations,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'type',
      'data',
      'mimeType',
      'uri',
      'annotations',
    ]),
  );

  /// Optional media URI.
  final String? uri;

  @override
  String get type => 'image';

  @override
  AcpJsonMap toJson() => <String, Object?>{
    ...super.toJson(),
    if (uri != null) 'uri': uri,
  };
}

/// Audio content.
final class AcpAudioContent extends AcpMediaContent {
  /// Creates audio content.
  const AcpAudioContent({
    required super.data,
    required super.mimeType,
    super.annotations,
    super.meta = const <String, Object?>{},
    super.extensions = const <String, Object?>{},
  });

  /// Parses audio content.
  factory AcpAudioContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) => AcpAudioContent(
    data: AcpJson.string(json, 'data') ?? '',
    mimeType: AcpJson.string(json, 'mimeType') ?? '',
    annotations: annotations,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'type',
      'data',
      'mimeType',
      'annotations',
    ]),
  );

  @override
  String get type => 'audio';
}

/// Base class for embedded text or binary resource data.
sealed class AcpEmbeddedResource implements AcpExtensible {
  const AcpEmbeddedResource();

  /// Parses embedded resource data.
  factory AcpEmbeddedResource.fromJson(AcpJsonMap json) {
    if (json['text'] is String) return AcpTextResource.fromJson(json);
    if (json['blob'] is String) return AcpBlobResource.fromJson(json);
    return AcpUnknownResource.fromJson(json);
  }

  /// Resource URI.
  String get uri;

  /// Optional resource MIME type.
  String? get mimeType;

  /// Encodes this resource.
  AcpJsonMap toJson();
}

/// Embedded text resource.
final class AcpTextResource extends AcpEmbeddedResource {
  /// Creates an embedded text resource.
  const AcpTextResource({
    required this.uri,
    required this.text,
    this.mimeType,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an embedded text resource.
  factory AcpTextResource.fromJson(AcpJsonMap json) => AcpTextResource(
    uri: AcpJson.string(json, 'uri') ?? '',
    text: AcpJson.string(json, 'text') ?? '',
    mimeType: AcpJson.string(json, 'mimeType'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['uri', 'text', 'mimeType']),
  );

  @override
  final String uri;

  /// Resource text.
  final String text;

  @override
  final String? mimeType;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'uri': uri,
    'text': text,
    if (mimeType != null) 'mimeType': mimeType,
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Embedded binary resource.
final class AcpBlobResource extends AcpEmbeddedResource {
  /// Creates an embedded binary resource.
  const AcpBlobResource({
    required this.uri,
    required this.blob,
    this.mimeType,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an embedded binary resource.
  factory AcpBlobResource.fromJson(AcpJsonMap json) => AcpBlobResource(
    uri: AcpJson.string(json, 'uri') ?? '',
    blob: AcpJson.string(json, 'blob') ?? '',
    mimeType: AcpJson.string(json, 'mimeType'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['uri', 'blob', 'mimeType']),
  );

  @override
  final String uri;

  /// Base64-encoded resource bytes.
  final String blob;

  @override
  final String? mimeType;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'uri': uri,
    'blob': blob,
    if (mimeType != null) 'mimeType': mimeType,
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Unknown embedded resource retained for future protocol versions.
final class AcpUnknownResource extends AcpEmbeddedResource {
  /// Creates an unknown embedded resource.
  const AcpUnknownResource({
    required this.raw,
    required this.uri,
    this.mimeType,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses unknown embedded resource data.
  factory AcpUnknownResource.fromJson(AcpJsonMap json) => AcpUnknownResource(
    raw: AcpJson.immutableObject(json),
    uri: AcpJson.string(json, 'uri') ?? '',
    mimeType: AcpJson.string(json, 'mimeType'),
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['uri', 'mimeType']),
  );

  /// Complete unrecognized resource object.
  final AcpJsonMap raw;

  @override
  final String uri;

  @override
  final String? mimeType;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => raw;
}

/// Embedded resource content block.
final class AcpResourceContent extends AcpContentBlock {
  /// Creates embedded resource content.
  const AcpResourceContent({
    required this.resource,
    this.annotations,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses embedded resource content.
  factory AcpResourceContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) {
    final rawResource =
        AcpJson.objectField(json, 'resource') ?? const <String, Object?>{};
    return AcpResourceContent(
      resource: AcpEmbeddedResource.fromJson(rawResource),
      annotations: annotations,
      meta: AcpJson.meta(json),
      extensions: AcpJson.extensions(json, const [
        'type',
        'resource',
        'annotations',
      ]),
    );
  }

  /// Embedded resource payload.
  final AcpEmbeddedResource resource;

  @override
  String get type => 'resource';

  @override
  final AcpAnnotations? annotations;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'type': type,
    'resource': resource.toJson(),
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Link to a resource the agent can read.
final class AcpResourceLinkContent extends AcpContentBlock {
  /// Creates resource-link content.
  const AcpResourceLinkContent({
    required this.name,
    required this.uri,
    this.title,
    this.description,
    this.mimeType,
    this.size,
    this.annotations,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses resource-link content.
  factory AcpResourceLinkContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) => AcpResourceLinkContent(
    name: AcpJson.string(json, 'name') ?? '',
    uri: AcpJson.string(json, 'uri') ?? '',
    title: AcpJson.string(json, 'title'),
    description: AcpJson.string(json, 'description'),
    mimeType: AcpJson.string(json, 'mimeType'),
    size: AcpJson.integer(json, 'size'),
    annotations: annotations,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const [
      'type',
      'name',
      'uri',
      'title',
      'description',
      'mimeType',
      'size',
      'annotations',
    ]),
  );

  /// Resource name.
  final String name;

  /// Resource URI.
  final String uri;

  /// Optional display title.
  final String? title;

  /// Optional description.
  final String? description;

  /// Optional MIME type.
  final String? mimeType;

  /// Optional resource size in bytes.
  final int? size;

  @override
  String get type => 'resource_link';

  @override
  final AcpAnnotations? annotations;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => <String, Object?>{
    'type': type,
    'name': name,
    'uri': uri,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (mimeType != null) 'mimeType': mimeType,
    if (size != null) 'size': size,
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta.isNotEmpty) '_meta': meta,
    ...extensions,
  };
}

/// Unknown content block retained for future protocol versions.
final class AcpUnknownContent extends AcpContentBlock {
  /// Creates an unknown content block.
  const AcpUnknownContent({
    required this.type,
    required this.raw,
    this.annotations,
    this.meta = const <String, Object?>{},
    this.extensions = const <String, Object?>{},
  });

  /// Parses an unknown content block.
  factory AcpUnknownContent.fromJson(
    AcpJsonMap json,
    AcpAnnotations? annotations,
  ) => AcpUnknownContent(
    type: AcpJson.string(json, 'type') ?? 'unknown',
    raw: AcpJson.immutableObject(json),
    annotations: annotations,
    meta: AcpJson.meta(json),
    extensions: AcpJson.extensions(json, const ['type', 'annotations']),
  );

  @override
  final String type;

  /// Complete unrecognized content object.
  final AcpJsonMap raw;

  @override
  final AcpAnnotations? annotations;

  @override
  final AcpJsonMap meta;

  @override
  final AcpJsonMap extensions;

  @override
  AcpJsonMap toJson() => raw;
}
