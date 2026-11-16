import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/types.dart';
import 'session.dart';

/// How the search index stands, as the core reports it.
final indexStatusProvider = StreamProvider<IndexStatus>((ref) {
  return ref.watch(coreProvider).subscribeIndexStatus();
});

/// The periods offered for the index, in days (0 is everything).
const indexPeriods = [30, 90, 182, 365, 0];

String periodLabel(int days) => switch (days) {
      0 => 'Everything',
      30 => '1 month',
      90 => '3 months',
      182 => '6 months',
      365 => '1 year',
      _ => '$days days',
    };

/// "the last year", for sentences.
String periodPhrase(int days) => switch (days) {
      0 => 'all your messages',
      30 => 'the last month',
      90 => 'the last 3 months',
      182 => 'the last 6 months',
      365 => 'the last year',
      _ => 'the last $days days',
    };
