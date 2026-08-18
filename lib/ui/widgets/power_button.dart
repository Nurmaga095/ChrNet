import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/vpn_stats.dart';
import '../perf.dart';
import '../theme/app_theme.dart';

/// The connect/disconnect control.
///
/// One circle, one ring, one icon. The ring carries all the state: static and
/// faint when idle, a sweeping arc while the tunnel comes up, and a solid
/// coloured halo once connected. No gradients, no stacked glows — on a dark and
/// a light background alike the shape reads the same.
class PowerButton extends StatefulWidget {
  final VpnStatus status;
  final VoidCallback onTap;

  /// Diameter of the outer ring in logical pixels.
  final double size;

  const PowerButton({
    super.key,
    required this.status,
    required this.onTap,
    this.size = 176,
  }) : assert(size > 0);

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  bool _pressed = false;

  bool get _isBusy =>
      widget.status == VpnStatus.connecting ||
      widget.status == VpnStatus.disconnecting;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    AppPerf.instance.addListener(_syncAnimation);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _syncAnimation();
  }

  /// The sweep runs only while connecting — it is a progress indicator, so it
  /// survives reduced motion. The connected halo is static by design.
  void _syncAnimation() {
    if (!mounted) return;
    if (_isBusy) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    AppPerf.instance.removeListener(_syncAnimation);
    _spin.dispose();
    super.dispose();
  }

  Color _stateColor(AppColors c) => switch (widget.status) {
        VpnStatus.connected => c.connectedText,
        VpnStatus.connecting || VpnStatus.disconnecting => c.accentText,
        VpnStatus.error => c.errorText,
        VpnStatus.disconnected => c.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = _stateColor(c);
    final isConnected = widget.status == VpnStatus.connected;
    final size = widget.size;
    final coreSize = size * 0.72;

    return Semantics(
      button: true,
      label: isConnected ? 'Отключить VPN' : 'Подключить VPN',
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: AppMotion.fast,
          curve: AppMotion.curve,
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Outer ring — the state indicator.
                if (_isBusy)
                  AnimatedBuilder(
                    animation: _spin,
                    builder: (_, __) => CustomPaint(
                      size: Size.square(size),
                      painter: _SweepPainter(
                        progress: _spin.value,
                        trackColor: c.border,
                        arcColor: color,
                      ),
                    ),
                  )
                else
                  CustomPaint(
                    size: Size.square(size),
                    painter: _RingPainter(
                      color: isConnected
                          ? color.withValues(alpha: 0.35)
                          : c.border,
                      width: isConnected ? 4 : 2,
                    ),
                  ),

                // Core.
                AnimatedContainer(
                  duration: AppMotion.normal,
                  curve: AppMotion.curve,
                  width: coreSize,
                  height: coreSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConnected ? color : c.surface,
                    border: isConnected
                        ? null
                        : Border.all(color: c.border, width: 1),
                    boxShadow: isConnected
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.32),
                              blurRadius: 28,
                              spreadRadius: 2,
                            ),
                          ]
                        : c.cardShadow,
                  ),
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    size: coreSize * 0.36,
                    color: isConnected ? Colors.white : color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  final double width;

  const _RingPainter({required this.color, required this.width});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (size.shortestSide - width) / 2;
    canvas.drawCircle(
      size.center(Offset.zero),
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.width != width;
}

class _SweepPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color arcColor;

  const _SweepPainter({
    required this.progress,
    required this.trackColor,
    required this.arcColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - stroke) / 2,
    );

    canvas.drawCircle(
      rect.center,
      rect.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = trackColor,
    );

    canvas.drawArc(
      rect,
      progress * math.pi * 2 - math.pi / 2,
      math.pi * 0.55,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = arcColor,
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) =>
      old.progress != progress ||
      old.trackColor != trackColor ||
      old.arcColor != arcColor;
}
