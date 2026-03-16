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
    final baseSurface = isDark
        ? colors.cardBackground.withValues(alpha: 0.88)
        : Colors.white.withValues(alpha: 0.92);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: br,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: baseSurface),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: const SizedBox.expand(),
              ),
            ),
            Container(
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
                          Colors.white.withValues(alpha: 0.78),
                          const Color(0xFFE8EEF6).withValues(alpha: 0.7),
                        ],
                ),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color:
                              const Color(0xFF9CA9BC).withValues(alpha: 0.18),
                          blurRadius: 28,
                          offset: const Offset(0, 14),
                        ),
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.42),
                          blurRadius: 16,
                          offset: const Offset(0, -2),
                        ),
                      ],
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.14)
                      : const Color(0xFFD9E2ED).withValues(alpha: 0.92),
                  width: isDark ? 0.5 : 0.9,
                ),
              ),
              padding: padding,
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
