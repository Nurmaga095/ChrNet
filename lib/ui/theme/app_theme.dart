import 'package:flutter/material.dart';

// ─── ThemeExtension с цветами приложения ─────────────────────────────────────

class AppColors extends ThemeExtension<AppColors> {
  // Цвета, меняющиеся в зависимости от темы
  final Color background;
  final Color cardBackground;
  final Color surfaceColor;
  final Color borderColor;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color buttonIdle;

  const AppColors({
    required this.background,
    required this.cardBackground,
    required this.surfaceColor,
    required this.borderColor,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.buttonIdle,
  });

  // ─── Статические константы (одинаковы в обеих темах) ─────────────────────
  static const Color accent        = Color(0xFF2979FF);
  static const Color accentDim     = Color(0xFF1565C0);
  static const Color accentGlow    = Color(0xFF82B1FF);
  static const Color connected     = Color(0xFF00C853);
  static const Color connectedGlow = Color(0xFF69F0AE);
  static const Color error         = Color(0xFFEF5350);
  static const Color warning       = Color(0xFFFFB300);
  static const Color uploadCard    = Color(0xFF2979FF);
  static const Color downloadCard  = Color(0xFF00C853);

  // ─── Светлая тема ─────────────────────────────────────────────────────────
  static const AppColors light = AppColors(
    background:     Color(0xFFECEEFF),
    cardBackground: Color(0xFFF5F6FF),
    surfaceColor:   Color(0xFFEEF2FF),
    borderColor:    Color(0xFFDDE0F5),
    textPrimary:    Color(0xFF111827),
    textSecondary:  Color(0xFF6B7280),
    textDisabled:   Color(0xFFB0B7C3),
    buttonIdle:     Color(0xFFE8EEFF),
  );

  // ─── Тёмная тема ──────────────────────────────────────────────────────────
  static const AppColors dark = AppColors(
    background:     Color(0xFF08091A),
    cardBackground: Color(0xFF141628),
    surfaceColor:   Color(0xFF1A2040),
    borderColor:    Color(0xFF2A2D3E),
    textPrimary:    Color(0xFFF0F2F5),
    textSecondary:  Color(0xFF8B929E),
    textDisabled:   Color(0xFF4A5160),
    buttonIdle:     Color(0xFF1A2040),
  );

  // ─── Получение из контекста ───────────────────────────────────────────────
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({
    Color? background,
    Color? cardBackground,
    Color? surfaceColor,
    Color? borderColor,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? buttonIdle,
  }) =>
      AppColors(
        background:     background     ?? this.background,
        cardBackground: cardBackground ?? this.cardBackground,
        surfaceColor:   surfaceColor   ?? this.surfaceColor,
        borderColor:    borderColor    ?? this.borderColor,
        textPrimary:    textPrimary    ?? this.textPrimary,
        textSecondary:  textSecondary  ?? this.textSecondary,
        textDisabled:   textDisabled   ?? this.textDisabled,
        buttonIdle:     buttonIdle     ?? this.buttonIdle,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      background:     Color.lerp(background,     other.background,     t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      surfaceColor:   Color.lerp(surfaceColor,   other.surfaceColor,   t)!,
      borderColor:    Color.lerp(borderColor,    other.borderColor,    t)!,
      textPrimary:    Color.lerp(textPrimary,    other.textPrimary,    t)!,
      textSecondary:  Color.lerp(textSecondary,  other.textSecondary,  t)!,
      textDisabled:   Color.lerp(textDisabled,   other.textDisabled,   t)!,
      buttonIdle:     Color.lerp(buttonIdle,     other.buttonIdle,     t)!,
    );
  }
}

// ─── ThemeData ────────────────────────────────────────────────────────────────

class AppTheme {
  static ThemeData get light => _build(AppColors.light, Brightness.light);
  static ThemeData get dark  => _build(AppColors.dark,  Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      extensions: [c],
      scaffoldBackgroundColor: Colors.transparent,
      primaryColor: AppColors.accent,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: AppColors.accent,
        onPrimary: Colors.white,
        secondary: AppColors.accentDim,
        onSecondary: Colors.white,
        error: AppColors.error,
        onError: Colors.white,
        surface: c.cardBackground,
        onSurface: c.textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: c.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        iconTheme: IconThemeData(color: c.textPrimary),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: c.cardBackground,
        selectedItemColor: AppColors.accent,
        unselectedItemColor: c.textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        selectedLabelStyle:
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
      ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: c.textPrimary, fontSize: 14),
        bodyLarge:  TextStyle(color: c.textPrimary, fontSize: 16),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.cardBackground,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        hintStyle: TextStyle(color: c.textDisabled),
      ),
      dividerTheme: DividerThemeData(
        color: c.borderColor, thickness: 1, space: 0,
      ),
      iconTheme: IconThemeData(color: c.textSecondary),
      cardTheme: CardThemeData(
        color: c.cardBackground,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.cardBackground,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((_) => Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.accent
              : c.borderColor,
        ),
      ),
      fontFamily: 'Roboto',
    );
  }
}
