import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/search.dart';
import '../state/session.dart';
import 'media_bubbles.dart';

/// How far back the device's search index goes, and the space it takes.
class SearchSettingsScreen extends ConsumerStatefulWidget {
  const SearchSettingsScreen({super.key});

  @override
  ConsumerState<SearchSettingsScreen> createState() => _SearchSettingsScreenState();
}

class _SearchSettingsScreenState extends ConsumerState<SearchSettingsScreen> {
  /// The period being switched to, until the core confirms it.
  int? _choosing;

  Future<void> _choose(int days) async {
    setState(() => _choosing = days);
    try {
      await ref.read(coreProvider).setIndexPeriod(days: days);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't change that: $e")));
    } finally {
      if (mounted) setState(() => _choosing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = ref.watch(indexStatusProvider).value;
    final period = _choosing ?? status?.periodDays;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final number = NumberFormat.decimalPattern();

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Switchboard keeps an index of your messages on this device, so search is instant and works offline. '
              'Choose how far back it goes. A longer period finds older messages but takes more space.',
              style: muted,
            ),
          ),
          RadioGroup<int>(
            groupValue: period,
            onChanged: (d) {
              if (d != null && d != status?.periodDays) _choose(d);
            },
            child: Column(
              children: [
                for (final days in indexPeriods)
                  RadioListTile<int>(
                    value: days,
                    title: Text(periodLabel(days)),
                    subtitle: days == 0 ? const Text('Every message the server has') : null,
                  ),
              ],
            ),
          ),
          const Divider(),
          if (status != null) ...[
            ListTile(
              leading: const Icon(Icons.storage_rounded),
              title: Text('Uses ${fileSize(status.bytes)}'),
              subtitle: Text(
                '${number.format(status.messages)} messages from ${number.format(status.chats)} chats'
                '${status.sinceMs == null ? '' : ', since ${DateFormat('d MMMM y').format(DateTime.fromMillisecondsSinceEpoch(status.sinceMs!))}'}',
              ),
            ),
            if (status.indexing && status.chatsDone < status.chats)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: status.chats == 0 ? null : status.chatsDone / status.chats,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      status.error != null
                          ? "Waiting for the server: indexing goes on when it's back."
                          : 'Indexing: ${status.chatsDone} of ${status.chats} chats done',
                      style: muted.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              'Only text is kept: messages, captions, file names and links. Photos, videos and files stay on the '
              'server. Messages outside the period can still be found with "Search older messages on the server".',
              style: muted.copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
