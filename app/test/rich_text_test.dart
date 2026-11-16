import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/ui/rich_text.dart';

List<String> runs(List<Run> rs) => [for (final r in rs) r.toString()];

void main() {
  test('plain text finds links but not trailing punctuation', () {
    expect(runs(linkify('See https://example.com/a?b=1. Thanks')), [
      'See ',
      'https://example.com/a?b=1|link',
      '. Thanks',
    ]);
    expect(runs(linkify('no links here')), ['no links here']);
  });

  test('bridge formatting becomes styled runs', () {
    // What mautrix-whatsapp sends for "*bold* _italic_ ~strike~ ```mono```".
    expect(runs(parseHtml('<strong>bold</strong> <em>italic</em> <del>strike</del> <code>mono</code>')), [
      'bold|b',
      ' ',
      'italic|i',
      ' ',
      'strike|s',
      ' ',
      'mono|code',
    ]);
  });

  test('nested styles combine', () {
    expect(runs(parseHtml('<b>a <i>b</i></b>')), ['a |b', 'b|b|i']);
  });

  test('the reply fallback is dropped', () {
    expect(
      runs(parseHtml('<mx-reply><blockquote>In reply to <a href="https://matrix.to/#/@a:x">@a:x</a></blockquote></mx-reply>Sure')),
      ['Sure'],
    );
  });

  test('matrix.to user links become mentions; other links stay links', () {
    expect(runs(parseHtml('Hi <a href="https://matrix.to/#/%40alice%3Aswitchboard.internal">Alice</a>, see <a href="https://example.com">this</a>')), [
      'Hi ',
      'Alice|@@alice:switchboard.internal',
      ', see ',
      'this|link',
    ]);
  });

  test('line breaks, paragraphs and lists', () {
    expect(parseHtml('one<br>two').map((r) => r.text).join(), 'one\ntwo');
    expect(parseHtml('<p>first</p><p>second</p>').map((r) => r.text).join(), 'first\nsecond');
    expect(parseHtml('<ul><li>a</li><li>b</li></ul>').map((r) => r.text).join(), '• a\n• b');
    expect(parseHtml('<ol><li>a</li><li>b</li></ol>').map((r) => r.text).join(), '1. a\n2. b');
  });

  test('links inside formatted text are found too', () {
    expect(runs(parseHtml('<em>read https://example.com now</em>')), [
      'read |i',
      'https://example.com|i|link',
      ' now|i',
    ]);
  });
}
