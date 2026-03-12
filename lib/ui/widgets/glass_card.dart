import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A frosted-glass container — iOS 26 Liquid Glass style.
///
/// Place this on top of a colourful background (e.g. the aurora) so that the
/// blur effect has something interesting to blur.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final double blur;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.blur = 18,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = AppColors.of(context);
    final br = borderRadius ?? BorderRadius.circular(20);
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: br,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      Colors.white.withValues(alpha: 0.09),
                      Colors.white.withValues(alpha: 0.04),
                    ]
                  : [
                      colors.cardBackground.withValues(alpha: 0.92),
                      colors.surfaceColor.withValues(alpha: 0.82),
                    ],
            ),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: colors.borderColor.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.14)
                  : colors.borderColor.withValues(alpha: 0.95),
              width: isDark ? 0.5 : 0.9,
            ),
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}
