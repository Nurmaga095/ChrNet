import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The one card surface the app uses.
///
/// Replaces the old frosted-glass container: a flat surface, a hairline border
/// and — in light mode only — a single soft shadow. No blur, so it costs one
/// draw call instead of a full-screen `saveLayer` per card.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;

  /// Tap target for the whole card. When set, the card gets an ink response.
  final VoidCallback? onTap;

  /// Draws the card with the accent border used for selected state.
  final bool isHighlighted;

  /// Uses the recessed surface instead of the default one — for cards nested
  /// inside another card.
  final bool muted;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.borderRadius = AppRadius.lgAll,
    this.onTap,
    this.isHighlighted = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    Widget content = Padding(
      padding: padding ?? EdgeInsets.zero,
      child: child,
    );

    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          child: content,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: muted ? c.surfaceMuted : c.surface,
        borderRadius: borderRadius,
        border: Border.all(
          color: isHighlighted ? c.accentText.withValues(alpha: 0.5) : c.border,
          width: isHighlighted ? 1.4 : 1,
        ),
        boxShadow: muted ? const [] : c.cardShadow,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: content,
      ),
    );
  }
}

/// An uppercase label introducing a group of cards.
class AppSectionLabel extends StatelessWidget {
  final String text;

  /// Optional trailing widget, e.g. a count or an action.
  final Widget? trailing;

  const AppSectionLabel({super.key, required this.text, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        0,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: AppText.overline.copyWith(color: c.textSecondary),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A small rounded icon plate — the app's standard leading element for rows.
class AppIconPlate extends StatelessWidget {
  final IconData icon;
  final Color color;

  /// Background tint. Defaults to a 12% wash of [color].
  final Color? background;
  final double size;

  const AppIconPlate({
    super.key,
    required this.icon,
    required this.color,
    this.background,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(icon, size: size * 0.52, color: color),
    );
  }
}

/// A borderless square icon button used in headers and card actions.
class AppIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final double size;
  final bool isBusy;

  const AppIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.color,
    this.size = 40,
    this.isBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final resolved = color ?? c.textSecondary;
    final enabled = onTap != null && !isBusy;

    Widget button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: AppRadius.mdAll,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: isBusy
                ? SizedBox(
                    width: size * 0.42,
                    height: size * 0.42,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: resolved,
                    ),
                  )
                : Icon(
                    icon,
                    size: size * 0.52,
                    color: enabled ? resolved : c.textDisabled,
                  ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// A compact status pill: coloured dot or icon plus a label.
class AppPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  /// Fills the pill with a tint of [color]. Otherwise only the text is tinted.
  final Color? background;

  const AppPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppText.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
