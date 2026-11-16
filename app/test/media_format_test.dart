import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/ui/media_bubbles.dart';

void main() {
  test('file sizes', () {
    expect(fileSize(null), '');
    expect(fileSize(512), '512 B');
    expect(fileSize(1500), '1.5 KB');
    expect(fileSize(23400000), '23 MB');
  });

  test('durations', () {
    expect(clock(const Duration(seconds: 5)), '0:05');
    expect(clock(const Duration(minutes: 1, seconds: 5)), '1:05');
    expect(clock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });
}
