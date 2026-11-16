import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/client.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/media.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/search.dart';
import 'package:switchboard/src/state/session.dart';
import 'package:switchboard/src/state/timeline.dart';
import 'package:switchboard/src/ui/chat_media_screen.dart';
import 'package:switchboard/src/ui/chat_screen.dart';
import 'package:switchboard/src/ui/search_screen.dart';

const roomId = '!alice:switchboard.internal';
final t0 = DateTime(2026, 11, 2, 14, 5).millisecondsSinceEpoch;

final alice = RoomSummary(
  id: roomId,
  name: 'Alice',
  isDm: true,
  dmUserIds: const ['@alice:x'],
  memberCount: 2,
  heroUserIds: const [],
  isInvite: false,
  isFavourite: false,
  isLowPriority: false,
  isMarkedUnread: false,
  unreadCount: 0,
  mentionCount: 0,
  unreadMessages: 0,
);

IndexedMessage indexed(
  String id,
  String text, {
  MessageKind kind = MessageKind.text,
  String? name,
  String? url,
  bool own = false,
  int minutes = 0,
}) =>
    IndexedMessage(
      eventId: id,
      roomId: roomId,
      sender: own ? '@richard:x' : '@alice:x',
      senderName: own ? 'Richard' : 'Alice',
      isOwn: own,
      timestampMs: t0 + minutes * 60000,
      kind: kind,
      text: text,
      name: name,
      mxc: kind == MessageKind.text ? null : 'mxc://x/$id',
      size: kind == MessageKind.file ? 2048 : null,
      url: url,
    );

const status = IndexStatus(
  periodDays: 365,
  chats: 3,
  chatsDone: 3,
  messages: 120,
  bytes: 1200000,
  indexing: false,
);

/// Answers search and media calls from canned results, and records them.
class FakeCore implements SwitchboardCore {
  final calls = <String>[];
  List<SearchHit> local = const [];
  List<SearchHit> server = const [];
  Map<MediaTab, List<IndexedMessage>> pages = const {};

  @override
  Future<List<SearchHit>> searchMessages({
    required String query,
    String? roomId,
    int? sinceMs,
    int? untilMs,
    required int offset,
    required int limit,
  }) async {
    calls.add('local $query room=$roomId since=${sinceMs != null}');
    return offset == 0 ? local : const [];
  }

  @override
  Future<SearchPage> searchServer({
    required String query,
    String? roomId,
    int? sinceMs,
    int? untilMs,
    String? next,
  }) async {
    calls.add('server $query');
    return SearchPage(hits: server);
  }

