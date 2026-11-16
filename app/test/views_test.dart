import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/views.dart';
import 'package:switchboard/src/ui/chat_list_screen.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');
const sig = Network(id: 'signal', name: 'Signal');

RoomSummary room(String id, Network? n, {int unread = 0, bool low = false, int messages = 0}) => RoomSummary(
      id: id,
      name: id,
      network: n,
      isDm: true,
      dmUserIds: const [],
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: low,
      isMarkedUnread: false,
      unreadCount: unread,
      mentionCount: 0,
      unreadMessages: messages,
    );

Bridge bridge(String id, String name, List<BridgeLogin> logins) =>
    Bridge(id: id, network: name, reachable: true, supportsApi: true, networkId: id, logins: logins);

BridgeLogin login(String id, String space) => BridgeLogin(id: id, name: 'Login $id', state: 'CONNECTED', spaceRoom: space);

void main() {
  test('views: all chats, then each network, with accounts only when a network has several', () {
    final views = inboxViews(
      [room('a', wa), room('t', const Network(id: 'telegram', name: 'Telegram'))],
      [
        bridge('whatsapp', 'WhatsApp', [login('1', '!s1'), login('2', '!s2')]),
        bridge('signal', 'Signal', [login('3', '!s3')]),
      ],
    );
    // Telegram has chats but no linked account, so it isn't offered.
    expect(views.map((v) => v.title), ['Inbox', 'Favourites', 'Notes', 'Low Priority', 'Archive', 'Signal', 'WhatsApp', 'Login 1', 'Login 2']);
    // A bridge with no account isn't offered either.
    final unlinked = inboxViews(const [], [bridge('discordgo', 'Discord', const [])]);
    expect(unlinked.map((v) => v.title), ['Inbox', 'Favourites', 'Notes', 'Low Priority', 'Archive']);
    // Before the Hub answers, the chats' networks stand in.
    expect(inboxViews([room('t', const Network(id: 'telegram', name: 'Telegram'))], const []).last.title, 'Telegram');
  });

  test('archived chats leave every view but the Archive, and return when someone else writes', () {
    RoomSummary chat({int? archivedAt, int? ts, bool own = false, bool markedUnread = false}) => RoomSummary(
          id: '!c',
          name: 'c',
          network: wa,
          isDm: true,
          dmUserIds: const [],
          memberCount: 2,
          heroUserIds: const [],
          isInvite: false,
          isFavourite: false,
          isLowPriority: false,
          isMarkedUnread: markedUnread,
          archivedAt: archivedAt,
          preview: ts == null ? null : Preview(isOwn: own, text: 'hi', sending: false, failed: false, isMembership: false),
          timestampMs: ts,
          unreadCount: 0,
          mentionCount: 0,
          unreadMessages: 0,
        );
    expect(isArchived(chat()), isFalse);
    expect(isArchived(chat(archivedAt: 100, ts: 50)), isTrue);
    expect(isArchived(chat(archivedAt: 100, ts: 150)), isFalse, reason: 'someone wrote since');
    expect(isArchived(chat(archivedAt: 100, ts: 150, own: true)), isTrue, reason: 'your own messages keep it archived');
    expect(isArchived(chat(archivedAt: 100, ts: 50, markedUnread: true)), isFalse);
    expect(isArchived(chat(), override: true), isTrue, reason: 'a tap shows at once');
    expect(inView(chat(), const AllChats(), archived: true), isFalse);
    expect(inView(chat(), const NetworkChats(wa), archived: true), isFalse);
    expect(inView(chat(), const ArchivedChats(), archived: true), isTrue);
    expect(inView(chat(), const ArchivedChats()), isFalse);
  });

  test('Notes holds the Switchboard note and bridged chats with only you and the bot', () {
    const bots = {'@signalbot:x'};
    RoomSummary withMembers(String id, Network? n, int count, List<String> heroes) => RoomSummary(
          id: id,
          name: id,
          network: n,
          isDm: true,
          dmUserIds: const [],
          memberCount: count,
          heroUserIds: heroes,
          isInvite: false,
          isFavourite: false,
          isLowPriority: false,
          isMarkedUnread: false,
          unreadCount: 0,
          mentionCount: 0,
          unreadMessages: 0,
        );
    expect(isSelfChat(withMembers('!note', null, 1, const []), bots, '!note'), isTrue);
    expect(isSelfChat(withMembers('!test', null, 1, const []), bots, '!note'), isFalse, reason: 'other rooms alone are not notes');
    expect(isSelfChat(withMembers('!sig', sig, 2, const ['@signalbot:x']), bots, null), isTrue);
    expect(isSelfChat(withMembers('!dm', sig, 3, const ['@signalbot:x', '@signal_a:x']), bots, null), isFalse);
    expect(isSelfChat(withMembers('!dm2', sig, 2, const ['@signal_a:x']), bots, null), isFalse);
    expect(inView(withMembers('!sig', sig, 2, const []), const NotesChats(), selfChats: {'!sig'}), isTrue);
    expect(inView(withMembers('!dm', sig, 2, const []), const NotesChats(), selfChats: {'!sig'}), isFalse);
  });

  test('a room is in its network view, and in an account view when in its space', () {
    final a = room('!a', wa);
    expect(inView(a, const AllChats()), isTrue);
    expect(inView(a, const NetworkChats(wa)), isTrue);
    expect(inView(a, const NetworkChats(sig)), isFalse);
    expect(inView(room('!plain', null), const NetworkChats(wa)), isFalse);

    final account = AccountChats(wa, login('1', '!s1'));
    expect(inView(a, account, spaceRooms: {'!a'}), isTrue);
    expect(inView(a, account, spaceRooms: {'!b'}), isFalse);
    expect(inView(a, account), isTrue, reason: 'falls back to the network while the space loads');
  });

  test('favourites keep their drag order; unordered ones follow, newest first', () {
    RoomSummary fav(String id, double? order) => RoomSummary(
          id: id,
          name: id,
          isDm: true,
          dmUserIds: const [],
          memberCount: 2,
          heroUserIds: const [],
          isInvite: false,
          isFavourite: true,
          favouriteOrder: order,
          isLowPriority: false,
          isMarkedUnread: false,
          unreadCount: 0,
          mentionCount: 0,
          unreadMessages: 0,
        );
    // The list arrives newest first.
    final rooms = [fav('new', null), fav('b', 0.6), fav('old', null), fav('a', 0.3)];
    expect(byFavouriteOrder(rooms).map((r) => r.id), ['a', 'b', 'new', 'old']);
    expect(inView(fav('a', 0.3), const FavouriteChats()), isTrue);
    expect(inView(room('x', wa), const FavouriteChats()), isFalse);
    expect(spreadOrders(3), [0.25, 0.5, 0.75]);
    expect(orderAfter([fav('a', 0.3), fav('b', 0.6)]), closeTo(0.8, 1e-9));
    expect(orderAfter(const []), 0.5);
  });

  test('Alt+arrows step through the list and stop at the ends', () {
    final order = [room('!a', wa), room('!b', wa), room('!c', sig)];
    expect(stepChat(order, null, 1), '!a');
    expect(stepChat(order, null, -1), '!c');
    expect(stepChat(order, '!a', 1), '!b');
    expect(stepChat(order, '!c', 1), '!c');
    expect(stepChat(order, '!a', -1), '!a');
    expect(stepChat(const [], null, 1), isNull);
  });

  test('next unread is below the open chat and wraps to the top', () {
    final order = [room('!a', wa, unread: 1), room('!b', wa), room('!c', sig, unread: 3)];
    expect(nextUnread(order, null), '!a');
    expect(nextUnread(order, '!a'), '!c');
    expect(nextUnread(order, '!c'), '!a');
    expect(nextUnread([room('!a', wa, unread: 1)], '!a'), isNull, reason: 'only the open chat is unread');
    final low = [room('!a', wa, low: true), room('!b', wa, low: true, messages: 2)];
    expect(nextUnread(low, '!a'), '!b', reason: 'quiet Low Priority messages count');
  });

  test('jump matches names starting with the query first, ignoring case', () {
    final rooms = [room('Mum', wa), room('Team chat', sig), room('Tom', wa), room('Emma', sig)];
    expect(jumpMatches(rooms, ' ').map((r) => r.id), ['Mum', 'Team chat', 'Tom', 'Emma']);
    expect(jumpMatches(rooms, 'e').map((r) => r.id), ['Emma', 'Team chat']);
    expect(jumpMatches(rooms, 'TEAM').map((r) => r.id), ['Team chat']);
    expect(jumpMatches(rooms, 'om').map((r) => r.id), ['Tom']);
    expect(jumpMatches(rooms, 'zz'), isEmpty);
  });

  testWidgets('the switcher lists views with unread counts and selects one', (tester) async {
    final container = ProviderContainer(overrides: [
      inboxProvider.overrideWithValue([room('!a', wa, unread: 2), room('!b', wa, unread: 1), room('!c', sig)]),
      viewsProvider.overrideWithValue(const [AllChats(), NetworkChats(sig), NetworkChats(wa)]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(onPressed: () => showViewSwitcher(context), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Signal'), findsOneWidget);
    expect(find.text('2'), findsNWidgets(2), reason: 'two unread chats, all of them WhatsApp');

    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();
    expect(container.read(selectedViewProvider), const NetworkChats(wa));
  });
}
