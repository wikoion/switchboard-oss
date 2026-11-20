// Linux desktop integration. Closing the window hides it to a tray icon so
// sync keeps running, the icon shows how many chats are unread, new messages
// raise desktop notifications, and the app can start at login in the tray.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
// The Linux implementation only: the full plugin's iOS code doesn't build
// with Xcode 16, and iOS uses push instead.
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'rust/api/types.dart';
import 'state/calls.dart';
import 'state/media.dart';
import 'state/notification_privacy.dart';
import 'state/notify.dart';
import 'state/ringer.dart';
import 'state/rooms.dart';
import 'state/session.dart';
import 'state/views.dart';
import 'ui/router.dart';

const _appId = 'com.richarddraycott.switchboard';
const _trayIcon = 'assets/icon/tray.png';

/// The app's own icon, as notifications show it: the picture of every
/// notification that has no sender's picture to show. It ships in the
/// bundle, so it doesn't depend on an installed icon theme.
const notificationIcon = 'assets/icon/switchboard-256.png';

/// The size senders' pictures are fetched at, in pixels.
const _pictureSize = 96;

/// The ringing call's notification. Chats' IDs come from room ID hashes.
const _callNotificationId = 0x7ffffffe;

/// Before the app starts: the close button hides rather than quits.
Future<void> initDesktopWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setMinimumSize(const Size(420, 480));
}

Future<void> showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

/// The inbox while signed in, or null.
final _signedInInboxProvider = Provider<List<RoomSummary>?>(
  (ref) => ref.watch(sessionProvider).value == null ? null : ref.watch(inboxProvider),
);

/// How many chats in the inbox are unread, for the tray icon. Counts the
/// same as the iOS badge.
final unreadCountProvider = Provider<int>(
  (ref) => (ref.watch(_signedInInboxProvider) ?? const []).where(isUnread).length,
);

/// The tray icon for [count] unread chats. Waybar ignores tray labels, so
/// the count is drawn into a copy of the icon in the runtime dir.
Future<String> _trayIconFor(int count) async {
  if (count == 0) return _trayIcon;
  final label = count > 9 ? '9+' : '$count';
  final dir = Directory('${Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path}/switchboard');
  await dir.create(recursive: true);
  final file = File('${dir.path}/tray-$label.png');
  await file.writeAsBytes(await _drawTrayBadge(label));
  return file.path;
}

