import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/timeline.dart';

TimelineItem message(int i) => TimelineItem(
      uniqueId: 'e$i',
      kind: TimelineItemKind.event(EventItem(
        canReply: true,
        canEdit: false,
        sender: '@a:x',
        isOwn: false,
        timestampMs: i,
        body: const EventBody.text(body: 'hi'),
        sendState: const SendState.sent(),
        reactions: const [],
        isEdited: false,
        readBy: const [],
      )),
    );

void main() {
  test('a chat opened from a notification, holding one message, pages back', () {
    final one = TimelineState(items: [const TimelineItem(uniqueId: 'd', kind: TimelineItemKind.dateDivider(timestampMs: 0)), message(1)]);
    expect(needsOlder(one), isTrue);
  });

  test('stops once the screen is full, at the start of the chat, or while paging', () {
    final full = TimelineState(items: [for (var i = 0; i < wantedMessages; i++) message(i)]);
    expect(needsOlder(full), isFalse);
    expect(needsOlder(TimelineState(items: [message(1)], atStart: true)), isFalse);
    expect(needsOlder(TimelineState(items: [message(1)], paginating: true)), isFalse);
    expect(needsOlder(const TimelineState()), isFalse, reason: 'nothing loaded yet');
  });
}
