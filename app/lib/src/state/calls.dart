// Signal calls: the call service as one call at a time, and the actions on
// it. On Linux the core runs calls; on iOS Swift does (calls_ios.dart).
// Elsewhere there is no service and no call button.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/calls.dart';
import '../rust/api/types.dart';
import 'calls_ios.dart';
import 'rooms.dart';
import 'session.dart';

/// What the call screens need from the core. Tests swap in a fake.
abstract class CallService {
  Stream<CallUpdate> updates();
  Future<void> place(String roomId, {bool video = false});
  Future<void> accept(String callId, {bool video = false});
  Future<void> hangUp();
  Future<void> setMuted(bool muted);
  Future<void> setVideo(bool enabled);

  /// The contact's or the camera's newest frame since the last ask, shrunk
  /// to fit, or null.
  Future<CallFrame?> frame({required bool remote, required int maxWidth, required int maxHeight});

  /// Where the contact's video is drawn natively instead (iOS): its
  /// texture, or null without video.
  ValueListenable<CallTexture?> get remoteTexture;
}

/// A video texture and its frames' shape. [quarterTurns] clockwise turns
/// it upright.
@immutable
class CallTexture {
  const CallTexture({required this.id, required this.width, required this.height, required this.quarterTurns});
  final int id;
  final int width;
  final int height;
  final int quarterTurns;

  @override
  bool operator ==(Object other) =>
      other is CallTexture &&
      other.id == id &&
      other.width == width &&
      other.height == height &&
      other.quarterTurns == quarterTurns;

  @override
  int get hashCode => Object.hash(id, width, height, quarterTurns);
}

/// No texture, for services that give frames instead.
final ValueListenable<CallTexture?> noCallTexture = ValueNotifier(null);

class _CoreCallService implements CallService {
  _CoreCallService(this._calls);
  final SignalCalls _calls;

  @override
  Stream<CallUpdate> updates() => _calls.subscribe();
  @override
  Future<void> place(String roomId, {bool video = false}) => _calls.placeCall(roomId: roomId, video: video);
  @override
  Future<void> accept(String callId, {bool video = false}) => _calls.accept(callId: callId, video: video);
  @override
  Future<void> hangUp() => _calls.hangUp();
  @override
  Future<void> setMuted(bool muted) => _calls.setMuted(muted: muted);
  @override
  Future<void> setVideo(bool enabled) => _calls.setVideo(enabled: enabled);
  @override
  Future<CallFrame?> frame({required bool remote, required int maxWidth, required int maxHeight}) => remote
      ? _calls.remoteFrame(maxWidth: maxWidth, maxHeight: maxHeight)
      : _calls.localFrame(maxWidth: maxWidth, maxHeight: maxHeight);
  @override
  ValueListenable<CallTexture?> get remoteTexture => noCallTexture;
}

/// The call service while signed in, or null where calls aren't supported
/// or it couldn't start.
final callServiceProvider = FutureProvider<CallService?>((ref) async {
  if (!SignalCalls.supported()) return null;
  final core = ref.watch(sessionProvider).value;
  if (core == null) return null;
  try {
    final calls = await SignalCalls.start(core: core);
    if (Platform.isIOS) {
      final service = IosCallService(CoreCallSignals(calls), room: (id) => ref.read(roomSummaryProvider(id)));
      ref.onDispose(service.dispose);
      return service;
    }
    return _CoreCallService(calls);
  } catch (e) {
    debugPrint('calls unavailable: $e');
    return null;
  }
});

/// Whether a chat can be called: Signal DMs only, so far. mautrix-signal's
/// bridge type is plain `signal`.
bool canCall(RoomSummary room) => room.isDm && room.network?.id == 'signal';

/// The call on screen.
@immutable
class CallView {
  const CallView({
    required this.update,
    required this.incoming,
    this.connectedAt,
    this.muted = false,
    this.answered = false,
    this.video = false,
  });

  final CallUpdate update;
  final bool incoming;

  /// When it connected, for its duration.
  final DateTime? connectedAt;
  final bool muted;

  /// Answer was pressed. The core may hold the answer until RingRTC can take
  /// it, so the phase can still be incoming or ringing.
  final bool answered;

  /// Our camera is on.
  final bool video;

  String get roomId => update.roomId;
  CallPhase get phase => update.phase;

  /// Incoming and not answered yet.
  bool get ringing => incoming && !answered && (phase == CallPhase.incoming || phase == CallPhase.ringing);

  /// Either camera is on, so there's video to show.
  bool get hasVideo => phase != CallPhase.ended && !ringing && (video || update.remoteVideo);

  CallView copyWith({bool? muted, bool? answered, bool? video}) => CallView(
        update: update,
        incoming: incoming,
        connectedAt: connectedAt,
        muted: muted ?? this.muted,
        answered: answered ?? this.answered,
        video: video ?? this.video,
      );
}

