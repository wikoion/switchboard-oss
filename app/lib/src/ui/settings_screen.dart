import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop.dart';
import '../state/search.dart';
import '../state/session.dart';
import 'layout.dart';
import 'media_bubbles.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _linux = defaultTargetPlatform == TargetPlatform.linux;
  late bool _atLogin = _linux && startsAtLogin();

  Future<void> _setAtLogin(bool on) async {
    try {
      await setStartAtLogin(on);
      setState(() => _atLogin = on);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't change that: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final index = ref.watch(indexStatusProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Accounts'),
            onTap: () => openPage(context, '/accounts'),
          ),
          ListTile(
            leading: const Icon(Icons.manage_search_rounded),
            title: const Text('Search'),
            subtitle: index == null ? null : Text('${periodLabel(index.periodDays)} · ${fileSize(index.bytes)} on this device'),
            onTap: () => openPage(context, '/settings/search'),
          ),
          if (_linux)
            SwitchListTile(
              secondary: const Icon(Icons.login_rounded),
              title: const Text('Start at login'),
              subtitle: const Text('Opens in the tray'),
              value: _atLogin,
              onChanged: _setAtLogin,
            ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout_rounded, color: scheme.error),
            title: Text('Sign out', style: TextStyle(color: scheme.error)),
            onTap: () => ref.read(sessionProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}