  @override
  Future<MediaPage> chatMedia({required String roomId, required MediaTab tab, String? cursor, required int limit}) async {
    calls.add('media $tab');
    return MediaPage(items: pages[tab] ?? const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A 1×1 PNG, for thumbnails.
final pixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

List<Override> overrides(FakeCore core) => [
      coreProvider.overrideWithValue(core),
      inboxProvider.overrideWithValue([alice]),
      roomSummaryProvider(roomId).overrideWithValue(alice),
      indexStatusProvider.overrideWithValue(const AsyncData(status)),
      mediaProvider.overrideWith((ref, key) async => pixel),
      linkPreviewProvider.overrideWith((ref, url) async => null),
    ];

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  test('snippets bold the matched words', () {
    const base = TextStyle();
    const mark = TextStyle(fontWeight: FontWeight.w700);
    final spans = snippetSpans('see you at dinner then', base, mark);
    expect([for (final s in spans) (s.text, s.style == mark)], [
      ('see you at ', false),
      ('dinner', true),
      (' then', false),
    ]);
  });

  testWidgets('search finds messages, filters by date and asks the server for older ones', (tester) async {
    await phone(tester);
    final core = FakeCore()
      ..local = [SearchHit(message: indexed(r'$1', 'dinner tonight?'), snippet: 'dinner tonight?')]
      ..server = [SearchHit(message: indexed(r'$0', 'dinner in 2023', minutes: -60), snippet: 'dinner in 2023')];
    final opened = <String?>[];
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(core),
      child: MaterialApp(home: SearchPanel(onOpen: (_, e) => opened.add(e), onSettings: () {}, onClose: () {})),
    ));
    expect(find.text('Search chats, messages and files'), findsOneWidget);
    expect(find.text('This device searches the last year.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'dinner');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(core.calls, ['local dinner room=null since=false']);
    expect(find.text('Alice'), findsWidgets);
    expect(find.textContaining('dinner tonight?', findRichText: true), findsOneWidget);
    expect(find.textContaining('Searched the last year on this device', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Search older messages on the server'));
    await tester.pumpAndSettle();
    expect(core.calls.last, 'server dinner');
    expect(find.text('On the server'), findsOneWidget);
    expect(find.textContaining('dinner in 2023', findRichText: true), findsOneWidget);
    expect(find.text('Nothing else on the server'), findsNothing);

    await tester.tap(find.textContaining('dinner tonight?', findRichText: true));
    expect(opened, [r'$1']);

    await tester.tap(find.text('Any time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Past week'));
    await tester.pumpAndSettle();
    expect(core.calls.last, 'local dinner room=null since=true');
    expect(find.text('Past week'), findsOneWidget);
  });

  testWidgets('search in one chat can widen to every chat', (tester) async {
    await phone(tester);
    final core = FakeCore();
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(core),
      child: MaterialApp(home: SearchPanel(roomId: roomId, onOpen: (_, _) {}, onSettings: () {}, onClose: () {})),
    ));
    expect(find.text('Search in Alice'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'pub');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(core.calls.last, 'local pub room=$roomId since=false');
    expect(find.text('No messages found'), findsOneWidget);

    await tester.tap(find.byTooltip('Search all chats instead'));
    await tester.pumpAndSettle();
    expect(core.calls.last, 'local pub room=null since=false');
  });

  testWidgets('a chat opened at a search result lights it up and jumps back to the latest', (tester) async {
    await phone(tester);
    EventItem message(String id, String body, int minutes) => EventItem(
          eventId: id,
          canReply: true,
          canEdit: false,
          sender: '@alice:x',
          senderName: 'Alice',
          isOwn: false,
          timestampMs: t0 + minutes * 60000,
          body: EventBody.text(body: body),
          sendState: const SendState.sent(),
          reactions: const [],
          isEdited: false,
          readBy: const [],
        );
    TimelineItem item(EventItem e) => TimelineItem(uniqueId: e.eventId!, kind: TimelineItemKind.event(e));
    final around = [for (var i = 0; i < 5; i++) message('\$old$i', 'old message $i', i)];
    final live = [message(r'$new', 'newest message', 600)];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...overrides(FakeCore()),
        syncStatusProvider.overrideWithValue(const AsyncData(SyncStatus.running)),
        focusedTimelineProvider((roomId: roomId, eventId: r'$old2'))
            .overrideWith(() => _FakeFocused([for (final e in around) item(e)])),
        timelineProvider(roomId).overrideWith(() => _FakeLive([for (final e in live) item(e)])),
        membersProvider(roomId).overrideWith((ref) async => const {}),
        typingProvider(roomId).overrideWith((ref) => Stream.value(const [])),
        typingNoticeProvider(roomId).overrideWithValue((_) {}),
        roomFeaturesProvider(roomId).overrideWith((ref) async => null),
      ],
      child: const MaterialApp(home: ChatScreen(roomId: roomId, focusEventId: r'$old2')),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('old message 2'), findsOneWidget);
    expect(find.text('newest message'), findsNothing);
    final lit = tester.widget<AnimatedContainer>(
      find.ancestor(of: find.text('old message 2'), matching: find.byType(AnimatedContainer)).first,
    );
    expect((lit.decoration! as BoxDecoration).color, isNot(Colors.transparent));

    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('newest message'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the media page shows photos by month, files and links', (tester) async {
    await phone(tester);
    final core = FakeCore()
      ..pages = {
        MediaTab.media: [
          indexed(r'$p1', 'IMG_1.jpg', kind: MessageKind.image, name: 'IMG_1.jpg'),
          indexed(r'$p0', 'IMG_0.jpg', kind: MessageKind.image, name: 'IMG_0.jpg', minutes: -60 * 24 * 40),
        ],
        MediaTab.files: [indexed(r'$f', 'invoice.pdf', kind: MessageKind.file, name: 'invoice.pdf', own: true)],
        MediaTab.links: [indexed(r'$l', 'look https://example.com/x', url: 'https://example.com/x')],
      };
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(core),
      child: const MaterialApp(home: ChatMediaScreen(roomId: roomId)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('invoice.pdf'), findsOneWidget);
    expect(find.textContaining('2.0 KB · You'), findsOneWidget);

    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.textContaining('Links from the last year'), findsOneWidget);
    expect(core.calls, containsAll(['media MediaTab.media', 'media MediaTab.files', 'media MediaTab.links']));
  });

  testWidgets('a photo opens full screen with save and show in chat', (tester) async {
    await phone(tester);
    final core = FakeCore()
      ..pages = {
        MediaTab.media: [indexed(r'$p1', 'Sunset', kind: MessageKind.image, name: 'IMG_1.jpg')],
      };
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(core),
      child: const MaterialApp(home: ChatMediaScreen(roomId: roomId)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save to Photos'), findsOneWidget);
    expect(find.byTooltip('Show in chat'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    // The body differs from the file name, so it's a caption.
    expect(find.text('Sunset'), findsOneWidget);
  });
}

class _FakeFocused extends FocusedTimelineNotifier {
  _FakeFocused(this.items) : super((roomId: roomId, eventId: r'$old2'));
  final List<TimelineItem> items;

  @override
  TimelineState build() => TimelineState(items: items, atStart: true, atEnd: false);

  @override
  Future<void> loadOlder() async {}

  @override
  Future<void> loadNewer() async {}
}

class _FakeLive extends TimelineNotifier {
  _FakeLive(this.items) : super(roomId);
  final List<TimelineItem> items;

  @override
  TimelineState build() => TimelineState(items: items, atStart: true);

  @override
  Future<void> loadOlder() async {}
}
