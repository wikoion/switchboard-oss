import 'package:flutter/material.dart';

/// Switchboard's look: neutral surfaces and one accent. Network colour
/// appears only in the small badge on each avatar.
const accent = Color(0xFF4F6BED);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.neutral,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: dark ? const Color(0xFF111214) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xFF0B0C0D) : const Color(0xFFFAFAFB),
    surfaceContainerLow: dark ? const Color(0xFF17181B) : const Color(0xFFF4F4F6),
    surfaceContainer: dark ? const Color(0xFF1C1D21) : const Color(0xFFEFEFF2),
    surfaceContainerHigh: dark ? const Color(0xFF232429) : const Color(0xFFE8E8EC),
    outlineVariant: dark ? const Color(0xFF2B2C31) : const Color(0xFFE3E3E8),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 0.5),
    // Menus share the sheets' rounded corners.
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      // An underline border keeps a floating label inside the filled box;
      // an outline border floats it onto the box's top edge.
      border: UnderlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

/// The star's gold, for favourites.
const favouriteColor = Color(0xFFF5B400);

/// A network ID as the badges know it. Rooms carry the bridge type, which
/// for the newer bridges ends in `go` (instagramgo, slackgo, discordgo).
String? canonicalNetwork(String? id) {
  if (id == null || !id.endsWith('go') || id.length <= 2) return id;
  final base = id.substring(0, id.length - 2);
  return networkGlyph(base) != null ? base : id;
}

/// Badge colours for networks whose bridge sends no icon, or while the
/// icon loads.
Color networkColor(String? id) => switch (canonicalNetwork(id)) {
      'whatsapp' => const Color(0xFF25D366),
      'signal' => const Color(0xFF3A76F0),
      'telegram' => const Color(0xFF2AABEE),
      'facebook' || 'messenger' => const Color(0xFF0084FF),
      'instagram' => const Color(0xFFE1306C),
      'twitter' || 'x' => const Color(0xFF111111),
      'linkedin' => const Color(0xFF0A66C2),
      'discord' => const Color(0xFF5865F2),
      'slack' => const Color(0xFF4A154B),
      'gmessages' => const Color(0xFF1A73E8),
      'imessage' => const Color(0xFF34C759),
      'googlechat' => const Color(0xFF00AC47),
      'matrix' => const Color(0xFF0DBD8B),
      _ => const Color(0xFF8A8A93),
    };

/// The bundled glyph for a bridge's protocol ID, if there is one. The
/// bridges' own icons live on maunium.net, which this server can't fetch
/// with federation off.
String? networkGlyph(String? id) {
  final file = switch (id != null && id.endsWith('go') ? canonicalNetwork(id) : id) {
    'whatsapp' => 'whatsapp',
    'signal' => 'signal',
    'telegram' => 'telegram',
    'facebook' || 'messenger' => 'messenger',
    'instagram' => 'instagram',
    'twitter' || 'x' => 'x',
    'linkedin' => 'linkedin',
    'discord' => 'discord',
    'slack' => 'slack',
    'gmessages' => 'googlemessages',
    'imessage' => 'imessage',
    'googlechat' => 'googlechat',
    'matrix' => 'matrix',
    _ => null,
  };
  return file == null ? null : 'assets/networks/$file.svg';
}
