import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'ui/plugin_search_page.dart';

class MagnetFinderApp extends StatelessWidget {
  const MagnetFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Magnet Finder',
      themeMode: ThemeMode.system,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: Platform.isAndroid
          ? const WithForegroundTask(child: PluginSearchPage())
          : const PluginSearchPage(),
    );
  }
}

ThemeData buildAppTheme(Brightness brightness, {String accentColor = 'teal'}) {
  final bool dark = brightness == Brightness.dark;
  final Color accent = appAccentColor(accentColor, brightness);
  final ColorScheme scheme = dark
      ? ColorScheme.dark(
          primary: accent,
          surface: AppColors.darkSurface,
          onSurface: AppColors.darkText1,
        )
      : ColorScheme.light(
          primary: accent,
          surface: AppColors.lightSurface,
          onSurface: AppColors.lightText1,
        );

  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
    fontFamily: 'Segoe UI',
    useMaterial3: true,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: dark ? 0.18 : 0.12),
      selectionHandleColor: accent,
    ),
    cardTheme: CardThemeData(
      color: dark ? AppColors.darkSurface : AppColors.lightSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: dark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: dark ? const Color(0xFF061210) : Colors.white,
        disabledBackgroundColor: dark
            ? AppColors.darkElevated
            : AppColors.lightElevated,
        disabledForegroundColor: dark
            ? AppColors.darkText3
            : AppColors.lightText3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? AppColors.darkInput : AppColors.lightInput,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: dark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: dark ? AppColors.darkBorder : AppColors.lightBorder,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? AppColors.darkElevated : AppColors.lightSurface,
      contentTextStyle: TextStyle(
        color: dark ? AppColors.darkText1 : AppColors.lightText1,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

abstract final class AppTheme {
  static bool isDark(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark;
  }

  static Color bg(BuildContext context) {
    return isDark(context) ? AppColors.darkBg : AppColors.lightBg;
  }

  static Color sidebar(BuildContext context) {
    return isDark(context) ? AppColors.darkSidebar : AppColors.lightSidebar;
  }

  static Color surface(BuildContext context) {
    return isDark(context) ? AppColors.darkSurface : AppColors.lightSurface;
  }

  static Color elevated(BuildContext context) {
    return isDark(context) ? AppColors.darkElevated : AppColors.lightElevated;
  }

  static Color border(BuildContext context) {
    return isDark(context) ? AppColors.darkBorder : AppColors.lightBorder;
  }

  static Color text1(BuildContext context) {
    return isDark(context) ? AppColors.darkText1 : AppColors.lightText1;
  }

  static Color text2(BuildContext context) {
    return isDark(context) ? AppColors.darkText2 : AppColors.lightText2;
  }

  static Color text3(BuildContext context) {
    return isDark(context) ? AppColors.darkText3 : AppColors.lightText3;
  }

  static Color selected(BuildContext context) {
    return accentDim(context);
  }

  static Color accent(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  static Color accentDim(BuildContext context) {
    return accent(context).withValues(alpha: isDark(context) ? 0.16 : 0.12);
  }

  static Color dock(BuildContext context) {
    return isDark(context) ? AppColors.darkDock : AppColors.lightDock;
  }
}

abstract final class AppColors {
  static const Color lightBg = Color(0xFFF4F6F8);
  static const Color lightSidebar = Color(0xFFECEFF3);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightElevated = Color(0xFFF8FAFB);
  static const Color lightInput = Color(0xFFEDF1F3);
  static const Color lightBorder = Color(0xFFDDE3E7);
  static const Color lightSelected = Color(0xFFE6F5F2);
  static const Color lightDock = Color(0xCCFFFFFF);
  static const Color lightText1 = Color(0xFF111827);
  static const Color lightText2 = Color(0xFF59636E);
  static const Color lightText3 = Color(0xFF8A95A1);
  static const Color lightAccent = Color(0xFF0F766E);
  static const Color lightAccentDim = Color(0x1F0F766E);

  static const Color darkBg = Color(0xFF0A0B0D);
  static const Color darkSidebar = Color(0xFF101215);
  static const Color darkSurface = Color(0xFF141619);
  static const Color darkElevated = Color(0xFF1D2125);
  static const Color darkInput = Color(0xFF111417);
  static const Color darkBorder = Color(0xFF282D33);
  static const Color darkSelected = Color(0xFF163D3A);
  static const Color darkDock = Color(0xBF141619);
  static const Color darkText1 = Color(0xFFF3F4F6);
  static const Color darkText2 = Color(0xFFAAB2BE);
  static const Color darkText3 = Color(0xFF6F7986);
  static const Color darkAccent = Color(0xFF2DD4BF);
  static const Color darkAccentDim = Color(0x242DD4BF);

  static const Color accent = Color(0xFF14B8A6);
  static const Color green = Color(0xFF22C55E);
  static const Color amber = Color(0xFFF59E0B);
  static const Color red = Color(0xFFF87171);

  static const Color bg0 = darkBg;
  static const Color bg1 = darkSurface;
  static const Color bg2 = darkElevated;
  static const Color bg3 = darkInput;
  static const Color border = darkBorder;
  static const Color text1 = darkText1;
  static const Color text2 = darkText2;
  static const Color text3 = darkText3;
  static const Color accentDim = darkAccentDim;
}

Color appAccentColor(String id, Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  return switch (id) {
    'blue' => dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
    'violet' => dark ? const Color(0xFFA78BFA) : const Color(0xFF7C3AED),
    'rose' => dark ? const Color(0xFFFB7185) : const Color(0xFFE11D48),
    'amber' => dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
    'green' => dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
    _ => dark ? AppColors.darkAccent : AppColors.lightAccent,
  };
}

abstract final class AppRadii {
  static const double sm = 6;
  static const double md = 10;
}

SnackBar appSnack(String message) {
  return SnackBar(
    content: Text(message),
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
  );
}
