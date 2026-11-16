import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'src/desktop.dart';
import 'src/rust/frb_generated.dart';
import 'src/state/push.dart';
import 'src/ui/router.dart';
import 'src/ui/theme.dart';
import 'src/ui/widgets/call_panel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  MediaKit.ensureInitialized();
  if (Platform.isLinux) await initDesktopWindow();
  runApp(ProviderScope(
    overrides: [initialRouteProvider.overrideWithValue(await _devRoute())],
    child: const SwitchboardApp(),
  ));
}

class SwitchboardApp extends ConsumerStatefulWidget {
  const SwitchboardApp({super.key});

  @override
  ConsumerState<SwitchboardApp> createState() => _SwitchboardAppState();
}

class _SwitchboardAppState extends ConsumerState<SwitchboardApp> {
  @override
  void initState() {
    super.initState();
    if (!pushSupported) return;
    // A notification tapped while the app runs opens its chat.
    pushChannel.setMethodCallHandler((call) async {
      if (call.method == 'openRoom' && call.arguments is String) _openRoom(call.arguments as String);
    });
    // One tapped to launch the app is waiting on the native side.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final room = await pushChannel.invokeMethod<String>('ready');
      if (room != null) _openRoom(room);
    });
  }

  void _openRoom(String roomId) => ref.read(routerProvider).go('/room/${Uri.encodeComponent(roomId)}');

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Switchboard',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
      builder: switch (Platform.operatingSystem) {
        'linux' => (_, child) => DesktopIntegration(child: CallPanel(child: child!)),
        'ios' => (_, child) => CallPanel(child: child!),
        _ => null,
      },
    );
  }
}

/// Debug builds open at the route in `dev_route` in the app support
/// directory once, then delete it. `tool/sim-shot.sh` and
/// `tool/linux-shot.sh` write it.
Future<String> _devRoute() async {
  if (!kDebugMode) return '/';
  try {
    final file = File('${(await getApplicationSupportDirectory()).path}/dev_route');
    if (!file.existsSync()) return '/';
    final route = file.readAsStringSync().trim();
    file.deleteSync();
    return route.isEmpty ? '/' : route;
  } catch (_) {
    return '/';
  }
}
