// Signal calls on iOS. RingRTC runs in Swift with CallKit
// (app/ios/Runner/CallsBridge.swift); the core reads and sends the call
// events in chats. This passes events between the two over
// "switchboard/calls", in order, and turns Swift's updates into the
// CallUpdates the call screens take.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../rust/api/calls.dart';
import '../rust/api/types.dart';
import 'calls.dart';

/// What the iOS service needs from the core. Tests swap in a fake.
abstract class CallSignals {
  Stream<CallSignal> subscribe();
  Future<void> send(CallSignal signal);
  Future<CallSettings> settings();
  Future<void> setCallRoom(String? roomId);
}

class CoreCallSignals implements CallSignals {
  CoreCallSignals(this._calls);
  final SignalCalls _calls;

  @override
  Stream<CallSignal> subscribe() => _calls.subscribeSignals();
  @override
  Future<void> send(CallSignal signal) => _calls.sendSignal(signal: signal);
  @override
  Future<CallSettings> settings() => _calls.settings();
  @override
  Future<void> setCallRoom(String? roomId) => _calls.setCallRoom(roomId: roomId);
}

class IosCallService implements CallService {
  IosCallService(this._calls, {required this.room, MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('switchboard/calls') {
    _channel.setMethodCallHandler(onSwift);
    _signals = _calls.subscribe().listen((signal) {
      // One at a time: RingRTC needs them in order, and an offer waits for
      // the bridge's settings.
      _queue = _queue.then((_) => _deliver(signal));
    }, onError: (Object e) => debugPrint('call events: $e'));
  }

  final CallSignals _calls;
  final MethodChannel _channel;

  /// The chat's summary, for the contact's Signal ID and name.
  final RoomSummary? Function(String roomId) room;

  final _updates = StreamController<CallUpdate>.broadcast();
  final _remoteTexture = ValueNotifier<CallTexture?>(null);
  StreamSubscription<CallSignal>? _signals;
  Future<void> _queue = Future.value();
  String? _callRoom;

  void dispose() {
    _signals?.cancel();
    _channel.setMethodCallHandler(null);
    _updates.close();
    _remoteTexture.dispose();
  }

  @override
  Stream<CallUpdate> updates() => _updates.stream;

  @override
  Future<void> place(String roomId, {bool video = false}) async {
    final summary = room(roomId);
    final uuid = summary == null ? null : signalContactUuid(summary);
    if (summary == null || uuid == null) throw StateError('no Signal contact in this chat');
    final settings = await _calls.settings();
    await _channel.invokeMethod('place', {
      'roomId': roomId,
      'uuid': uuid,
      'name': summary.name,
      'video': video,
      'localDevice': settings.deviceId,
    });
  }

  @override
  Future<void> accept(String callId, {bool video = false}) => _channel.invokeMethod('accept', {'video': video});

  @override
  Future<void> hangUp() => _channel.invokeMethod('hangUp');

  @override
  Future<void> setMuted(bool muted) => _channel.invokeMethod('setMuted', {'muted': muted});

  @override
  Future<void> setVideo(bool enabled) => _channel.invokeMethod('setVideo', {'enabled': enabled});

  /// Video is drawn natively on iOS: the contact's from [remoteTexture], the
  /// camera's preview in a platform view.
  @override
  Future<CallFrame?> frame({required bool remote, required int maxWidth, required int maxHeight}) async => null;

  @override
  ValueListenable<CallTexture?> get remoteTexture => _remoteTexture;

  Future<void> _deliver(CallSignal signal) async {
    try {
      final summary = room(signal.roomId);
      final uuid = summary == null ? null : signalContactUuid(summary);
      if (summary == null || uuid == null) {
        debugPrint('call event in ${signal.roomId}, which has no Signal contact');
        return;
      }
      await _channel.invokeMethod('received', {
        ...signalToMap(signal),
        'uuid': uuid,
        'name': summary.name,
        if (signal.kind == CallSignalKind.offer) 'localDevice': (await _calls.settings()).deviceId,
      });
    } catch (e) {
      debugPrint('call event ${signal.kind.name}: $e');
    }
  }

  /// Swift's calls: settings and send are answered, update and remoteVideo
  /// are taken.
  @visibleForTesting
  Future<Object?> onSwift(MethodCall call) async {
    switch (call.method) {
      case 'settings':
        try {
          final settings = await _calls.settings();
          return {
            'deviceId': settings.deviceId,
            'iceServers': [
              for (final s in settings.iceServers)
                {'username': s.username, 'password': s.password, 'hostname': s.hostname, 'urls': s.urls},
            ],
          };
        } catch (e) {
          // Without TURN only a direct route can work, but it's worth a try.
          debugPrint('no TURN servers for the call: $e');
          return null;
        }
      case 'send':
        await _calls.send(signalFromMap(Map<String, Object?>.from(call.arguments as Map)));
        return null;
      case 'update':
        final update = updateFromMap(Map<String, Object?>.from(call.arguments as Map));
        _followRoom(update);
        _updates.add(update);
        return null;
      case 'remoteVideo':
        _remoteTexture.value = textureFromMap(Map<String, Object?>.from(call.arguments as Map));
        return null;
    }
    throw MissingPluginException(call.method);
  }

  /// Tells the core which chat the call is in, so every event there is read.
  void _followRoom(CallUpdate update) {
    final room = update.phase == CallPhase.ended ? null : update.roomId;
    if (room == _callRoom) return;
    _callRoom = room;
    _calls.setCallRoom(room).catchError((Object e) => debugPrint('call room: $e'));
  }
}

/// The contact's Signal ID in a bridged Signal DM: mautrix-signal's ghosts
/// are `@signal_<ACI>:server`.
String? signalContactUuid(RoomSummary room) {
  final ghost = RegExp(r'^@signal_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}):');
  for (final id in [...room.dmUserIds, ...room.heroUserIds]) {
    final match = ghost.firstMatch(id);
    if (match != null) return match.group(1)!.toLowerCase();
  }
  return null;
}

@visibleForTesting
Map<String, Object?> signalToMap(CallSignal s) => {
      'roomId': s.roomId,
      'kind': s.kind.name,
      'callId': s.callId,
      'senderDeviceId': s.senderDeviceId,
      'receiverDeviceId': s.receiverDeviceId,
      'ageSecs': s.ageSecs,
      'senderIdentityKey': s.senderIdentityKey,
      'receiverIdentityKey': s.receiverIdentityKey,
      'video': s.video,
      'hangupType': s.hangupType,
      'hangupDeviceId': s.hangupDeviceId,
      'opaque': s.opaque,
      'candidates': s.candidates,
    };

@visibleForTesting
CallSignal signalFromMap(Map<String, Object?> m) => CallSignal(
      roomId: m['roomId']! as String,
      kind: CallSignalKind.values.byName(m['kind']! as String),
      callId: m['callId']! as String,
      senderDeviceId: 0,
      receiverDeviceId: 0,
      ageSecs: 0,
      senderIdentityKey: Uint8List(0),
      receiverIdentityKey: Uint8List(0),
      destinationDeviceId: m['destinationDeviceId'] as int?,
      video: m['video'] as bool? ?? false,
      hangupType: m['hangupType'] as int? ?? 0,
      hangupDeviceId: m['hangupDeviceId'] as int?,
      opaque: m['opaque'] as Uint8List? ?? Uint8List(0),
      candidates: [for (final c in m['candidates'] as List? ?? const []) c as Uint8List],
    );

/// The contact's video texture, or null once the frames stop (zero size).
@visibleForTesting
CallTexture? textureFromMap(Map<String, Object?> m) {
  final width = m['width'] as int? ?? 0, height = m['height'] as int? ?? 0;
  if (width <= 0 || height <= 0) return null;
  return CallTexture(
    id: m['textureId']! as int,
    width: width,
    height: height,
    quarterTurns: ((m['rotation'] as int? ?? 0) ~/ 90) % 4,
  );
}

@visibleForTesting
CallUpdate updateFromMap(Map<String, Object?> m) => CallUpdate(
      roomId: m['roomId']! as String,
      callId: m['callId']! as String,
      phase: CallPhase.values.byName(m['phase']! as String),
      video: m['video'] as bool? ?? false,
      remoteVideo: m['remoteVideo'] as bool? ?? false,
      reason: m['reason'] as String?,
    );
