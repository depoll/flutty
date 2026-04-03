import 'dart:collection';

import 'package:flutter/material.dart';

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

/// Visible drag handle used to start a reorder gesture.
class ReorderGrip extends StatelessWidget {
  /// Creates a [ReorderGrip].
  const ReorderGrip({required this.index, super.key});

  /// The item index within the reorderable list.
  final int index;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ReorderableDragStartListener(
      index: index,
      child: Tooltip(
        message: 'Reorder',
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Icon(
              Icons.drag_indicator,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
