import 'package:flutter/material.dart';
import '../../core/models/vpn_stats.dart';
import '../theme/app_theme.dart';

class StatsCard extends StatelessWidget {
  final VpnStats stats;

  const StatsCard({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StatItem(
          icon: Icons.arrow_downward_rounded,
          iconColor: AppColors.connected,
          value: stats.downloadSpeedFormatted,
        ),
        const SizedBox(width: 28),
        _StatItem(
          icon: Icons.arrow_upward_rounded,
          iconColor: AppColors.accent,
          value: stats.uploadSpeedFormatted,
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;

  const _StatItem({
    required this.icon,
    required this.iconColor,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: iconColor),
        const SizedBox(width: 5),
        Text(
          value,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
