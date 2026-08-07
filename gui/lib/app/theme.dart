import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: const Color(0xCC1E1E22),
      colorScheme: const ColorScheme.dark(
        surface: Color(0xCC25252A),
        primary: Color(0xFF10B981),
        secondary: Color(0xFF0284C7),
        outline: Color(0xFF323238),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF323238),
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0xCC141416),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF323238)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF323238)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xFF10B981)),
        ),
      ),
    );
  }

  static ThemeData get studioDarkTheme {
    return darkTheme.copyWith(
      scaffoldBackgroundColor: const Color(0xCC0F1115),
      colorScheme: darkTheme.colorScheme.copyWith(
        surface: const Color(0xCC16181D),
      ),
    );
  }
}
