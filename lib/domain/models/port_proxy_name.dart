/// Builds the normalized, readable base used by generated proxy aliases.
String generatedPortProxySlug(String hostLabel) {
  var base = hostLabel
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) {
    base = 'host';
  }
  if (base.length > 12) {
    base = base.substring(0, 12).replaceFirst(RegExp(r'-+$'), '');
  }
  return base;
}
