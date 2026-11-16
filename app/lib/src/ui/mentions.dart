// @-mentions in the composer. The field shows "@Name"; on send each chosen
// mention that is still in the text becomes a matrix.to pill in Markdown,
// and its user ID goes in m.mentions.

/// The partial name after an "@" that ends at [cursor], or null when the
/// cursor isn't in a mention.
String? mentionQuery(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  final m = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(text.substring(0, cursor));
  return m?[1];
}

/// Replaces the "@query" before [cursor] with "@name ". Returns the new text
/// and cursor.
(String, int) insertMention(String text, int cursor, String name) {
  final at = text.substring(0, cursor).lastIndexOf('@');
  final rest = text.substring(cursor);
  // One space after the name, reusing one that's already there.
  final inserted = rest.startsWith(' ') ? '@$name' : '@$name ';
  return (text.substring(0, at) + inserted + rest, at + '@$name '.length);
}

/// Turns each chosen "@Name" still in [body] into a Markdown matrix.to link.
/// [chosen] maps the display name to the user ID.
({String markdown, List<String> userIds}) applyMentions(String body, Map<String, String> chosen) {
  var out = body;
  final ids = <String>[];
  // Longest names first, so "@Ann Lee" isn't taken as "@Ann".
  final names = chosen.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final name in names) {
    final token = '@$name';
    if (!out.contains(token)) continue;
    final id = chosen[name]!;
    final label = name.replaceAllMapped(RegExp(r'[\[\]\\]'), (m) => '\\${m[0]}');
    out = out.replaceAll(token, '[$label](https://matrix.to/#/$id)');
    ids.add(id);
  }
  return (markdown: out, userIds: ids);
}
