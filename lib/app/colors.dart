import 'package:flutter/material.dart';

/// Pastel tone tokens for the app's card/badge/stat-tile design language.
enum AppTone { neutral, violet, orange, mint, sky, pink }

class AppColors {
  AppColors._();

  static const scaffoldBg = Color(0xFFF8F7FC);
  static const ink = Color(0xFF0F1115);

  static const violetBg = Color(0xFFEDE7FB);
  static const violetFg = Color(0xFF6D4FE0);

  static const orangeBg = Color(0xFFFDECD8);
  static const orangeFg = Color(0xFFC97B1F);

  static const mintBg = Color(0xFFDFF6E9);
  static const mintFg = Color(0xFF17845A);

  static const skyBg = Color(0xFFDCEEFB);
  static const skyFg = Color(0xFF2E86D8);

  static const pinkBg = Color(0xFFFBE3F0);
  static const pinkFg = Color(0xFFD6488C);

  static const neutralBg = Colors.white;
  static const neutralFg = Color(0xFF1E293B);

  static Color background(AppTone tone) => switch (tone) {
    AppTone.violet  => violetBg,
    AppTone.orange  => orangeBg,
    AppTone.mint    => mintBg,
    AppTone.sky     => skyBg,
    AppTone.pink    => pinkBg,
    AppTone.neutral => neutralBg,
  };

  static Color foreground(AppTone tone) => switch (tone) {
    AppTone.violet  => violetFg,
    AppTone.orange  => orangeFg,
    AppTone.mint    => mintFg,
    AppTone.sky     => skyFg,
    AppTone.pink    => pinkFg,
    AppTone.neutral => neutralFg,
  };
}
