import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum AppNavTab { connection, settings }

/// The app's bottom navigation: a docked bar with a hairline top border.
///
/// Replaces the floating frosted pill. Full-width items give a much larger
/// touch target, and the flat surface costs nothing to paint.
class AppNavBar extends StatelessWidget {
  final AppNavTab activeTab;
  final VoidCallback onConnectionTap;
  final VoidCallback onSettingsTap;

  const AppNavBar({
    super.key,
    required this.activeTab,
    required this.onConnectionTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              Expanded(
                child: _NavItem(
                  icon: Icons.shield_outlined,
                  activeIcon: Icons.shield_rounded,
                  label: 'Подключение',
                  isActive: activeTab == AppNavTab.connection,
                  onTap: onConnectionTap,
                ),
              ),
              Expanded(
                child: _NavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings_rounded,
                  label: 'Настройки',
                  isActive: activeTab == AppNavTab.settings,
                  onTap: onSettingsTap,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = isActive ? c.accentText : c.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: AppMotion.fast,
              curve: AppMotion.curve,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 3),
              decoration: BoxDecoration(
                color: isActive ? c.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(isActive ? activeIcon : icon, size: 21, color: color),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: color,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
