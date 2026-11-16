import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/state/session.dart';
import 'package:switchboard/src/state/timeline.dart';
import 'package:switchboard/src/ui/chat_screen.dart';
import 'package:switchboard/src/ui/theme.dart';

const roomId = '!room:switchboard.internal';
final t0 = DateTime(2026, 10, 30, 9, 20).millisecondsSinceEpoch;

EventItem message(
  String id,
  String body, {
  bool own = false,
  SendState state = const SendState.sent(),
  String? txn,
  int minutes = 0,
}) =>
    EventItem(
      eventId: id.isEmpty ? null : id,
      transactionId: txn,
      canReply: id.isNotEmpty,
      canEdit: own,
      sender: own ? '@richard:switchboard.internal' : '@alice:switchboard.internal',
      senderName: own ? 'Richard' : 'Alice',
      isOwn: own,
      timestampMs: t0 + minutes * 60000,
      body: EventBody.text(body: body),
      sendState: state,
      reactions: const [],
      isEdited: false,
      readBy: const [],
    );

TimelineItem item(EventItem e) => TimelineItem(uniqueId: e.eventId ?? e.transactionId!, kind: TimelineItemKind.event(e));

class FakeTimeline extends TimelineNotifier {
  FakeTimeline(this.items) : super(roomId);
  final List<EventItem> items;
  final calls = <String>[];

  @override
  TimelineState build() => TimelineState(items: [for (final e in items) item(e)], atStart: true);

  @override
  Future<void> send(String body, {List<String> mentions = const []}) async =>
      calls.add(['send $body', ...mentions].join(' '));
  @override
  Future<void> reply(String body, String eventId, {List<String> mentions = const []}) async =>
      calls.add('reply $eventId $body');
  @override
  Future<void> edit(String id, String body) async => calls.add('edit $id $body');
  @override
  Future<void> unsend(String id) async => calls.add('unsend $id');
  @override
  Future<void> retry(String transactionId) async => calls.add('retry $transactionId');
  @override
  Future<void> cancel(String transactionId) async => calls.add('cancel $transactionId');
  @override
  Future<void> react(String eventId, String key) async => calls.add('react $eventId $key');
  @override
  Future<void> sendFile(String path, String mimeType, {int? width, int? height, int? durationMs, bool isVoice = false}) async =>
      calls.add('file $path $mimeType');
}

final room = RoomSummary(
  id: roomId,
  name: 'Alice',
  isDm: true,
  dmUserIds: const ['@alice:switchboard.internal'],
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

final notices = <bool>[];

Future<FakeTimeline> open(
  WidgetTester tester,
  List<EventItem> events, {
  List<Member> typing = const [],
  List<Member> members = const [],
  RoomFeatures? features,
}) async {
  notices.clear();
  final fake = FakeTimeline(events);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      timelineProvider(roomId).overrideWith(() => fake),
      roomSummaryProvider(roomId).overrideWithValue(room),
      syncStatusProvider.overrideWithValue(const AsyncData(SyncStatus.running)),
      membersProvider(roomId).overrideWith((ref) async => {for (final m in members) m.userId: m}),
      typingProvider(roomId).overrideWith((ref) => Stream.value(typing)),
      typingNoticeProvider(roomId).overrideWithValue(notices.add),
      roomFeaturesProvider(roomId).overrideWith((ref) async => features),
    ],
    child: const MaterialApp(home: ChatScreen(roomId: roomId)),
  ));
  // The typing dots animate forever, so pump frames rather than settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return fake;
}

