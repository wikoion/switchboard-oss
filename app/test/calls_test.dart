import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/rust/api/calls.dart';
import 'package:switchboard/src/rust/api/types.dart';
import 'package:switchboard/src/state/calls.dart';
import 'package:switchboard/src/state/rooms.dart';
import 'package:switchboard/src/ui/theme.dart';
import 'package:switchboard/src/ui/widgets/call_panel.dart';

const roomId = '!alice:x';
const sig = Network(id: 'signal', name: 'Signal');

RoomSummary room({Network? network = sig, bool dm = true}) => RoomSummary(
      id: roomId,
      name: 'Alice',
      network: network,
      isDm: dm,
      dmUserIds: const [],
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

CallUpdate update(
  CallPhase phase, {
  String callId = '7',
  bool video = false,
  bool remoteVideo = false,
  String? reason,
}) =>
    CallUpdate(roomId: roomId, callId: callId, phase: phase, video: video, remoteVideo: remoteVideo, reason: reason);

class FakeCalls implements CallService {
  final _updates = StreamController<CallUpdate>.broadcast();
  final log = <String>[];

  void emit(CallUpdate u) => _updates.add(u);

  @override
  Stream<CallUpdate> updates() => _updates.stream;
  @override
  Future<void> place(String roomId, {bool video = false}) async => log.add('place $roomId${video ? ' video' : ''}');
  @override
  Future<void> accept(String callId, {bool video = false}) async => log.add('accept $callId${video ? ' video' : ''}');
  @override
  Future<void> hangUp() async => log.add('hang up');
  @override
  Future<void> setMuted(bool muted) async => log.add('muted $muted');
  @override
  Future<void> setVideo(bool enabled) async => log.add('video $enabled');
  @override
  Future<CallFrame?> frame({required bool remote, required int maxWidth, required int maxHeight}) async => null;
  @override
  ValueListenable<CallTexture?> get remoteTexture => noCallTexture;
}

/// The panel over an empty screen, with [calls] as the core.
Widget app(FakeCalls calls) => ProviderScope(
      overrides: [
        callServiceProvider.overrideWith((ref) async => calls),
        roomSummaryProvider(roomId).overrideWithValue(room()),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(),
        builder: (_, child) => CallPanel(child: child!),
      ),
    );

/// Lets the stream deliver and the panel rebuild.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  test('only Signal DMs can be called', () {
    expect(canCall(room()), isTrue);
    expect(canCall(room(dm: false)), isFalse);
    expect(canCall(room(network: const Network(id: 'whatsapp', name: 'WhatsApp'))), isFalse);
    expect(canCall(room(network: null)), isFalse);
  });

  test('call durations', () {
    expect(callDuration(const Duration(seconds: 42)), '0:42');
    expect(callDuration(const Duration(minutes: 12, seconds: 3)), '12:03');
    expect(callDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  test('a connected call shows how long it has run', () {
    final at = DateTime(2026, 11, 2, 12);
    final call = CallView(update: update(CallPhase.connected), incoming: false, connectedAt: at);
    expect(callStatus(call, now: at.add(const Duration(seconds: 65))), '1:05');
  });

  test('end reasons in words', () {
    expect(endedText('Timeout'), 'No answer');
    expect(endedText('RemoteHangupAccepted'), 'Answered on another device');
    expect(endedText('ConnectionFailure'), "Couldn't connect");
    expect(endedText('LocalHangup'), 'Call ended');
    expect(endedText(null), 'Call ended');
  });

  testWidgets('an incoming call rings with Answer and Decline, then shows the call', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    expect(find.text('Alice'), findsNothing);

    calls.emit(update(CallPhase.incoming));
    calls.emit(update(CallPhase.ringing));
    await settle(tester);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Incoming Signal call'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_rounded));
    await tester.pump();
    expect(calls.log, contains('accept 7'));
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);

    calls.emit(update(CallPhase.connected));
    await settle(tester);
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    expect(calls.log, contains('muted true'));
    expect(find.text('Unmute'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(calls.log, contains('hang up'));

    calls.emit(update(CallPhase.ended, reason: 'LocalHangup'));
    await settle(tester);
    expect(find.text('Call ended'), findsOneWidget);
    await tester.pump(endedFor);
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('answering before RingRTC rings stays answered', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.incoming));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.call_rounded));
    await tester.pump();
    expect(calls.log, ['accept 7']);
    calls.emit(update(CallPhase.ringing));
    await settle(tester);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);
    calls.emit(update(CallPhase.ended, reason: 'LocalHangup'));
    await settle(tester);
    await tester.pump(endedFor);
  });

  testWidgets('a video call answered with video fills the window and can shrink', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.incoming, video: true));
    await settle(tester);
    expect(find.text('Video'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.videocam_rounded));
    await tester.pump();
    expect(calls.log, ['accept 7 video']);
    expect(find.text('Shrink'), findsOneWidget);

    calls.emit(update(CallPhase.connected, video: true, remoteVideo: true));
    await settle(tester);
    expect(find.text('Camera off'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_fullscreen_rounded));
    await tester.pump();
    expect(find.text('Shrink'), findsNothing);
    expect(find.text('Expand'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pump();
    expect(find.text('Shrink'), findsOneWidget);

    calls.emit(update(CallPhase.ended, video: true, reason: 'LocalHangup'));
    await settle(tester);
    expect(find.text('Shrink'), findsNothing);
    await tester.pump(endedFor);
  });

  testWidgets('the camera, or the contact turning theirs on, brings up the video', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.outgoing));
    calls.emit(update(CallPhase.connected));
    await settle(tester);
    expect(find.text('Shrink'), findsNothing);

    calls.emit(update(CallPhase.connected, remoteVideo: true));
    await settle(tester);
    expect(find.text('Shrink'), findsOneWidget);
    calls.emit(update(CallPhase.connected));
    await settle(tester);
    expect(find.text('Shrink'), findsNothing);

    await tester.tap(find.byIcon(Icons.videocam_off_rounded));
    await tester.pump();
    expect(calls.log, ['video true']);
    expect(find.text('Shrink'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.videocam_rounded));
    await tester.pump();
    expect(calls.log, ['video true', 'video false']);
    expect(find.text('Shrink'), findsNothing);

    calls.emit(update(CallPhase.ended, reason: 'LocalHangup'));
    await settle(tester);
    await tester.pump(endedFor);
  });

  testWidgets('placing a video call shows the preview while it rings', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.outgoing, video: true));
    await settle(tester);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.text('Camera off'), findsOneWidget);
    calls.emit(update(CallPhase.ended, video: true, reason: 'Timeout'));
    await settle(tester);
    await tester.pump(endedFor);
  });

  testWidgets('declining a ringing call hangs up', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.incoming, video: true));
    await settle(tester);
    expect(find.text('Incoming Signal video call'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(calls.log, ['hang up']);
    calls.emit(update(CallPhase.ended, reason: 'LocalHangup'));
    await settle(tester);
    await tester.pump(endedFor);
  });

  testWidgets('an outgoing call says where it is up to', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.outgoing));
    await settle(tester);
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);
    calls.emit(update(CallPhase.ringing));
    await settle(tester);
    expect(find.text('Ringing…'), findsOneWidget);
    calls.emit(update(CallPhase.ended, reason: 'Timeout'));
    await settle(tester);
    expect(find.text('No answer'), findsOneWidget);
    await tester.pump(endedFor);
    expect(find.text('No answer'), findsNothing);
  });

  testWidgets('a second call during one, or an offer too old to ring, shows nothing', (tester) async {
    final calls = FakeCalls();
    await tester.pumpWidget(app(calls));
    await settle(tester);
    calls.emit(update(CallPhase.ended, callId: '8', reason: 'ReceivedOfferExpired'));
    await settle(tester);
    expect(find.text('Alice'), findsNothing);

    calls.emit(update(CallPhase.outgoing));
    calls.emit(update(CallPhase.ended, callId: '8', reason: 'ReceivedOfferWhileActive'));
    await settle(tester);
    expect(find.text('Calling…'), findsOneWidget);
    calls.emit(update(CallPhase.ended, reason: 'LocalHangup'));
    await settle(tester);
    await tester.pump(endedFor);
  });
}
