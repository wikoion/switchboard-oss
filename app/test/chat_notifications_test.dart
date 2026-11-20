import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/desktop.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/notify.dart';

const wa = Network(id: 'whatsapp', name: 'WhatsApp');
const alicePicture = 'mxc://example.org/alice';
const chatPicture = 'mxc://example.org/chat';
const mumPicture = 'mxc://example.org/mum';
const familyPicture = 'mxc://example.org/family';

// A 1×1 PNG.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

RoomSummary room(
  String id,
  int unread, {
  String name = 'Alice',
  bool dm = true,
  String? sender,
  String text = 'See you at 7',
  String? picture,
  String? senderPicture,
}) =>
    RoomSummary(
      id: id,
      name: name,
      avatarMxc: picture,
      network: wa,
      isDm: dm,
      dmUserIds: const [],
      memberCount: dm ? 2 : 5,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      preview: Preview(
        senderName: sender,
        senderAvatarMxc: senderPicture,
        isOwn: false,
        text: text,
        sending: false,
        failed: false,
        isMembership: false,
      ),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      unreadCount: unread,
      mentionCount: 0,
      unreadMessages: unread,
    );

RoomSummary alice(int unread, {String text = 'See you at 7', String? senderPicture = alicePicture}) =>
    room('!alice', unread, text: text, picture: chatPicture, senderPicture: senderPicture);

RoomSummary family(int unread, {String? senderPicture = mumPicture}) => room(
      '!family',
      unread,
      name: 'Family',
      dm: false,
      sender: 'Mum',
      text: 'Photo',
      picture: familyPicture,
      senderPicture: senderPicture,
    );

typedef Shown = ({int id, String? title, String? body, String? payload, LinuxNotificationIcon? icon});

/// Stands in for the notification server.
class FakeNotifications extends Fake implements LinuxFlutterLocalNotificationsPlugin {
  final shown = <Shown>[];
  final cancelled = <int>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    LinuxNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload, icon: notificationDetails?.icon));
  }

  @override
  Future<void> cancel({required int id}) async => cancelled.add(id);
}

/// The notifications of one run of the app.
class Harness {
  Harness({Future<Uint8List> Function(String mxc)? picture}) {
    chats = ChatNotifications(
      server,
      hideSender: () async => hide ?? (throw const FileSystemException('unreadable')),
      picture: (mxc) {
        fetched.add(mxc);
        return (picture ?? (_) async => png)(mxc);
      },
    );
  }

  final server = FakeNotifications();
  late final ChatNotifications chats;

  /// The setting. Null makes reading it fail.
  bool? hide = false;

  /// The pictures asked for.
  final fetched = <String>[];

  /// Starts from [before] and moves to [after], then waits for [count]
  /// notifications in all.
  Future<void> receive(List<RoomSummary> before, List<RoomSummary> after, {int count = 1}) async {
    chats.update(before);
    chats.update(after);
    await settle(count);
  }

