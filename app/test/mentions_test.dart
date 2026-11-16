import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/ui/mentions.dart';

void main() {
  test('finds the mention being typed at the cursor', () {
    expect(mentionQuery('hey @Al', 7), 'Al');
    expect(mentionQuery('@', 1), '');
    expect(mentionQuery('email a@b.com', 13), isNull, reason: 'needs a space or the start before @');
    expect(mentionQuery('hey @Al there', 13), isNull);
  });

  test('inserts the chosen name in place of the query', () {
    final (text, cursor) = insertMention('hey @Al and', 7, 'Alice Smith');
    expect(text, 'hey @Alice Smith and');
    expect(cursor, 17);
    expect(insertMention('@Al', 3, 'Alice'), ('@Alice ', 7));
  });

  test('chosen mentions become pills and m.mentions', () {
    final r = applyMentions('hi @Ann Lee and @Ann', {'Ann': '@ann:x', 'Ann Lee': '@annlee:x'});
    expect(r.markdown, 'hi [Ann Lee](https://matrix.to/#/@annlee:x) and [Ann](https://matrix.to/#/@ann:x)');
    expect(r.userIds, unorderedEquals(['@ann:x', '@annlee:x']));
  });

  test('a mention deleted from the text is not sent', () {
    final r = applyMentions('never mind', {'Ann': '@ann:x'});
    expect(r.markdown, 'never mind');
    expect(r.userIds, isEmpty);
  });

  test('brackets in names are escaped', () {
    expect(applyMentions('@A [x]', {'A [x]': '@a:x'}).markdown, r'[A \[x\]](https://matrix.to/#/@a:x)');
  });
}
