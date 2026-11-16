import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/push.dart';

/// Turns push notifications on or off for this iPhone.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = ref.watch(pushProvider);
    final scheme = Theme.of(context).colorScheme;
    final enabled = push.value ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Push notifications'),
            subtitle: const Text('New messages from every network, even when Switchboard is closed'),
            value: enabled,
            onChanged: push.isLoading
                ? null
                : (on) async {
                    final controller = ref.read(pushProvider.notifier);
                    try {
                      on ? await controller.enable() : await controller.disable();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't turn on notifications: $e")));
                      }
                    }
                  },
          ),
          if (enabled) const _PreviewsTile(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Notifications show the sender and message, fetched from your server over Tailscale. '
              'Apple only carries an ID, never the text. If Tailscale is off when one arrives, it says "New message". '
              "The history a bridge imports when you link a network doesn't notify.",
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether notifications show the message: iOS's Show Previews setting for
/// Switchboard, which only iOS Settings can change. It starts as "When
/// unlocked" on Face ID iPhones: hidden on the lock screen, shown once the
/// phone recognises you.
class _PreviewsTile extends StatefulWidget {
  const _PreviewsTile();

  @override
  State<_PreviewsTile> createState() => _PreviewsTileState();
}

class _PreviewsTileState extends State<_PreviewsTile> {
  String? _value;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _read();
    // Back from iOS Settings: show what was chosen there.
    _lifecycle = AppLifecycleListener(onResume: _read);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final value = await pushChannel.invokeMethod<String>('previews').catchError((_) => null);
    if (mounted) setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) {
    final (label, detail) = switch (_value) {
      'always' => ('Always', 'Message text shows on the lock screen too'),
      'never' => ('Never', 'Notifications never show the message text'),
      'whenUnlocked' => ('When unlocked', 'Hidden on the lock screen, shown once your iPhone is unlocked'),
      _ => ('', ''),
    };
    return ListTile(
      title: const Text('Show message text'),
      subtitle: Text(detail.isEmpty ? 'Set in iOS Settings' : '$detail. Change it in iOS Settings.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
      onTap: () => pushChannel.invokeMethod<void>('openNotificationSettings'),
    );
  }
}
