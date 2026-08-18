import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─── Design tokens ───────────────────────────────────────────────────────────

/// Corner radii. One scale, four steps — anything outside it is a mistake.
abstract final class AppRadius {
  /// Chips, badges, small controls.
  static const double sm = 10;

  /// Rows, inputs, buttons.
  static const double md = 14;

  /// Cards and sheets.
  static const double lg = 20;

  /// Hero surfaces and modal sheets.
  static const double xl = 28;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
}

/// The 4pt spacing scale the whole app lays out on.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  /// Horizontal page padding on phones.
  static const double page = 16;

  /// Space reserved at the bottom of scrollables for the floating nav bar.
  static const double navBarInset = 96;
}

/// Motion durations. Short and consistent — the UI should feel instant.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
}

// ─── Colour scheme ───────────────────────────────────────────────────────────

/// Every colour the app draws with, resolved for the active brightness.
///
/// Both palettes are defined here side by side so a token can never exist in
/// one theme and be missing in the other. Widgets read `AppColors.of(context)`
/// and must not branch on `Theme.of(context).brightness` themselves — if a
/// value differs between themes it belongs in this class.
class AppColors extends ThemeExtension<AppColors> {
  /// Page background.
  final Color background;

  /// Default card / sheet surface sitting on [background].
  final Color surface;

  /// A slightly recessed surface for rows and fills inside a card.
  final Color surfaceMuted;

  /// Surface used when a card sits on top of another card.
  final Color surfaceRaised;

  /// Hairline borders and dividers.
  final Color border;

  /// A stronger border for focused or selected elements.
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;

  /// Tint used behind accent icons and selected rows.
  final Color accentSoft;

  /// Tint used behind success icons and badges.
  final Color successSoft;

  /// Tint used behind error icons and badges.
  final Color errorSoft;

  /// Tint used behind warning icons and badges.
  final Color warningSoft;

  /// Shadow colour for the app's single elevation step.
  final Color shadow;

  /// Brightness this palette was built for.
  final Brightness brightness;

  const AppColors({
    required this.background,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceRaised,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.accentSoft,
    required this.successSoft,
    required this.errorSoft,
    required this.warningSoft,
    required this.shadow,
    required this.brightness,
  });

  bool get isDark => brightness == Brightness.dark;

  // ─── Brand colours (identical in both themes) ───────────────────────────
  static const Color accent = Color(0xFF11A697);
  static const Color accentStrong = Color(0xFF0C8578);
  static const Color connected = Color(0xFF16A34A);
  static const Color error = Color(0xFFDC2626);
  static const Color warning = Color(0xFFD97706);
  static const Color info = Color(0xFF2563EB);

  /// Accent adjusted for dark surfaces, where the brand teal is too dim.
  static const Color accentOnDark = Color(0xFF2DD4BF);
  static const Color connectedOnDark = Color(0xFF34D399);
  static const Color errorOnDark = Color(0xFFF87171);
  static const Color warningOnDark = Color(0xFFFBBF24);
  static const Color infoOnDark = Color(0xFF60A5FA);

  /// The accent at a legible contrast for the current theme.
  Color get accentText => isDark ? accentOnDark : accent;
  Color get connectedText => isDark ? connectedOnDark : connected;
  Color get errorText => isDark ? errorOnDark : error;
  Color get warningText => isDark ? warningOnDark : warning;
  Color get infoText => isDark ? infoOnDark : info;

  // ─── Light ──────────────────────────────────────────────────────────────
  static const AppColors light = AppColors(
    background: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF1F3F6),
    surfaceRaised: Color(0xFFFFFFFF),
    border: Color(0xFFE4E7EC),
    borderStrong: Color(0xFFCBD2DC),
    textPrimary: Color(0xFF10131A),
    textSecondary: Color(0xFF636B7A),
    textDisabled: Color(0xFF9AA2B1),
    accentSoft: Color(0xFFE1F5F2),
    successSoft: Color(0xFFE3F6E9),
    errorSoft: Color(0xFFFDE9E9),
    warningSoft: Color(0xFFFDF1DF),
    shadow: Color(0x14101828),
    brightness: Brightness.light,
  );

  // ─── Dark ───────────────────────────────────────────────────────────────
  static const AppColors dark = AppColors(
    background: Color(0xFF0B0E13),
    surface: Color(0xFF141920),
    surfaceMuted: Color(0xFF1B212A),
    surfaceRaised: Color(0xFF1E242E),
    border: Color(0xFF262D38),
    borderStrong: Color(0xFF3A424F),
    textPrimary: Color(0xFFF2F4F7),
    textSecondary: Color(0xFF98A1B0),
    textDisabled: Color(0xFF5E6673),
    accentSoft: Color(0xFF10302E),
    successSoft: Color(0xFF122C1F),
    errorSoft: Color(0xFF35191A),
    warningSoft: Color(0xFF32240F),
    shadow: Color(0x66000000),
    brightness: Brightness.dark,
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>() ?? dark;

  /// The app's single elevation step. Real shadow in light, a near-flat
  /// separation in dark where shadows read as smudges.
  List<BoxShadow> get cardShadow => isDark
      ? const []
      : [
          BoxShadow(
            color: shadow,
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ];

  /// A slightly stronger shadow for elements that float over content.
  List<BoxShadow> get floatingShadow => isDark
      ? [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ]
      : [
          BoxShadow(
            color: shadow,
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ];

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceMuted,
    Color? surfaceRaised,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? accentSoft,
    Color? successSoft,
    Color? errorSoft,
    Color? warningSoft,
    Color? shadow,
    Brightness? brightness,
  }) =>
      AppColors(
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceMuted: surfaceMuted ?? this.surfaceMuted,
        surfaceRaised: surfaceRaised ?? this.surfaceRaised,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textDisabled: textDisabled ?? this.textDisabled,
        accentSoft: accentSoft ?? this.accentSoft,
        successSoft: successSoft ?? this.successSoft,
        errorSoft: errorSoft ?? this.errorSoft,
        warningSoft: warningSoft ?? this.warningSoft,
        shadow: shadow ?? this.shadow,
        brightness: brightness ?? this.brightness,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      successSoft: Color.lerp(successSoft, other.successSoft, t)!,
      errorSoft: Color.lerp(errorSoft, other.errorSoft, t)!,
      warningSoft: Color.lerp(warningSoft, other.warningSoft, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      brightness: t < 0.5 ? brightness : other.brightness,
    );
  }
}

