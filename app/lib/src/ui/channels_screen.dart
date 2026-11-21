import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import '../state/hub.dart';
import 'layout.dart';
import 'widgets/avatar.dart';

/// Which Discord and Slack channels come into Switchboard. DMs always do;
/// channels are chosen here, per linked account, at any time. The bridges
/// hold the selection, so nothing is kept on the device.
class ChannelsScreen extends ConsumerWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridges = ref.watch(bridgesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Channels')),
      body: switch (bridges) {
        // Keep showing the last answer while a refresh is in flight.
        AsyncValue(:final value?) => _accounts(context, value),
        AsyncError(:final error) => _Notice(
            icon: Icons.cloud_off_rounded,
            text: "Couldn't load accounts: $error",
            action: 'Try again',
            onAction: () => ref.invalidate(bridgesProvider),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _accounts(BuildContext context, List<Bridge> bridges) {
    final accounts = [
      for (final b in bridges)
        if (b.hasChannels)
          for (final login in b.logins) (bridge: b, login: login),
    ];
    if (accounts.isEmpty) {
      return _Notice(
        icon: Icons.forum_outlined,
        text: 'No Discord or Slack account linked.\nLink one to choose which of its channels come in.',
        action: 'Add account',
        onAction: () => openPage(context, '/accounts/add'),
      );
    }
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'Direct messages always come in. Choose the channels to bring in as well. '
            'Turning a channel off stops new messages; the chat and its history stay.',
            style: muted,
          ),
        ),
        for (final a in accounts)
          _AccountChannels(key: ValueKey('${a.bridge.id}/${a.login.id}'), bridge: a.bridge, login: a.login),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// A centred message with one thing to do about it.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.action, required this.onAction});
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

/// One linked account: its servers or workspaces and their channels.
class _AccountChannels extends ConsumerStatefulWidget {
  const _AccountChannels({super.key, required this.bridge, required this.login});
  final Bridge bridge;
  final BridgeLogin login;

  @override
  ConsumerState<_AccountChannels> createState() => _AccountChannelsState();
}

class _AccountChannelsState extends ConsumerState<_AccountChannels> {
  /// Channels with a change on its way to the bridge.
  final _saving = <String>{};

  /// What the bridge confirmed since the list was fetched, by channel.
  final _saved = <String, bool>{};

  /// Why a channel's last change didn't happen, by channel.
  final _failed = <String, String>{};

  ChannelAccount get _account => (bridge: widget.bridge.id, login: widget.login.id);

  static String _key(ChannelGroup g, BridgeChannel c) => '${g.id}/${c.id}';

  bool _selected(ChannelGroup g, BridgeChannel c) => _saved[_key(g, c)] ?? c.selected;

  Future<void> _set(ChannelGroup group, BridgeChannel channel, bool on) async {
    final key = _key(group, channel);
    if (_saving.contains(key)) return;
    setState(() {
      _saving.add(key);
      _failed.remove(key);
    });
    try {
      final saved = await ref
          .read(hubProvider)
          .setChannelBridged(widget.bridge.id, widget.login.id, group.id, channel.id, bridged: on);
      if (!mounted) return;
      // Show what the bridge saved, whatever was asked for.
      setState(() => _saved[key] = saved);
    } catch (e) {
      if (!mounted) return;
      // The switch never moved, so it still shows the saved selection.
      setState(() => _failed[key] = "Couldn't turn ${on ? 'on' : 'off'}: $e");
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text("Couldn't turn ${on ? 'on' : 'off'} ${channel.name}: $e")));
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  void _reload() {
    setState(() {
      _saved.clear();
      _failed.clear();
    });
    ref.invalidate(channelsProvider(_account));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final bridge = widget.bridge;
    final groups = ref.watch(channelsProvider(_account));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        ListTile(
          leading: NetworkBadge(
            network: Network(id: bridge.protocolId, name: bridge.network, avatarMxc: bridge.iconMxc),
            size: 28,
          ),
          title: Text(widget.login.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
            widget.login.handle == null ? bridge.network : '${bridge.network} · ${widget.login.handle}',
          ),
        ),
        switch (groups) {
          AsyncData(:final value) when value.every((g) => g.channels.isEmpty) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                bridge.protocolId.startsWith('slack')
                    ? 'No channels yet. Channels this account joins in Slack appear here.'
                    : 'No channels yet. Text channels this account can see appear here.',
                style: muted,
              ),
            ),
          AsyncData(:final value) => Column(
              children: [
                for (final g in value)
                  if (g.channels.isNotEmpty) _group(g, expanded: value.length == 1),
              ],
            ),
          AsyncError(:final error) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text(_loadError(error), style: muted.copyWith(color: scheme.error))),
                  TextButton(onPressed: _reload, child: const Text('Try again')),
                ],
              ),
            ),
          _ => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text('Loading channels…', style: muted),
                ],
              ),
            ),
        },
      ],
    );
  }

  String _loadError(Object error) {
    // A bridge without the channel endpoints answers 404 with no login
    // error: the server runs a build from before this setting.
    if (error is HubException && error.status == 404 && error.code != 'M_NOT_FOUND') {
      return "This server's ${widget.bridge.network} bridge can't choose channels yet. Update the server to use this.";
    }
    return "Couldn't load channels: $error";
  }

  Widget _group(ChannelGroup group, {required bool expanded}) {
    final on = group.channels.where((c) => _selected(group, c)).length;
    return ExpansionTile(
      key: PageStorageKey('${widget.bridge.id}/${widget.login.id}/${group.id}'),
      // A group with something already on opens, so the selection shows.
      initiallyExpanded: expanded || on > 0,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(on == 0 ? 'None of ${group.channels.length} on' : '$on of ${group.channels.length} on'),
      children: [for (final c in group.channels) _channel(group, c)],
    );
  }

  Widget _channel(ChannelGroup group, BridgeChannel channel) {
    final scheme = Theme.of(context).colorScheme;
    final key = _key(group, channel);
    final saving = _saving.contains(key);
    final failed = _failed[key];
    return SwitchListTile(
      key: ValueKey(key),
      contentPadding: const EdgeInsets.only(left: 24, right: 16),
      secondary: saving
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(channel.private ? Icons.lock_outline_rounded : Icons.tag_rounded, size: 20),
      title: Text(channel.name),
      subtitle: failed != null
          ? Text(failed, style: TextStyle(color: scheme.error))
          : channel.section == null
              ? null
              : Text(channel.section!),
      // The saved selection: it only moves once the bridge confirms.
      value: _selected(group, channel),
      onChanged: saving ? null : (on) => _set(group, channel, on),
    );
  }
}
