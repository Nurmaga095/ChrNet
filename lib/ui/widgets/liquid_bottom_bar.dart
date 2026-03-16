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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 236),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.10),
                      Colors.white.withValues(alpha: 0.04),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
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
                      ),
                    ),
                    Expanded(
                      child: _BarItem(
                        icon: Icons.settings_rounded,
                        label: 'Настройки',
                        isActive: activeTab == LiquidBottomBarTab.settings,
                        onTap: onSettingsTap,
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

  const _BarItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: isActive
                      ? LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.48, 1],
                          colors: [
                            Colors.white.withValues(alpha: 0.24),
                            Colors.white.withValues(alpha: 0.10),
                            Colors.white.withValues(alpha: 0.02),
                          ],
                        )
                      : null,
                  color: isActive ? null : Colors.transparent,
                  boxShadow: isActive
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 14,
                            spreadRadius: -1,
                            offset: const Offset(0, 5),
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
                      color: isActive ? Colors.white : c.textSecondary,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isActive ? Colors.white : c.textSecondary,
                        fontSize: 9.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              // Radial highlight — яркое пятно света сверху активной кнопки
              if (isActive)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        gradient: RadialGradient(
                          center: const Alignment(0, -1.3),
                          radius: 0.9,
                          colors: [
                            Colors.white.withValues(alpha: 0.40),
                            Colors.white.withValues(alpha: 0.10),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.35, 0.75],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
