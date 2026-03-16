import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum LiquidBottomBarTab { connection, settings }

class LiquidBottomBar extends StatelessWidget {
  final LiquidBottomBarTab activeTab;
  final VoidCallback onConnectionTap;
  final VoidCallback onSettingsTap;

  const LiquidBottomBar({
    super.key,
    required this.activeTab,
    required this.onConnectionTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = AppColors.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 236),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [
                            const Color(0xFF5B626B).withValues(alpha: 0.28),
                            const Color(0xFF2E343B).withValues(alpha: 0.5),
                          ]
                        : [
                            const Color(0xFFF4F6FA).withValues(alpha: 0.44),
                            const Color(0xFFCDD6E2).withValues(alpha: 0.34),
                          ],
                  ),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : const Color(0xFFE3EAF3).withValues(alpha: 0.82),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.18 : 0.1),
                      blurRadius: 12,
                      offset: const Offset(0, 7),
                    ),
                    BoxShadow(
                      color:
                          Colors.white.withValues(alpha: isDark ? 0.04 : 0.22),
                      blurRadius: 12,
                      spreadRadius: 0.2,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _BarItem(
                        icon: Icons.phone_in_talk_rounded,
                        label: 'Подключение',
                        isActive: activeTab == LiquidBottomBarTab.connection,
                        onTap: onConnectionTap,
                        textColor: c.textPrimary,
                      ),
                    ),
                    Expanded(
                      child: _BarItem(
                        icon: Icons.settings_rounded,
                        label: 'Настройки',
                        isActive: activeTab == LiquidBottomBarTab.settings,
                        onTap: onSettingsTap,
                        textColor: c.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final Color textColor;

  const _BarItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = AppColors.of(context);
    final activeForeground =
        isDark ? Colors.white.withValues(alpha: 0.86) : const Color(0xFF172132);
    final inactiveForeground =
        isDark ? c.textSecondary : const Color(0xFF657084);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: isActive
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isDark
                        ? [
                            Colors.white.withValues(alpha: 0.2),
                            Colors.white.withValues(alpha: 0.1),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.44),
                            const Color(0xFFDCE3EC).withValues(alpha: 0.36),
                          ],
                  )
                : null,
            color: isActive ? null : Colors.transparent,
            border: Border.all(
              color: isActive
                  ? Colors.white.withValues(alpha: isDark ? 0.12 : 0.42)
                  : Colors.transparent,
              width: 1,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.12 : 0.08),
                      blurRadius: 9,
                      spreadRadius: 0.2,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isActive ? activeForeground : inactiveForeground,
              ),
              const SizedBox(height: 1),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? activeForeground : textColor,
                  fontSize: 9.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
