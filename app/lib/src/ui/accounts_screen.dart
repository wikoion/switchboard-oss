import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../rust/api/types.dart';
import '../state/hub.dart';
import 'widgets/avatar.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Refetched whenever the Hub reports a change, so cards update live.
    final bridges = ref.watch(bridgesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(bridgesProvider.future),
        child: switch (bridges) {
          // Keep showing the last answer while a refresh is in flight.
          AsyncValue(:final value?) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Grouped by network, each with its own Add another, so a
                // second WhatsApp (or any network) is one tap away.
                for (final b in value)
                  if (b.logins.isNotEmpty || (b.supportsApi && !b.reachable)) ...[
                    _NetworkHeader(bridge: b),
                    for (final login in b.logins) _LoginCard(bridge: b, login: login),
                    if (!b.reachable) _BridgeDown(bridge: b),
                  ],
                if (value.every((b) => b.logins.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No accounts linked yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => context.push('/accounts/add'),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add account'),
                ),
              ],
            ),
          AsyncError(:final error) => ListView(
              padding: const EdgeInsets.all(24),
              children: [Text("Couldn't load accounts: $error")],
            ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _NetworkHeader extends StatelessWidget {
  const _NetworkHeader({required this.bridge});
  final Bridge bridge;

  @override
  Widget build(BuildContext context) {
    final canAdd = bridge.reachable && bridge.supportsApi;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
      child: Row(
        children: [
          NetworkBadge(
            network: Network(id: bridge.protocolId, name: bridge.network, avatarMxc: bridge.iconMxc),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(bridge.network, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (canAdd)
            TextButton.icon(
              onPressed: () => context.push('/accounts/link/${bridge.id}'),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add another'),
            ),
        ],
      ),
    );
  }
}

class _BridgeDown extends StatelessWidget {
  const _BridgeDown({required this.bridge});
  final Bridge bridge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
        title: Text('${bridge.network} bridge is not responding'),
        subtitle: bridge.error == null ? null : Text(bridge.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// The colour and words for a bridge state event.
(Color, String) stateBadge(String state, ColorScheme scheme) => switch (state) {
      'CONNECTED' => (const Color(0xFF2EA043), 'Connected'),
      'CONNECTING' || 'BACKFILLING' => (const Color(0xFFD29922), state == 'BACKFILLING' ? 'Syncing' : 'Connecting'),
      'TRANSIENT_DISCONNECT' => (const Color(0xFFD29922), 'Reconnecting'),
      'BAD_CREDENTIALS' || 'LOGGED_OUT' => (scheme.error, 'Needs relink'),
      _ => (scheme.error, 'Error'),
    };

class _LoginCard extends ConsumerWidget {
  const _LoginCard({required this.bridge, required this.login});
  final Bridge bridge;
  final BridgeLogin login;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = stateBadge(login.state, scheme);
    final needsRelink = login.state == 'BAD_CREDENTIALS' || login.state == 'LOGGED_OUT';
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      MxcAvatar(name: login.name, mxc: login.avatar, size: 44),
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: NetworkBadge(
                          network: Network(id: bridge.protocolId, name: bridge.network, avatarMxc: bridge.iconMxc),
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(login.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      Text(
                        login.handle ?? bridge.network,
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
                ),
                const SizedBox(width: 8),
              ],
            ),
            if (login.message != null && login.state != 'CONNECTED')
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Text(login.message!, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (needsRelink)
                  TextButton(
                    onPressed: () => context.push(
                      '/accounts/link/${bridge.id}?login=${Uri.encodeQueryComponent(login.id)}',
                    ),
                    child: const Text('Reconnect'),
                  ),
                TextButton(
                  onPressed: () => _logout(context, ref),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('Log out'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Log out of ${bridge.network}?'),
        content: Text('${login.name} will stop syncing. You can link it again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(hubProvider).logout(bridge.id, login.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't log out: $e")));
      }
    }
    ref.invalidate(bridgesProvider);
  }
}

/// "Add account": every enabled network.
class AddAccountScreen extends ConsumerWidget {
  const AddAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridges = ref.watch(bridgesProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Add account')),
      body: switch (bridges) {
        AsyncValue(:final value?) => ListView(
            children: [
              for (final b in value)
                ListTile(
                  enabled: b.reachable && b.supportsApi,
                  leading: NetworkBadge(
                    network: Network(id: b.protocolId, name: b.network, avatarMxc: b.iconMxc),
                    size: 32,
                  ),
                  title: Text(b.network),
                  subtitle: !b.reachable
                      ? const Text('Bridge not responding')
                      : b.logins.isEmpty
                          ? null
                          : Text(
                              '${b.logins.length} linked · add another',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/accounts/link/${b.id}'),
                ),
            ],
          ),
        AsyncError(:final error) => Center(child: Text("Couldn't load networks: $error")),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
