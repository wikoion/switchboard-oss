// Forwarding: pick a chat, and a copy of the message goes there.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import '../state/rooms.dart';
import '../state/session.dart';
import '../state/views.dart';
import 'widgets/avatar.dart';

const forwardIcon = Icons.forward_rounded;

/// Asks which chat to forward [eventId] from [roomId] to, sends it there
/// and says how it went in a snack bar.
Future<void> forwardMessage(BuildContext context, WidgetRef ref, {required String roomId, required String eventId}) async {
  final messenger = ScaffoldMessenger.of(context);
  // The screen that asked may close while the picker is open.
  final core = ref.read(coreProvider);
  final target = await showModalBottomSheet<RoomSummary>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const ForwardPicker(),
  );
  if (target == null) return;
  try {
    await core.forward(roomId: roomId, eventId: eventId, toRoomId: target.id);
    messenger.showSnackBar(SnackBar(content: Text('Forwarded to ${target.name}')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text("Couldn't forward: $e")));
  }
}

/// The chats to forward to, newest first, with a search field. Pops the
/// chosen one.
class ForwardPicker extends ConsumerStatefulWidget {
  const ForwardPicker({super.key});

  @override
  ConsumerState<ForwardPicker> createState() => _ForwardPickerState();
}

class _ForwardPickerState extends ConsumerState<ForwardPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final rooms = [for (final r in ref.watch(inboxProvider) ?? const <RoomSummary>[]) if (!r.isInvite) r];
    final matches = jumpMatches(rooms, _query);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Forward to', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(hintText: 'Search chats', prefixIcon: Icon(Icons.search_rounded)),
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: matches.length,
              itemBuilder: (context, i) {
                final r = matches[i];
                return ListTile(
                  leading: RoomAvatar(room: r, size: 40),
                  title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: r.network == null ? null : Text(r.network!.name),
                  onTap: () => Navigator.pop(context, r),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