/// The tray icon with [label] in a red badge, big enough to read at
/// waybar's 21 px.
Future<Uint8List> _drawTrayBadge(String label) async {
  final data = await rootBundle.load(_trayIcon);
  final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
  final icon = (await codec.getNextFrame()).image;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(icon, Offset.zero, Paint());
  const centre = Offset(45, 19);
  canvas.drawCircle(centre, 19, Paint()..color = const Color(0xFFFFFFFF));
  canvas.drawCircle(centre, 16, Paint()..color = const Color(0xFFFF3B30));
  final text = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(color: const Color(0xFFFFFFFF), fontSize: label.length > 1 ? 18 : 24, fontWeight: FontWeight.w800),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  text.paint(canvas, centre - Offset(text.width / 2, text.height / 2));
  final image = await recorder.endRecording().toImage(icon.width, icon.height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

/// Chats' notifications: raised as unread counts rise and taken down as
/// chats are read. Each shows its sender's picture, or the app's icon when
/// they have none, it can't be fetched, or senders are hidden.
class ChatNotifications {
  ChatNotifications(this._plugin, {required this.hideSender, required this.picture});

  final LinuxFlutterLocalNotificationsPlugin _plugin;

  /// The setting, asked for each notification, so changing it applies to
  /// the next one.
  final Future<bool> Function() hideSender;

  /// A picture's PNG bytes, from its mxc:// URI.
  final Future<Uint8List> Function(String mxc) picture;

  /// Each chat's unread count at the last update. Null until the first
  /// list after signing in, which only sets the baseline.
  Map<String, int>? _counts;

  /// Chats with a notification showing or on its way, each with a number
  /// that rises with every message, so that a notification held up by its
  /// picture never replaces a newer one or returns after the chat is read.
  final _shown = <String, int>{};
  var _raised = 0;

  /// The inbox changed. [openRoomId] is the chat on screen, which doesn't
  /// notify. Null [rooms] means signed out.
  void update(List<RoomSummary>? rooms, {String? openRoomId}) {
    if (rooms == null) {
      _counts = null;
      return;
    }
    final before = _counts;
    _counts = {for (final r in rooms) r.id: r.unreadCount};
    if (before == null) return;
    // Read elsewhere: take its notification down.
    for (final r in rooms) {
      if (r.unreadCount == 0 && _shown.remove(r.id) != null) _plugin.cancel(id: notificationId(r.id)).ignore();
    }
    final fresh = newlyNotifying(before, rooms, openRoomId: openRoomId);
    if (fresh.isEmpty) return;
    // A burst, such as catching up after a reconnect, gets one summary.
    if (fresh.length > 3) {
      _plugin
          .show(
            id: 0,
            title: 'Switchboard',
            body: '${fresh.length} chats have new messages',
            notificationDetails: LinuxNotificationDetails(icon: AssetsLinuxIcon(notificationIcon)),
          )
          .ignore();
      return;
    }
    for (final r in fresh) {
      _show(r).ignore();
    }
  }

  Future<void> _show(RoomSummary r) async {
    final raised = _shown[r.id] = ++_raised;
    // Without the setting, assume the careful answer.
    final hide = await hideSender().catchError((_) => true);
    final text = notificationText(r, hideSender: hide);
    final icon = await _picture(hide ? null : senderPicture(r));
    if (_shown[r.id] != raised) return;
    await _plugin.show(
      id: notificationId(r.id),
      title: text.title,
      body: text.body,
      payload: r.id,
      notificationDetails: LinuxNotificationDetails(icon: icon),
    );
  }

  /// The picture at [mxc] for the notification server, which takes raw
  /// pixels, or the app's icon.
  Future<LinuxNotificationIcon> _picture(String? mxc) async {
    if (mxc != null) {
      try {
        final png = await picture(mxc).timeout(const Duration(seconds: 4));
        final codec = await ui.instantiateImageCodec(png);
        final image = (await codec.getNextFrame()).image;
        final pixels = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        if (pixels != null) {
          return ByteDataLinuxIcon(LinuxRawIconData(
            data: pixels.buffer.asUint8List(),
            width: image.width,
            height: image.height,
            channels: 4,
            hasAlpha: true,
          ));
        }
      } catch (_) {
        // No picture: the app's icon.
      }
    }
    return AssetsLinuxIcon(notificationIcon);
  }
}

/// The tray icon and menu, close-to-tray, and notifications.
class DesktopIntegration extends ConsumerStatefulWidget {
  const DesktopIntegration({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DesktopIntegration> createState() => _DesktopIntegrationState();
}

class _DesktopIntegrationState extends ConsumerState<DesktopIntegration> with TrayListener, WindowListener {
  final _notifications = LinuxFlutterLocalNotificationsPlugin();
  late final _chats = ChatNotifications(
    _notifications,
    hideSender: () => ref.read(hideNotificationSenderProvider.future),
    picture: (mxc) => ref.read(avatarProvider((mxc: mxc, size: _pictureSize)).future),
  );
  final _ringer = Ringer();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    windowManager.isFocused().then((f) => _focused = f);
    _setUpTray();
    _setUpNotifications();
  }

  /// The count the tray icon was last asked to show.
  int? _trayCount;

  Future<void> _setTrayIcon(int count) async {
    _trayCount = count;
    final icon = await _trayIconFor(count);
    // A newer count may have come in while this one was drawn.
    if (count == _trayCount) await trayManager.setIcon(icon);
  }

  Future<void> _setUpTray() async {
    // The menu needs the icon set first.
    await trayManager.setIcon(_trayIcon);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Show Switchboard'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
    await _setTrayIcon(ref.read(unreadCountProvider));
  }

  Future<void> _setUpNotifications() async {
    try {
      await _notifications.initialize(
        settings: LinuxInitializationSettings(defaultActionName: 'Open', defaultIcon: AssetsLinuxIcon(notificationIcon)),
        onDidReceiveNotificationResponse: (response) {
          switch (response.actionId) {
            case 'answer':
              showWindow();
              ref.read(callProvider.notifier).accept();
              return;
            case 'decline':
              ref.read(callProvider.notifier).hangUp();
              return;
          }
          showWindow();
          final roomId = response.payload;
          if (roomId != null && roomId.isNotEmpty) {
            ref.read(routerProvider).go('/room/${Uri.encodeComponent(roomId)}');
          }
        },
      );
    } catch (e) {
      // No notification server: the app works without notifications.
      debugPrint('notifications unavailable: $e');
    }
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _ringer.stop();
    super.dispose();
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onWindowFocus() => _focused = true;

  @override
  void onWindowBlur() => _focused = false;

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showWindow();
      case 'quit':
        _quit();
    }
  }

  Future<void> _quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  /// The chat on screen, if the window has focus.
  String? _openRoomId() {
    if (!_focused) return null;
    final s = ref.read(routerProvider).routerDelegate.currentConfiguration.uri.pathSegments;
    return s.length >= 2 && s[0] == 'room' ? s[1] : null;
  }

  /// Rings while a call rings, with a notification to answer it from when
  /// the window isn't in front. The call panel covers the window itself.
  void _onCall(CallView? before, CallView? call) {
    final ringing = call?.ringing ?? false;
    if (ringing == (before?.ringing ?? false)) return;
    if (!ringing) {
      _ringer.stop();
      _notifications.cancel(id: _callNotificationId);
      return;
    }
    _ringer.start();
    if (_focused) return;
    final room = ref.read(roomSummaryProvider(call!.roomId));
    _notifications.show(
      id: _callNotificationId,
      title: room?.name ?? 'Signal call',
      body: callStatus(call),
      payload: call.roomId,
      notificationDetails: const LinuxNotificationDetails(
        category: LinuxNotificationCategory.imReceived,
        urgency: LinuxNotificationUrgency.critical,
        timeout: LinuxNotificationTimeout.expiresNever(),
        actions: [
          LinuxNotificationAction(key: 'decline', label: 'Decline'),
          LinuxNotificationAction(key: 'answer', label: 'Answer'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(unreadCountProvider, (_, count) => _setTrayIcon(count));
    ref.listen(_signedInInboxProvider, (_, rooms) => _chats.update(rooms, openRoomId: _openRoomId()));
    ref.listen<CallView?>(callProvider, _onCall);
    return widget.child;
  }
}

/// The XDG autostart entry that starts the app hidden in the tray.
File _autostartEntry() {
  final config = Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME']}/.config';
  return File('$config/autostart/$_appId.desktop');
}

bool startsAtLogin() => _autostartEntry().existsSync();

Future<void> setStartAtLogin(bool on) async {
  final entry = _autostartEntry();
  if (!on) {
    if (await entry.exists()) await entry.delete();
    return;
  }
  // An AppImage runs from a temporary mount; start the AppImage itself.
  final exe = Platform.environment['APPIMAGE'] ?? Platform.resolvedExecutable;
  await entry.parent.create(recursive: true);
  await entry.writeAsString('''
[Desktop Entry]
Type=Application
Name=Switchboard
Comment=Start Switchboard in the tray
Exec="$exe" --minimized
Icon=$_appId
Terminal=false
X-GNOME-Autostart-enabled=true
''');
}
