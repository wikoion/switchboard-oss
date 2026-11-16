import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/types.dart';
import '../../state/session.dart';

/// Shown while the server can't be reached. Cached chats stay usable and
/// messages wait in the send queue.
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider).value;
    final show = status == SyncStatus.offline || status == SyncStatus.error;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: show
          ? Container(
              width: double.infinity,
              color: scheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Can't reach Switchboard — messages will send when connected",
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}
