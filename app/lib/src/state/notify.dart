// Which chats raise a desktop notification, and what it says. A chat's
// unread count follows your push rules, so it only rises for messages
// they notify for; muted chats stay at zero.

import '../rust/api/types.dart';

/// Chats whose count rose since [before] (room ID to count), apart from
/// [openRoomId], the chat on screen. A chat new to the list counts from
/// zero, but only notifies for a message from the last [recent]: linking
/// a network brings in every chat with its history, and old messages
/// shouldn't notify.
List<RoomSummary> newlyNotifying(
  Map<String, int> before,
  List<RoomSummary> rooms, {
  String? openRoomId,
  DateTime? now,
  Duration recent = const Duration(minutes: 2),
}) {
  final since = (now ?? DateTime.now()).subtract(recent).millisecondsSinceEpoch;
  return [
    for (final r in rooms)
      if (r.id != openRoomId &&
          r.unreadCount > (before[r.id] ?? 0) &&
          !(r.preview?.isOwn ?? false) &&
          (before.containsKey(r.id) || (r.timestampMs ?? 0) >= since))
        r,
  ];
}

/// "Alice · WhatsApp", or "Alice in Family · WhatsApp" for a group.
({String title, String body}) notificationText(RoomSummary r) {
  final p = r.preview;
  final sender = p?.senderName;
  final who = r.isDm || sender == null ? r.name : '$sender in ${r.name}';
  final network = r.network == null ? '' : ' · ${r.network!.name}';
  return (title: '$who$network', body: p?.text ?? 'New message');
}

/// A stable notification ID per chat, so a newer message replaces the
/// last one. 0 is kept for the summary.
int notificationId(String roomId) {
  final id = roomId.hashCode & 0x7fffffff;
  return id == 0 ? 1 : id;
}
