// Which chats raise a desktop notification, and what it says and shows. A chat's
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

/// What stands in for the sender when notifications hide who wrote.
const hiddenSender = 'New message';

/// "Alice · WhatsApp", or "Alice in Family · WhatsApp" for a group. With
/// [hideSender] it names nobody: neither the sender nor the chat, since a
/// direct chat is named after the other person.
({String title, String body}) notificationText(RoomSummary r, {bool hideSender = false}) {
  final p = r.preview;
  final network = r.network == null ? '' : ' · ${r.network!.name}';
  if (hideSender) {
    // A join or leave is worded around the member's name.
    final text = p == null || p.isMembership ? 'New message' : p.text;
    return (title: '$hiddenSender$network', body: text);
  }
  final sender = p?.senderName;
  final who = r.isDm || sender == null ? r.name : '$sender in ${r.name}';
  return (title: '$who$network', body: p?.text ?? 'New message');
}

/// The sender's picture for a chat's notification: the one on their own
/// profile. Null when they have none; the chat's picture is never used in
/// its place, since it need not be the sender's.
String? senderPicture(RoomSummary r) {
  final mxc = r.preview?.senderAvatarMxc;
  return mxc != null && mxc.startsWith('mxc://') ? mxc : null;
}

/// A stable notification ID per chat, so a newer message replaces the
/// last one. 0 is kept for the summary.
int notificationId(String roomId) {
  final id = roomId.hashCode & 0x7fffffff;
  return id == 0 ? 1 : id;
}
