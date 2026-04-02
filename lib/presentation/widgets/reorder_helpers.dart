import 'dart:collection';

/// Reorders visible items within the full ordered list while preserving hidden ones.
List<int> reorderVisibleIdsInFullOrder({
  required List<int> allIds,
  required List<int> visibleIds,
  required int oldIndex,
  required int newIndex,
}) {
  if (visibleIds.length < 2) {
    return List<int>.from(allIds);
  }

  final adjustedNewIndex = oldIndex < newIndex ? newIndex - 1 : newIndex;
  final reorderedVisibleIds = List<int>.from(visibleIds);
  final movedId = reorderedVisibleIds.removeAt(oldIndex);
  reorderedVisibleIds.insert(adjustedNewIndex, movedId);

  final reorderedVisibleQueue = Queue<int>.from(reorderedVisibleIds);
  final visibleIdSet = visibleIds.toSet();
  return [
    for (final id in allIds)
      if (visibleIdSet.contains(id))
        reorderedVisibleQueue.removeFirst()
      else
        id,
  ];
}
