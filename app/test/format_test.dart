import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/ui/format.dart';

void main() {
  final now = DateTime(2026, 10, 30, 17, 40);
  int at(DateTime t) => t.millisecondsSinceEpoch;

  test('list times', () {
    expect(listTime(null, now: now), '');
    expect(listTime(at(DateTime(2026, 10, 30, 9, 5)), now: now), '09:05');
    expect(listTime(at(DateTime(2026, 10, 29, 23, 0)), now: now), 'Yesterday');
    expect(listTime(at(DateTime(2026, 10, 26, 12, 0)), now: now), 'Monday');
    expect(listTime(at(DateTime(2026, 9, 1, 12, 0)), now: now), '1 Sep');
    expect(listTime(at(DateTime(2025, 12, 25, 12, 0)), now: now), '25 Dec 2025');
  });

  test('day separators', () {
    expect(dayLabel(at(DateTime(2026, 10, 30, 1)), now: now), 'Today');
    expect(dayLabel(at(DateTime(2026, 10, 29, 1)), now: now), 'Yesterday');
    expect(dayLabel(at(DateTime(2026, 8, 3, 1)), now: now), 'Monday 3 August');
  });
}