  /// Pictures are decoded by the engine, so wait in real time.
  Future<void> settle(int count) async {
    for (var i = 0; i < 300 && server.shown.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(server.shown, hasLength(count));
  }
}

void expectStockIcon(Shown n) {
  final icon = n.icon;
  expect(icon, isA<AssetsLinuxIcon>(), reason: 'the picture is a bundled asset');
  expect((icon as AssetsLinuxIcon).relativePath, 'assets/icon/switchboard-256.png');
}

void expectNamesNobody(Shown n) {
  for (final name in ['Alice', 'Mum', 'Family']) {
    expect('${n.title}\n${n.body}', isNot(contains(name)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("by default a notification names the sender and shows their picture", () async {
    final h = Harness();
    await h.receive([alice(0)], [alice(1)]);
    final n = h.server.shown.single;
    expect(n.title, 'Alice · WhatsApp');
    expect(n.body, 'See you at 7');
    expect(n.payload, '!alice');
    expect(n.id, notificationId('!alice'));
    expect(h.fetched, [alicePicture]);
    final picture = (n.icon as ByteDataLinuxIcon).iconData;
    expect((picture.width, picture.height, picture.channels, picture.hasAlpha), (1, 1, 4, true));
    expect(picture.data, hasLength(4), reason: 'raw pixels, as the notification server takes them');
  });

  test("in a group the picture is the sender's, not the group's", () async {
    final h = Harness();
    await h.receive([family(0)], [family(1)]);
    expect(h.server.shown.single.title, 'Mum in Family · WhatsApp');
    expect(h.server.shown.single.icon, isA<ByteDataLinuxIcon>());
    expect(h.fetched, [mumPicture]);
  });

  test('a sender with no picture gets the Switchboard icon', () async {
    final h = Harness();
    await h.receive([family(0, senderPicture: null)], [family(1, senderPicture: null)]);
    expect(h.server.shown.single.title, 'Mum in Family · WhatsApp');
    expectStockIcon(h.server.shown.single);
    expect(h.fetched, isEmpty, reason: "the group's picture isn't the sender's");

    // Nor is a direct chat's picture used in the sender's place.
    final direct = Harness();
    await direct.receive([alice(0, senderPicture: null)], [alice(1, senderPicture: null)]);
    expect(direct.server.shown.single.title, 'Alice · WhatsApp');
    expectStockIcon(direct.server.shown.single);
    expect(direct.fetched, isEmpty);
  });

  test("a picture that can't be fetched or read gets the Switchboard icon", () async {
    final offline = Harness(picture: (_) async => throw const SocketException('offline'));
    await offline.receive([alice(0)], [alice(1)]);
    expect(offline.server.shown.single.title, 'Alice · WhatsApp');
    expectStockIcon(offline.server.shown.single);

    final broken = Harness(picture: (_) async => Uint8List.fromList(utf8.encode('<html>not found</html>')));
    await broken.receive([alice(0)], [alice(1)]);
    expectStockIcon(broken.server.shown.single);
  });

  test('hiding the sender shows no name, chat or picture, only the Switchboard icon', () async {
    final h = Harness()..hide = true;
    await h.receive([alice(0), family(0)], [alice(1), family(1)], count: 2);
    for (final n in h.server.shown) {
      expect(n.title, 'New message · WhatsApp');
      expectNamesNobody(n);
      expectStockIcon(n);
    }
    expect(h.server.shown.map((n) => n.body), ['See you at 7', 'Photo']);
    expect(h.fetched, isEmpty, reason: "senders' pictures aren't even fetched");
    // Clicking one still opens its chat.
    expect(h.server.shown.map((n) => n.payload), ['!alice', '!family']);
  });

  test('turning the setting off again restores the sender for the next notification', () async {
    final h = Harness()..hide = true;
    await h.receive([alice(0)], [alice(1)]);
    expectNamesNobody(h.server.shown.last);
    expectStockIcon(h.server.shown.last);

    h.hide = false;
    h.chats.update([alice(2, text: 'Running late')]);
    await h.settle(2);
    expect(h.server.shown.last.title, 'Alice · WhatsApp');
    expect(h.server.shown.last.body, 'Running late');
    expect(h.server.shown.last.icon, isA<ByteDataLinuxIcon>());

    h.hide = true;
    h.chats.update([alice(3, text: 'Here')]);
    await h.settle(3);
    expectNamesNobody(h.server.shown.last);
    expectStockIcon(h.server.shown.last);
  });

  test("senders stay hidden when the setting can't be read", () async {
    final h = Harness()..hide = null;
    await h.receive([alice(0)], [alice(1)]);
    expectNamesNobody(h.server.shown.single);
    expectStockIcon(h.server.shown.single);
    expect(h.fetched, isEmpty);
  });

  test('a burst gets one summary with the Switchboard icon', () async {
    final h = Harness();
    final ids = ['!a', '!b', '!c', '!d'];
    await h.receive([for (final id in ids) room(id, 0)], [for (final id in ids) room(id, 1)]);
    expect(h.server.shown.single.title, 'Switchboard');
    expect(h.server.shown.single.body, '4 chats have new messages');
    expectStockIcon(h.server.shown.single);
  });

  test('a chat read while its picture loads never notifies, and a read chat is taken down', () async {
    final picture = Completer<Uint8List>();
    final h = Harness(picture: (_) => picture.future);
    h.chats.update([alice(0)]);
    h.chats.update([alice(1)]);
    h.chats.update([alice(0)]);
    picture.complete(png);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.server.shown, isEmpty);
    expect(h.server.cancelled, [notificationId('!alice')]);
  });

  test('a newer message is never replaced by an older one whose picture came late', () async {
    final pictures = [Completer<Uint8List>(), Completer<Uint8List>()];
    var asked = 0;
    final h = Harness(picture: (_) => pictures[asked++].future);
    h.chats.update([alice(0)]);
    h.chats.update([alice(1, text: 'First')]);
    h.chats.update([alice(2, text: 'Second')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    pictures[1].complete(png);
    await h.settle(1);
    pictures[0].complete(png);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.server.shown.map((n) => n.body), ['Second']);
  });

  test('the Switchboard icon ships in the bundle', () async {
    final bundled = await rootBundle.load(notificationIcon);
    final source = File('assets/icon/switchboard-256.png').readAsBytesSync();
    expect(bundled.buffer.asUint8List(bundled.offsetInBytes, bundled.lengthInBytes), source);
    // A PNG: the app's own artwork, not a name for the icon theme to find.
    expect(source.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });
}
