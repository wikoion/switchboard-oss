// iOS push: registration with Synapse's pusher API, the session the
// notification extension reads, and chats opened from notifications. The
// native side lives in ios/Runner/AppDelegate.swift.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../rust/api/client.dart';
import '../rust/api/types.dart';
import 'hub.dart';
import 'rooms.dart';
import 'session.dart';
import 'views.dart';

const pushChannel = MethodChannel('switchboard/push');

/// Synapse pushes through the hub inside the Compose network; it holds
/// back the history a bridge imports and passes the rest to Sygnal.
const pushGateway = 'http://hub:8090/_matrix/push/v1/notify';

/// Development-signed builds (Xcode, `flutter run`) get pushes through APNs'
/// sandbox; TestFlight and App Store builds through production. Sygnal has
/// one app ID for each.
const _production = bool.fromEnvironment('SB_APNS_PRODUCTION');
const pushAppId = _production ? 'com.richarddraycott.switchboard' : 'com.richarddraycott.switchboard.dev';
const _otherPushAppId = _production ? 'com.richarddraycott.switchboard.dev' : 'com.richarddraycott.switchboard';

/// Push needs APNs, so it is iOS only. Desktop keeps a live sync instead.
bool get pushSupported => Platform.isIOS;

/// Hands the session to the notification extension, or clears it.
Future<void> shareSessionWithExtension(SwitchboardCore? core) async {
  if (!pushSupported) return;
  try {
    await pushChannel.invokeMethod<void>('shareSession', core?.sessionJson());
  } on PlatformException {
    // Notifications fall back to "New message".
  }
}

const _storage = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
);
const _enabledKey = 'push_enabled';
const _tokenKey = 'push_token';

/// Whether push is on for this device.
final pushProvider = AsyncNotifierProvider<PushController, bool>(PushController.new);

class PushController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    if (!pushSupported) return false;
    final enabled = await _storage.read(key: _enabledKey) == 'true';
    // APNs tokens can change, so register again on each launch.
    if (enabled) {
      try {
        await _register();
      } catch (_) {
        // Still on; the next launch tries again.
      }
    }
    return enabled;
  }

  Future<void> _register() async {
    final token = await pushChannel.invokeMethod<String>('register');
    if (token == null) throw StateError('no push token');
    final core = ref.read(coreProvider);
    final previous = await _storage.read(key: _tokenKey);
    if (previous != null && previous != token) {
      // Moving between a development build and TestFlight changes the APNs
      // environment, so the old token's pusher is under the other app ID.
      for (final appId in [pushAppId, _otherPushAppId]) {
        await core.removePusher(appId: appId, pushkey: previous).catchError((_) {});
      }
    }
    await core.setPusher(
      appId: pushAppId,
      pushkey: token,
      gatewayUrl: pushGateway,
      deviceName: 'Switchboard on iPhone',
      lang: 'en',
    );
    await _storage.write(key: _tokenKey, value: token);
  }

  /// Asks iOS for permission and registers with the server. Throws with a
  /// message for the user when that fails.
  Future<void> enable() async {
    state = const AsyncLoading<bool>();
    try {
      await _register();
      await _storage.write(key: _enabledKey, value: 'true');
      state = const AsyncData(true);
    } on PlatformException catch (e) {
      state = const AsyncData(false);
      throw StateError(e.message ?? e.code);
    }
  }

  Future<void> disable() async {
    final token = await _storage.read(key: _tokenKey);
    if (token != null) {
      await ref.read(coreProvider).removePusher(appId: pushAppId, pushkey: token).catchError((_) {});
    }
    await _storage.delete(key: _enabledKey);
    await _storage.delete(key: _tokenKey);
    state = const AsyncData(false);
  }
}

/// Keeps iOS in step with what has been read: the app icon's badge counts
/// the inbox's unread chats, and read chats' notifications leave
/// Notification Center (also when read on another device). Pushes set the
/// badge too, but only when a message arrives. Waits for sync, since the
/// cached list at launch can predate a notification that just came in.
final notificationTidyProvider = Provider<void>((ref) {
  if (!pushSupported) return;
  Timer? timer;
  ref.onDispose(() => timer?.cancel());
  void tidy() {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 800), () {
      final rooms = ref.read(roomListProvider);
      final inbox = ref.read(inboxProvider);
      if (rooms == null || inbox == null || ref.read(syncStatusProvider).value != SyncStatus.running) return;
      pushChannel.invokeMethod<void>('setBadge', inbox.where(isUnread).length).ignore();
      // With each read chat goes its newest message's time: a notification
      // for anything later arrived before sync did, so it stays.
      pushChannel.invokeMethod<void>('clearRead', {
        for (final r in rooms)
          if (!isUnread(r)) r.id: r.timestampMs ?? 0,
      }).ignore();
    });
  }

  ref.listen(roomListProvider, (_, _) => tidy());
  ref.listen(syncStatusProvider, (_, _) => tidy(), fireImmediately: true);
});

/// Marks read, once a session, the chats nobody can open or read: the
/// bridges' bot chats and account spaces, and chats with no messages. Otherwise their notifications count forever,
/// in Synapse's badge on every push and in the app's own.
final readHiddenChatsProvider = Provider<void>((ref) {
  final done = <String>{};
  void read() {
    final rooms = ref.read(roomListProvider);
    final bridges = ref.read(bridgesProvider).value;
    if (rooms == null || bridges == null || ref.read(syncStatusProvider).value != SyncStatus.running) return;
    final bots = ref.read(bridgeBotsProvider);
    final hidden = [
      for (final r in rooms)
        if (isBotChat(r, bots) && isUnread(r)) r.id,
      for (final b in bridges)
        for (final l in b.logins) ?l.spaceRoom,
    ].where(done.add).toList();
    if (hidden.isNotEmpty) ref.read(coreProvider).markRoomsRead(roomIds: hidden).ignore();
    // Chats with no messages at all, whose only notification is the
    // invite: the app shows them as read, but Synapse counts them in every
    // push's badge. No preview can also mean the latest event isn't worked
    // out yet, so the core checks the server for messages first.
    final empty = [for (final r in rooms) if (r.preview == null && !r.isInvite) r.id].where(done.add).toList();
    if (empty.isNotEmpty) ref.read(coreProvider).markReadIfNoMessages(roomIds: empty).ignore();
  }

  ref.listen(roomListProvider, (_, _) => read());
  ref.listen(bridgesProvider, (_, _) => read());
  ref.listen(syncStatusProvider, (_, _) => read(), fireImmediately: true);
});
