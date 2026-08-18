import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A country flag for the server list.
///
/// The flags are bundled rather than drawn from the platform emoji font:
/// Windows ships no flag glyphs in Segoe UI Emoji (it renders 🇳🇱 as "NL"),
/// and on the web it depends entirely on the host font. Bundling is the only
/// way the list looks the same everywhere.
///
/// Codes the flag set does not cover fall back to a lettered badge.
class CountryFlagIcon extends StatelessWidget {
  /// Two-letter ISO 3166-1 alpha-2 code, e.g. `RU`.
  final String countryCode;

  /// Side of the square slot the flag is centred in.
  final double size;

  const CountryFlagIcon({
    super.key,
    required this.countryCode,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    final code = countryCode.trim().toUpperCase();

    if (FlagCode.fromCountryCode(code) != null) {
      // Flags are 4:3, so the artwork is inset in the square slot instead of
      // being stretched to fill it.
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: CountryFlag.fromCountryCode(
            code,
            theme: ImageTheme(
              width: size,
              height: size * 0.75,
              shape: RoundedRectangle(size * 0.16),
            ),
          ),
        ),
      );
    }

    final colors = AppColors.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        code.length >= 2 ? code.substring(0, 2) : code,
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: colors.textSecondary,
          height: 1.0,
        ),
      ),
    );
  }
}
