import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// How many panes fit: sidebar, chat list and conversation from 900 px,
/// list and conversation from 600 px, one at a time below that.
enum Panes { one, two, three }

Panes panesFor(double width) => width >= 900
    ? Panes.three
    : width >= 600
        ? Panes.two
        : Panes.one;

Panes panesOf(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  // A phone turned sideways stays one pane.
  if (!isDesktop && size.shortestSide < 600) return Panes.one;
  return panesFor(size.width);
}

/// Desktop behaviour: Enter sends, hover actions, keyboard shortcuts.
/// Widget tests run as Android unless they override the platform.
bool get isDesktop => switch (defaultTargetPlatform) {
      TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
      _ => false,
    };

/// Opens a page under the inbox: over the list on a phone, so Back returns
/// to it, or in place of whatever is open beside the list.
void openPage(BuildContext context, String path) {
  if (panesOf(context) == Panes.one) {
    context.push(path);
  } else {
    context.go(path);
  }
}

void openRoom(BuildContext context, String roomId) => openPage(context, '/room/${Uri.encodeComponent(roomId)}');

bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

/// Ctrl on Linux, ⌘ on macOS.
SingleActivator primaryKey(LogicalKeyboardKey key, {bool shift = false}) =>
    SingleActivator(key, control: !_mac, meta: _mac, shift: shift);

/// How [primaryKey] reads in hints: "Ctrl+K" or "⌘K".
String primaryLabel(String key, {bool shift = false}) =>
    _mac ? '⌘${shift ? '⇧' : ''}$key' : 'Ctrl+${shift ? 'Shift+' : ''}$key';
