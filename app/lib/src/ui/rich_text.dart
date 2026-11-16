// Message text: the safe subset of Matrix HTML that bridges produce, links
// in plain text, and mention pills.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

/// One run of text with its styling.
class Run {
  const Run(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
    this.quote = false,
    this.link,
    this.mention,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool strike;
  final bool code;
  final bool quote;
  final String? link;

  /// The user ID of a matrix.to pill.
  final String? mention;

  @override
  String toString() => [
        text,
        if (bold) 'b',
        if (italic) 'i',
        if (strike) 's',
        if (code) 'code',
        if (quote) 'quote',
        if (link != null) 'link',
        if (mention != null) '@$mention',
      ].join('|');
}

final _url = RegExp(r'''\bhttps?://[^\s<>"']+[^\s<>"'.,;:!?)\]]''', caseSensitive: false);

/// Splits plain text into runs, marking URLs as links.
List<Run> linkify(String text) {
  final out = <Run>[];
  var at = 0;
  for (final m in _url.allMatches(text)) {
    if (m.start > at) out.add(Run(text.substring(at, m.start)));
    out.add(Run(m[0]!, link: m[0]));
    at = m.end;
  }
  if (at < text.length) out.add(Run(text.substring(at)));
  return out;
}

/// The user ID a matrix.to link points at, if it is a user.
String? mentionTarget(String href) {
  const prefix = 'https://matrix.to/#/';
  if (!href.startsWith(prefix)) return null;
  // Clients may percent-encode the user ID, @ included.
  final String rest;
  try {
    rest = Uri.decodeComponent(href.substring(prefix.length));
  } on ArgumentError {
    return null;
  }
  final id = rest.split(RegExp(r'[/?]')).first;
  return id.startsWith('@') && id.contains(':') ? id : null;
}

/// Parses Matrix HTML into runs. Unknown tags keep their text; the reply
/// fallback (`mx-reply`) is dropped, as the app draws replies itself.
List<Run> parseHtml(String source) {
  final out = <Run>[];
  final root = html.parseFragment(source);

  void add(String text, _Style s) {
    if (text.isEmpty) return;
    if (s.link != null || s.code) {
      out.add(s.run(text));
    } else {
      for (final r in linkify(text)) {
        out.add(r.link != null ? s.withLink(r.link!).run(r.text) : s.run(r.text));
      }
    }
  }

  void newline() {
    if (out.isNotEmpty && !out.last.text.endsWith('\n')) out.add(const Run('\n'));
  }

  void walk(dom.Node node, _Style s) {
    if (node is dom.Text) {
      add(node.text, s);
      return;
    }
    if (node is! dom.Element) {
      for (final c in node.nodes) {
        walk(c, s);
      }
      return;
    }
    final tag = node.localName;
    switch (tag) {
      case 'mx-reply':
        return;
      case 'br':
        out.add(const Run('\n'));
        return;
      case 'li':
        newline();
        final parent = node.parent;
        final bullet = parent?.localName == 'ol' ? '${parent!.children.indexOf(node) + 1}. ' : '• ';
        add(bullet, s);
        for (final c in node.nodes) {
          walk(c, s);
        }
        newline();
        return;
    }
    final next = switch (tag) {
      'b' || 'strong' => s.copy(bold: true),
      'i' || 'em' => s.copy(italic: true),
      's' || 'del' || 'strike' => s.copy(strike: true),
      'code' || 'pre' => s.copy(code: true),
      'blockquote' => s.copy(quote: true),
      'a' => s.withLink(node.attributes['href'] ?? ''),
      _ => s,
    };
    final block = const {'p', 'div', 'blockquote', 'pre', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag);
    if (block) newline();
    for (final c in node.nodes) {
      walk(c, next);
    }
    if (block) newline();
  }

  walk(root, const _Style());
  // Trim the trailing newlines that block elements leave.
  while (out.isNotEmpty && out.last.text.trim().isEmpty && out.last.text.contains('\n')) {
    out.removeLast();
  }
  return out;
}

class _Style {
  const _Style({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
    this.quote = false,
    this.link,
  });
  final bool bold, italic, strike, code, quote;
  final String? link;

  _Style copy({bool? bold, bool? italic, bool? strike, bool? code, bool? quote}) => _Style(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        strike: strike ?? this.strike,
        code: code ?? this.code,
        quote: quote ?? this.quote,
        link: link,
      );

  _Style withLink(String href) =>
      _Style(bold: bold, italic: italic, strike: strike, code: code, quote: quote, link: href);

  Run run(String text) {
    final target = link == null ? null : mentionTarget(link!);
    return Run(
      text,
      bold: bold,
      italic: italic,
      strike: strike,
      code: code,
      quote: quote,
      link: target == null ? link : null,
      mention: target,
    );
  }
}

/// Renders a message body: formatted HTML when the event has it, otherwise
/// plain text with links found.
class MessageText extends StatefulWidget {
  const MessageText({super.key, required this.body, this.html, required this.style, required this.own});

  final String body;
  final String? html;
  final TextStyle style;
  final bool own;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final scheme = Theme.of(context).colorScheme;
    final linkColor = widget.own ? Colors.white : scheme.primary;
    final runs = widget.html == null ? linkify(widget.body) : parseHtml(widget.html!);
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final r in runs) _span(r, linkColor, scheme),
        ],
      ),
    );
  }

  InlineSpan _span(Run r, Color linkColor, ColorScheme scheme) {
    var style = TextStyle(
      fontWeight: r.bold || r.mention != null ? FontWeight.w700 : null,
      fontStyle: r.italic || r.quote ? FontStyle.italic : null,
      decoration: r.strike ? TextDecoration.lineThrough : (r.link != null ? TextDecoration.underline : null),
      decorationColor: linkColor,
      color: r.link != null || r.mention != null ? linkColor : null,
      fontFamily: r.code ? 'Menlo' : null,
      fontFamilyFallback: r.code ? const ['Courier'] : null,
      backgroundColor: r.code ? (widget.own ? Colors.white24 : scheme.surfaceContainerHigh) : null,
    );
    if (r.quote) style = style.copyWith(color: widget.own ? Colors.white70 : scheme.onSurfaceVariant);
    final link = r.link;
    if (link == null) return TextSpan(text: r.text, style: style);
    final tap = TapGestureRecognizer()..onTap = () => _open(link);
    _recognizers.add(tap);
    return TextSpan(text: r.text, style: style, recognizer: tap);
  }

  Future<void> _open(String link) async {
    final uri = Uri.tryParse(link);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme == 'mailto')) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