/// The call, or null. An ended call stays for [endedFor] so its screen can
/// say why.
final callProvider = NotifierProvider<CallController, CallView?>(CallController.new);

const endedFor = Duration(seconds: 2);

class CallController extends Notifier<CallView?> {
  CallService? _service;
  Timer? _clear;

  @override
  CallView? build() {
    final service = _service = ref.watch(callServiceProvider).value;
    if (service == null) return null;
    final sub = service.updates().listen(onUpdate);
    ref.onDispose(() {
      sub.cancel();
      _clear?.cancel();
    });
    return null;
  }

  @visibleForTesting
  void onUpdate(CallUpdate update) {
    final current = state;
    final live = current != null && current.phase != CallPhase.ended;
    // A second call while one is on: RingRTC turns it away as busy, and
    // only its end comes through.
    if (live && current.update.callId != update.callId) return;
    // The end of a call never shown, such as an offer too old to ring.
    if (!live && update.phase == CallPhase.ended) return;
    final same = live ? current : null;
    _clear?.cancel();
    state = CallView(
      update: update,
      incoming: same?.incoming ?? update.phase == CallPhase.incoming,
      connectedAt: same?.connectedAt ?? (update.phase == CallPhase.connected ? DateTime.now() : null),
      muted: same?.muted ?? false,
      answered: same?.answered ?? false,
      // Placing a video call starts the camera.
      video: same?.video ?? (update.phase == CallPhase.outgoing && update.video),
    );
    if (update.phase == CallPhase.ended) {
      _clear = Timer(endedFor, () => state = null);
    }
  }

  Future<void> place(String roomId, {bool video = false}) async {
    final service = _service;
    if (service == null) throw StateError("calls aren't available");
    await service.place(roomId, video: video);
  }

  Future<void> accept({bool video = false}) async {
    final call = state;
    if (call == null || !call.ringing) return;
    // Straight away, so the ring stops and Answer can't be pressed twice.
    state = call.copyWith(answered: true, video: video);
    try {
      await _service?.accept(call.update.callId, video: video);
    } catch (_) {
      if (state?.update.callId == call.update.callId) state = state!.copyWith(answered: false, video: false);
      rethrow;
    }
  }

  /// Hangs up, or declines while it rings.
  Future<void> hangUp() async {
    if (state == null || state!.phase == CallPhase.ended) return;
    await _service?.hangUp();
  }

  Future<void> toggleMute() async {
    final call = state;
    if (call == null || call.phase == CallPhase.ended) return;
    await _service?.setMuted(!call.muted);
    if (state?.update.callId == call.update.callId) state = state!.copyWith(muted: !call.muted);
  }

  /// Turns the camera on or off. Fails if the camera can't be opened.
  Future<void> toggleVideo() async {
    final call = state;
    if (call == null || call.phase == CallPhase.ended) return;
    await _service?.setVideo(!call.video);
    if (state?.update.callId == call.update.callId) state = state!.copyWith(video: !call.video);
  }

  Future<CallFrame?> frame({required bool remote, required int maxWidth, required int maxHeight}) async =>
      _service?.frame(remote: remote, maxWidth: maxWidth, maxHeight: maxHeight);

  ValueListenable<CallTexture?> get remoteTexture => _service?.remoteTexture ?? noCallTexture;
}

/// What the call screen says under the name.
String callStatus(CallView call, {DateTime? now}) {
  if (call.ringing) return call.update.video ? 'Incoming Signal video call' : 'Incoming Signal call';
  return switch (call.phase) {
    CallPhase.incoming || CallPhase.ringing when call.answered => 'Connecting…',
    CallPhase.incoming || CallPhase.outgoing => 'Calling…',
    CallPhase.ringing => 'Ringing…',
    CallPhase.connecting => 'Connecting…',
    CallPhase.connected => callDuration((now ?? DateTime.now()).difference(call.connectedAt ?? now ?? DateTime.now())),
    CallPhase.ended => endedText(call.update.reason),
  };
}

/// RingRTC's end reasons, in words.
String endedText(String? reason) => switch (reason) {
      'Timeout' => 'No answer',
      'RemoteBusy' => 'Busy',
      'RemoteHangupAccepted' => 'Answered on another device',
      'RemoteHangupDeclined' => 'Declined on another device',
      'RemoteHangupBusy' => 'Busy on another device',
      'ConnectionFailure' || 'SignalingFailure' || 'InternalFailure' => "Couldn't connect",
      _ => 'Call ended',
    };

/// 0:42, or 1:02:03 past an hour.
String callDuration(Duration d) {
  final s = d.inSeconds % 60, m = d.inMinutes % 60, h = d.inHours;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}