void main() {
  testWidgets('edit your own message from the long-press menu', (tester) async {
    final fake = await open(tester, [message(r'$1', 'Hello', own: true)]);
    await tester.longPress(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Unsend'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Hello there');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(fake.calls, [r'edit $1 Hello there']);
    expect(find.text('Editing message'), findsNothing);
  });

  testWidgets("swipe right to reply to someone else's message", (tester) async {
    final fake = await open(tester, [message(r'$2', 'Are you around?')]);
    expect(find.text('Edit'), findsNothing);
    await tester.drag(find.text('Are you around?'), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Alice'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Yes');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(fake.calls, [r'reply $2 Yes']);
  });

  testWidgets('a failed message can be retried or dropped', (tester) async {
    final failed = message('', 'Lost', own: true, txn: 'txn1', state: const SendState.failed(error: 'offline', recoverable: true));
    final fake = await open(tester, [failed]);
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);

    await tester.tap(find.text('Lost'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lost'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't send"));
    await tester.pumpAndSettle();
    expect(fake.calls, ['retry txn1', 'cancel txn1']);
  });

  testWidgets('a plain message sends as text', (tester) async {
    final fake = await open(tester, const []);
    await tester.enterText(find.byType(TextField), '  hi  ');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(fake.calls, ['send hi']);
  });

  testWidgets('typing: shows who is typing and sends our own notices', (tester) async {
    await open(tester, const [], typing: [Member(userId: '@alice:switchboard.internal', name: 'Alice')]);
    expect(find.text('Alice is typing'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'h');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(notices, [true], reason: 'one notice per 3 s while typing');

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(notices, [true, false], reason: 'sending stops typing');
  });

  testWidgets('"Seen" under your message in a DM', (tester) async {
    final read = EventItem(
      eventId: r'$9',
      canReply: true,
      canEdit: true,
      sender: '@richard:switchboard.internal',
      isOwn: true,
      timestampMs: t0,
      body: const EventBody.text(body: 'Read me'),
      sendState: const SendState.sent(),
      reactions: const [],
      isEdited: false,
      readBy: const ['@alice:switchboard.internal'],
    );
    await open(tester, [read]);
    expect(find.text('Seen'), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
  });

  testWidgets('a bridge delivery failure shows on the message and offers Send again', (tester) async {
    final status = EventItem(
      eventId: r'$s1',
      canReply: false,
      canEdit: false,
      sender: '@whatsappbot:switchboard.internal',
      isOwn: false,
      timestampMs: t0,
      body: const EventBody.sendStatus(
        forEventId: r'$1',
        status: BridgeStatus.retriable,
        message: 'Not delivered to WhatsApp',
      ),
      sendState: const SendState.sent(),
      reactions: const [],
      isEdited: false,
      readBy: const [],
    );
    final fake = await open(tester, [message(r'$1', 'Hello', own: true), status]);
    expect(find.textContaining('Unsupported'), findsNothing, reason: 'status events are not shown');
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);

    await tester.tap(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(find.text('Not delivered'), findsOneWidget);
    expect(find.text('Not delivered to WhatsApp'), findsOneWidget);
    await tester.tap(find.text('Send again'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['send Hello']);
  });

  testWidgets("actions the network can't do are hidden", (tester) async {
    const noEdits = RoomFeatures(
      reply: 2,
      edit: -2,
      delete: 2,
      reaction: 0,
      allowedReactions: [],
      images: false,
      video: false,
      audio: false,
      voice: false,
      files: false,
      typingNotifications: false,
      readReceipts: true,
    );
    await open(tester, [message(r'$1', 'Hello', own: true)], features: noEdits);
    expect(find.byIcon(Icons.add_circle_outline_rounded), findsNothing, reason: 'no media on this network');
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing, reason: 'no voice notes either');

    await tester.longPress(find.text('Hello'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Unsend'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('👍'), findsNothing);
  });

  testWidgets('@ suggests members and sends a pill with m.mentions', (tester) async {
    final fake = await open(tester, const [], members: const [
      Member(userId: '@alice:switchboard.internal', name: 'Alice Smith'),
      Member(userId: '@bob:switchboard.internal', name: 'Bob'),
    ]);
    await tester.enterText(find.byType(TextField), 'hi @al');
    await tester.pump();
    await tester.pump(); // members load
    expect(find.text('Alice Smith'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);

    await tester.tap(find.text('Alice Smith'));
    await tester.pump();
    expect(find.text('hi @Alice Smith '), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(fake.calls, [
      'send hi [Alice Smith](https://matrix.to/#/@alice:switchboard.internal) @alice:switchboard.internal',
    ]);
  });

  testWidgets('formatted messages render their styling and pills', (tester) async {
    final formatted = EventItem(
      eventId: r'$f',
      canReply: true,
      canEdit: false,
      sender: '@alice:switchboard.internal',
      isOwn: false,
      timestampMs: t0,
      body: const EventBody.text(
        body: '*bold* Richard',
        formattedHtml: '<strong>bold</strong> <a href="https://matrix.to/#/@richard:switchboard.internal">Richard</a>',
      ),
      sendState: const SendState.sent(),
      reactions: const [],
      isEdited: false,
      readBy: const [],
    );
    await open(tester, [formatted]);
    expect(find.text('bold Richard'), findsOneWidget, reason: 'the HTML is shown, not the plain fallback');
  });

  testWidgets('the mic shows while the composer is empty, Send once there is text', (tester) async {
    await open(tester, const []);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
  });

  testWidgets("a bridge's link preview shows under the message", (tester) async {
    final linked = EventItem(
      eventId: r'$l',
      canReply: true,
      canEdit: false,
      sender: '@alice:switchboard.internal',
      isOwn: false,
      timestampMs: t0,
      body: const EventBody.text(body: 'look https://example.com/x'),
      sendState: const SendState.sent(),
      reactions: const [],
      isEdited: false,
      readBy: const [],
      linkPreview: const LinkPreview(
        url: 'https://example.com/x',
        title: 'Example page',
        description: 'What the sender saw',
        siteName: 'Example',
      ),
    );
    await open(tester, [linked]);
    expect(find.text('Example page'), findsOneWidget);
    expect(find.text('What the sender saw'), findsOneWidget);
  });

  testWidgets('conversation golden: every bubble state', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    EventItem ev(
      String id,
      EventBody body, {
      bool own = false,
      String sender = '@alice:switchboard.internal',
      String? name = 'Alice',
      int minutes = 0,
      SendState state = const SendState.sent(),
      List<Reaction> reactions = const [],
      ReplyPreview? reply,
      bool edited = false,
      List<String> readBy = const [],
      String? txn,
    }) =>
        EventItem(
          eventId: id.isEmpty ? null : id,
          transactionId: txn,
          canReply: true,
          canEdit: own,
          sender: own ? '@richard:switchboard.internal' : sender,
          senderName: own ? 'Richard' : name,
          isOwn: own,
          timestampMs: t0 + minutes * 60000,
          body: body,
          sendState: state,
          reactions: reactions,
          replyTo: reply,
          isEdited: edited,
          readBy: readBy,
        );
    final events = [
      ev(r'$1', const EventBody.text(body: 'Morning all'), minutes: 0),
      ev(r'$2', const EventBody.text(body: 'Who is in for lunch?'), minutes: 1,
          reactions: const [Reaction(key: '👍', count: 2, byMe: true)]),
      ev(r'$3', const EventBody.text(body: 'Me'), sender: '@bob:switchboard.internal', name: 'Bob', minutes: 2),
      ev(r'$4', const EventBody.text(body: 'Count me in'), own: true, minutes: 3,
          reply: const ReplyPreview(eventId: r'$2', senderName: 'Alice', text: 'Who is in for lunch?'),
          readBy: const ['@alice:switchboard.internal']),
      ev(r'$5', const EventBody.text(body: 'Fixed the typo'), own: true, minutes: 4, edited: true),
      ev(r'$6', const EventBody.redacted(), minutes: 5),
      ev('', const EventBody.text(body: 'On its way'), own: true, minutes: 6, txn: 't1', state: const SendState.sending()),
      ev('', const EventBody.text(body: 'This one failed'), own: true, minutes: 7, txn: 't2',
          state: const SendState.failed(error: 'offline', recoverable: true)),
    ];
    final fake = FakeTimeline(events);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        timelineProvider(roomId).overrideWith(() => fake),
        roomSummaryProvider(roomId).overrideWithValue(RoomSummary(
          id: roomId,
          name: 'Lunch',
          network: const Network(id: 'whatsapp', name: 'WhatsApp'),
          isDm: false,
          dmUserIds: const [],
          memberCount: 2,
          heroUserIds: const [],
          isInvite: false,
          isFavourite: false,
          isLowPriority: false,
          isMarkedUnread: false,
          unreadCount: 0,
          mentionCount: 0,
          unreadMessages: 0,
        )),
        syncStatusProvider.overrideWithValue(const AsyncData(SyncStatus.running)),
        membersProvider(roomId).overrideWith((ref) async => {
              '@alice:switchboard.internal': const Member(userId: '@alice:switchboard.internal', name: 'Alice'),
            }),
        typingProvider(roomId).overrideWith((ref) => Stream.value(const [])),
        typingNoticeProvider(roomId).overrideWithValue((_) {}),
        roomFeaturesProvider(roomId).overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: const ChatScreen(roomId: roomId),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(ChatScreen), matchesGoldenFile('goldens/conversation.png'));
  });

  group('desktop', () {
    final linux = TargetPlatformVariant.only(TargetPlatform.linux);

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {bool shift = false}) async {
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(k);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    testWidgets('Enter sends and Shift+Enter does not', variant: linux, (tester) async {
      final fake = await open(tester, const []);
      await tester.enterText(find.byType(TextField), 'hi');
      await key(tester, LogicalKeyboardKey.enter, shift: true);
      expect(fake.calls, isEmpty);
      await key(tester, LogicalKeyboardKey.enter);
      expect(fake.calls, ['send hi']);
    });

    testWidgets('↑ in an empty composer edits your last message, Esc cancels', variant: linux, (tester) async {
      await open(tester, [
        message(r'$1', 'First', own: true),
        message(r'$2', 'Second', own: true, minutes: 1),
        message(r'$3', 'From Alice', minutes: 2),
      ]);
      await tester.showKeyboard(find.byType(TextField));
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(find.text('Editing message'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Second'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('Editing message'), findsNothing);
      expect(find.widgetWithText(TextField, 'Second'), findsNothing);
    });

    testWidgets('right-click opens the actions as a menu, with reactions', variant: linux, (tester) async {
      final fake = await open(tester, [message(r'$2', 'Are you around?')]);
      await tester.tap(find.text('Are you around?'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Reply'), findsOneWidget);
      await tester.tap(find.text('👍'));
      await tester.pumpAndSettle();
      expect(fake.calls, [r'react $2 👍']);

      await tester.tap(find.text('Are you around?'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.text('Replying to Alice'), findsOneWidget);
    });

    Future<void> paste(WidgetTester tester, {List<String> files = const [], String? text}) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('pasteboard'),
        (call) async => call.method == 'files' ? files : null,
      );
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData' ? {'text': text} : null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(const MethodChannel('pasteboard'), null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.showKeyboard(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl+V with a copied file asks, then sends it', variant: linux, (tester) async {
      final fake = await open(tester, const []);
      await paste(tester, files: ['/home/me/report.pdf']);
      expect(find.text('Send report.pdf?'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(fake.calls, ['file /home/me/report.pdf application/pdf']);
    });

    testWidgets('Ctrl+V with only text pastes the text', variant: linux, (tester) async {
      final fake = await open(tester, const []);
      await paste(tester, text: 'hello');
      expect(find.widgetWithText(TextField, 'hello'), findsOneWidget);
      expect(fake.calls, isEmpty);
    });

    testWidgets('hovering a message shows Reply', variant: linux, (tester) async {
      await open(tester, [message(r'$2', 'Are you around?')]);
      final reply = find.byTooltip('Reply');
      expect(tester.widget<Visibility>(find.ancestor(of: reply, matching: find.byType(Visibility))).visible, isFalse);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('Are you around?')));
      await tester.pump();
      expect(tester.widget<Visibility>(find.ancestor(of: reply, matching: find.byType(Visibility))).visible, isTrue);

      await tester.tap(reply);
      await tester.pump();
      expect(find.text('Replying to Alice'), findsOneWidget);
    });
  });
}
