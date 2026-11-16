// Linux desktop integration. Closing the window hides it to a tray icon so
// sync keeps running, the icon shows how many chats are unread, new messages
// raise desktop notifications, and the app can start at login in the tray.

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
import 'state/notify.dart';
import 'state/ringer.dart';
import 'state/rooms.dart';
import 'state/session.dart';
import 'state/views.dart';
import 'ui/router.dart';

const _appId = 'com.richarddraycott.switchboard';
const _trayIcon = 'assets/icon/tray.png';

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

/// The tray icon and menu, close-to-tray, and notifications.
class DesktopIntegration extends ConsumerStatefulWidget {
  const DesktopIntegration({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DesktopIntegration> createState() => _DesktopIntegrationState();
}

class _DesktopIntegrationState extends ConsumerState<DesktopIntegration> with TrayListener, WindowListener {
  final _notifications = LinuxFlutterLocalNotificationsPlugin();
  final _ringer = Ringer();

  /// Each chat's unread count at the last update. Null until the first
  /// list after signing in, which only sets the baseline.
  Map<String, int>? _counts;

  /// Chats with a notification showing.
  final _shown = <String>{};
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
        settings: LinuxInitializationSettings(defaultActionName: 'Open', defaultIcon: AssetsLinuxIcon(_trayIcon)),
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

  void _onRooms(List<RoomSummary>? rooms) {
    if (rooms == null) {
      _counts = null;
      return;
    }
    final before = _counts;
    _counts = {for (final r in rooms) r.id: r.unreadCount};
    if (before == null) return;
    // Read elsewhere: take its notification down.
    for (final r in rooms) {
      if (r.unreadCount == 0 && _shown.remove(r.id)) _notifications.cancel(id: notificationId(r.id));
    }
    final fresh = newlyNotifying(before, rooms, openRoomId: _openRoomId());
    if (fresh.isEmpty) return;
    // A burst, such as catching up after a reconnect, gets one summary.
    if (fresh.length > 3) {
      _notifications.show(id: 0, title: 'Switchboard', body: '${fresh.length} chats have new messages');
      return;
    }
    for (final r in fresh) {
      final text = notificationText(r);
      _shown.add(r.id);
      _notifications.show(id: notificationId(r.id), title: text.title, body: text.body, payload: r.id);
    }
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
    ref.listen(_signedInInboxProvider, (_, rooms) => _onRooms(rooms));
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