// ─── Typography ──────────────────────────────────────────────────────────────

/// Named text styles. Sizes are fixed; only colour varies by theme, and that is
/// applied by the widget from [AppColors].
abstract final class AppText {
  /// Screen titles.
  static const TextStyle title = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.2,
  );

  /// Card and section headings.
  static const TextStyle heading = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.25,
  );

  /// Primary row text.
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// Supporting text under a row.
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  /// Uppercase section labels above groups of cards.
  static const TextStyle overline = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.7,
    height: 1.2,
  );

  /// Numbers that should line up in a column (ping, speed, timer).
  static const TextStyle mono = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
    height: 1.2,
  );
}

// ─── ThemeData ───────────────────────────────────────────────────────────────

abstract final class AppTheme {
  static ThemeData get light => _build(AppColors.light);
  static ThemeData get dark => _build(AppColors.dark);

  /// Status/navigation bar styling that matches the given palette.
  static SystemUiOverlayStyle overlayStyle(AppColors c) {
    final iconBrightness = c.isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: iconBrightness,
      statusBarBrightness: c.brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: iconBrightness,
    );
  }

  static ThemeData _build(AppColors c) {
    final accent = c.accentText;

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      primaryColor: accent,
      splashFactory: InkSparkle.splashFactory,
      colorScheme: ColorScheme(
        brightness: c.brightness,
        primary: accent,
        onPrimary: c.isDark ? const Color(0xFF04211E) : Colors.white,
        primaryContainer: c.accentSoft,
        onPrimaryContainer: accent,
        secondary: accent,
        onSecondary: c.isDark ? const Color(0xFF04211E) : Colors.white,
        error: c.errorText,
        onError: Colors.white,
        errorContainer: c.errorSoft,
        onErrorContainer: c.errorText,
        surface: c.surface,
        onSurface: c.textPrimary,
        surfaceContainerHighest: c.surfaceMuted,
        onSurfaceVariant: c.textSecondary,
        outline: c.border,
        outlineVariant: c.border,
        shadow: c.shadow,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlayStyle(c),
        titleTextStyle: AppText.heading.copyWith(color: c.textPrimary),
        iconTheme: IconThemeData(color: c.textPrimary),
      ),
      textTheme: TextTheme(
        titleLarge: AppText.title.copyWith(color: c.textPrimary),
        titleMedium: AppText.heading.copyWith(color: c.textPrimary),
        bodyLarge: AppText.body.copyWith(color: c.textPrimary),
        bodyMedium: AppText.body.copyWith(color: c.textPrimary),
        bodySmall: AppText.caption.copyWith(color: c.textSecondary),
        labelSmall: AppText.overline.copyWith(color: c.textSecondary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceMuted,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: c.errorText),
        ),
        hintStyle: AppText.body.copyWith(color: c.textDisabled),
        labelStyle: AppText.caption.copyWith(color: c.textSecondary),
      ),
      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: c.textSecondary, size: 22),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
        titleTextStyle: AppText.heading.copyWith(color: c.textPrimary),
        contentTextStyle: AppText.body.copyWith(color: c.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: c.borderStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
          side: BorderSide(color: c.border),
        ),
        textStyle: AppText.body.copyWith(color: c.textPrimary),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: c.isDark ? const Color(0xFF04211E) : Colors.white,
          minimumSize: const Size.fromHeight(48),
          textStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.border),
          minimumSize: const Size.fromHeight(48),
          textStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : c.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : c.surfaceMuted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.transparent
              : c.borderStrong,
        ),
        trackOutlineWidth: const WidgetStatePropertyAll(1),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: c.surfaceMuted,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: c.surfaceMuted,
        circularTrackColor: c.surfaceMuted,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.isDark ? c.surfaceRaised : const Color(0xFF1F242C),
          borderRadius: AppRadius.smAll,
        ),
        textStyle: AppText.caption.copyWith(color: Colors.white),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      splashColor: accent.withValues(alpha: 0.10),
      highlightColor: accent.withValues(alpha: 0.05),
      fontFamily: 'Roboto',
    );
  }
}
