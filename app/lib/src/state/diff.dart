// Applies the core's list diffs, which mirror eyeball_im::VectorDiff.

import '../rust/api/types.dart';

List<RoomSummary> applyRoomDiffs(List<RoomSummary> list, List<RoomListDiff> diffs) {
  final out = List<RoomSummary>.of(list);
  for (final d in diffs) {
    switch (d) {
      case RoomListDiff_Append(:final values):
        out.addAll(values);
      case RoomListDiff_Clear():
        out.clear();
      case RoomListDiff_PushFront(:final value):
        out.insert(0, value);
      case RoomListDiff_PushBack(:final value):
        out.add(value);
      case RoomListDiff_PopFront():
        out.removeAt(0);
      case RoomListDiff_PopBack():
        out.removeLast();
      case RoomListDiff_Insert(:final index, :final value):
        out.insert(index, value);
      case RoomListDiff_Set(:final index, :final value):
        out[index] = value;
      case RoomListDiff_Remove(:final index):
        out.removeAt(index);
      case RoomListDiff_Truncate(:final length):
        out.length = length;
      case RoomListDiff_Reset(:final values):
        out
          ..clear()
          ..addAll(values);
    }
  }
  return out;
}

List<TimelineItem> applyTimelineDiffs(List<TimelineItem> list, List<TimelineDiff> diffs) {
  final out = List<TimelineItem>.of(list);
  for (final d in diffs) {
    switch (d) {
      case TimelineDiff_Append(:final values):
        out.addAll(values);
      case TimelineDiff_Clear():
        out.clear();
      case TimelineDiff_PushFront(:final value):
        out.insert(0, value);
      case TimelineDiff_PushBack(:final value):
        out.add(value);
      case TimelineDiff_PopFront():
        out.removeAt(0);
      case TimelineDiff_PopBack():
        out.removeLast();
      case TimelineDiff_Insert(:final index, :final value):
        out.insert(index, value);
      case TimelineDiff_Set(:final index, :final value):
        out[index] = value;
      case TimelineDiff_Remove(:final index):
        out.removeAt(index);
      case TimelineDiff_Truncate(:final length):
        out.length = length;
      case TimelineDiff_Reset(:final values):
        out
          ..clear()
          ..addAll(values);
    }
  }
  return out;
}
