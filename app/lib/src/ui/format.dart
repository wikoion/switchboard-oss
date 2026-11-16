import 'package:intl/intl.dart';

/// Chat-list time: "14:05" today, "Yesterday", a weekday within the week,
/// then a short date.
String listTime(int? millis, {DateTime? now}) {
  if (millis == null) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return DateFormat.Hm().format(t);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.EEEE().format(t);
  if (t.year == n.year) return DateFormat('d MMM').format(t);
  return DateFormat('d MMM y').format(t);
}

/// Day separator text in a conversation.
String dayLabel(int millis, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(DateTime(t.year, t.month, t.day)).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.EEEE().format(t);
  if (t.year == n.year) return DateFormat('EEEE d MMMM').format(t);
  return DateFormat('d MMMM y').format(t);
}

String bubbleTime(int millis) => DateFormat.Hm().format(DateTime.fromMillisecondsSinceEpoch(millis));
