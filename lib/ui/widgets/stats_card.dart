import 'package:flutter/material.dart';

import '../../core/models/vpn_stats.dart';
import '../theme/app_theme.dart';

/// Live throughput, shown under the connect button.
///
/// One line, no card: the numbers are glanceable telemetry, not content worth
/// a surface of their own. Tabular figures keep them from jittering as they
/// tick, and each item is fixed-width so the row does not reflow.
class StatsCard extends StatelessWidget {
  final VpnStats stats;

  const StatsCard({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StatItem(
          icon: Icons.south_rounded,
          color: c.connectedText,
          value: stats.downloadSpeedFormatted,
        ),
        const SizedBox(width: AppSpacing.lg),
        _StatItem(
          icon: Icons.north_rounded,
          color: c.accentText,
          value: stats.uploadSpeedFormatted,
        ),
        const SizedBox(width: AppSpacing.lg),
        _StatItem(
          icon: Icons.swap_vert_rounded,
          color: c.textDisabled,
          value: VpnStats.formatBytes(
            stats.downloadBytes + stats.uploadBytes,
          ),
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;

  const _StatItem({
    required this.icon,
    required this.color,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono.copyWith(color: c.textSecondary, fontSize: 12.5),
        ),
      ],
    );
  }
}
