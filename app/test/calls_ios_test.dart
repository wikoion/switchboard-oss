import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/calls.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/calls.dart';
import 'package:switchboard/src/state/calls_ios.dart';

const roomId = '!alice:x';
const aliceAci = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';

RoomSummary room({List<String> dm = const ['@signal_$aliceAci:x']}) => RoomSummary(
      id: roomId,
      name: 'Alice',
      network: const Network(id: 'signal', name: 'Signal'),
      isDm: true,
      dmUserIds: dm,
      memberCount: 2,
      heroUserIds: const [],
      isInvite: false,
      isFavourite: false,
      isLowPriority: false,
      isMarkedUnread: false,
      timestampMs: 0,
      unreadCount: 0,
      mentionCount: 0,
      unreadMessages: 0,
    );

CallSignal signal(CallSignalKind kind, {String callId = '18446744073709551615', bool video = false}) => CallSignal(
      roomId: roomId,
      kind: kind,
      callId: callId,
      senderDeviceId: 2,
      receiverDeviceId: 3,
      ageSecs: 1,
      senderIdentityKey: Uint8List.fromList(List.filled(32, 1)),
      receiverIdentityKey: Uint8List.fromList(List.filled(32, 2)),
      video: video,
      hangupType: 0,
      opaque: Uint8List.fromList([1, 2]),
      candidates: kind == CallSignalKind.ice ? [Uint8List.fromList([3]), Uint8List.fromList([4, 5])] : const [],
    );

class FakeSignals implements CallSignals {
  final incoming = StreamController<CallSignal>();
  final sent = <CallSignal>[];
  final rooms = <String?>[];
  int settingsAsked = 0;

  /// Holds settings back until completed, to check events wait in order.
  Completer<void>? holdSettings;

  @override
  Stream<CallSignal> subscribe() => incoming.stream;
  @override
  Future<void> send(CallSignal signal) async => sent.add(signal);
  @override
  Future<CallSettings> settings() async {
    settingsAsked++;
    await holdSettings?.future;
    return const CallSettings(
      deviceId: 3,
      iceServers: [IceServerSpec(username: 'u', password: 'p', hostname: 'turn.example', urls: ['turn:192.0.2.1'])],
    );
  }

  @override
  Future<void> setCallRoom(String? roomId) async => rooms.add(roomId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('switchboard/calls-test');
  late FakeSignals signals;
  late IosCallService service;
  late List<MethodCall> toSwift;
  RoomSummary? summary;

  setUp(() {
    signals = FakeSignals();
    toSwift = [];
    summary = room();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      toSwift.add(call);
      return null;
    });
    service = IosCallService(signals, room: (_) => summary, channel: channel);
  });

  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('passes call events to Swift in order, with the contact and our device', () async {
    signals.holdSettings = Completer();
    signals.incoming.add(signal(CallSignalKind.offer, video: true));
    signals.incoming.add(signal(CallSignalKind.ice));
    await settle();
    // The ICE waits behind the offer, which waits for the settings.
    expect(toSwift, isEmpty);
    signals.holdSettings!.complete();
    await settle();
    expect(toSwift.map((c) => (c.method, (c.arguments as Map)['kind'])), [('received', 'offer'), ('received', 'ice')]);
    final offer = toSwift.first.arguments as Map;
    expect(offer['uuid'], aliceAci);
    expect(offer['name'], 'Alice');
    expect(offer['localDevice'], 3);
    expect(offer['callId'], '18446744073709551615');
    expect(offer['video'], true);
    expect(offer['senderDeviceId'], 2);
    expect((offer['senderIdentityKey'] as Uint8List).length, 32);
    final ice = toSwift.last.arguments as Map;
    expect(ice.containsKey('localDevice'), isFalse);
    expect(ice['candidates'], [
      [3],
      [4, 5],
    ]);
  });

  test('skips call events in chats without a Signal contact', () async {
    summary = room(dm: const ['@whatsapp_1:x']);
    signals.incoming.add(signal(CallSignalKind.offer));
    await settle();
    expect(toSwift, isEmpty);
  });

  test("sends Swift's call events through the core", () async {
    await service.onSwift(MethodCall('send', {
      'roomId': roomId,
      'kind': 'hangup',
      'callId': '7',
      'destinationDeviceId': 2,
      'hangupType': 1,
      'hangupDeviceId': 3,
    }));
    await service.onSwift(MethodCall('send', {
      'roomId': roomId,
      'kind': 'ice',
      'callId': '7',
      'candidates': [Uint8List.fromList([1]), Uint8List.fromList([2])],
    }));
    final hangup = signals.sent.first;
    expect((hangup.kind, hangup.callId, hangup.destinationDeviceId), (CallSignalKind.hangup, '7', 2));
    expect((hangup.hangupType, hangup.hangupDeviceId), (1, 3));
    expect(signals.sent.last.candidates, [
      [1],
      [2],
    ]);
    expect(signals.sent.last.destinationDeviceId, isNull);
  });

  test("answers Swift's settings with the TURN servers", () async {
    final settings = await service.onSwift(const MethodCall('settings')) as Map;
    expect(settings['deviceId'], 3);
    expect(settings['iceServers'], [
      {'username': 'u', 'password': 'p', 'hostname': 'turn.example', 'urls': ['turn:192.0.2.1']},
    ]);
  });

  test("turns Swift's updates into call updates and follows the call's chat", () async {
    final updates = <CallUpdate>[];
    final sub = service.updates().listen(updates.add);
    for (final phase in ['incoming', 'ringing', 'connected', 'ended']) {
      await service.onSwift(MethodCall('update', {
        'roomId': roomId,
        'callId': '7',
        'phase': phase,
        'video': true,
        'remoteVideo': phase == 'connected',
        'reason': phase == 'ended' ? 'RemoteHangup' : null,
      }));
    }
    await settle();
    expect(updates.map((u) => u.phase), [CallPhase.incoming, CallPhase.ringing, CallPhase.connected, CallPhase.ended]);
    expect(updates[2].remoteVideo, isTrue);
    expect(updates.last.reason, 'RemoteHangup');
    expect(signals.rooms, [roomId, null]);
    await sub.cancel();
  });

  test('places calls to the Signal contact', () async {
    await service.place(roomId, video: true);
    expect(toSwift.single.method, 'place');
    expect(toSwift.single.arguments, {'roomId': roomId, 'uuid': aliceAci, 'name': 'Alice', 'video': true, 'localDevice': 3});
    summary = room(dm: const []);
    expect(() => service.place(roomId), throwsStateError);
  });

  test("follows the contact's video texture, upright", () async {
    expect(service.remoteTexture.value, isNull);
    await service.onSwift(const MethodCall('remoteVideo', {'textureId': 5, 'width': 640, 'height': 480, 'rotation': 90}));
    expect(service.remoteTexture.value, const CallTexture(id: 5, width: 640, height: 480, quarterTurns: 1));
    // Zero size: the call ended or the frames stopped.
    await service.onSwift(const MethodCall('remoteVideo', {'textureId': 5, 'width': 0, 'height': 0, 'rotation': 0}));
    expect(service.remoteTexture.value, isNull);
  });

  test("finds the contact's Signal ID in the chat's members", () {
    expect(signalContactUuid(room()), aliceAci);
    expect(signalContactUuid(room(dm: ['@signal_${aliceAci.toUpperCase()}:x'])), aliceAci);
    expect(signalContactUuid(room(dm: const ['@signalbot:x', '@whatsapp_1:x'])), isNull);
  });
}
