import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/hub.dart';

/// Flags an account that needs relinking or a bridge that isn't answering;
/// tapping opens Accounts.
class HealthBanner extends ConsumerWidget {
  const HealthBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problems = accountProblems(ref.watch(bridgesProvider).value ?? const []);
    if (problems.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final more = problems.length - 1;
    return Material(
      color: scheme.errorContainer,
      child: InkWell(
        onTap: () => context.push('/accounts'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.link_off_rounded, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  more > 0 ? '${problems.first.message} and $more more' : problems.first.message,
                  style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}
