import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models/vpn_stats.dart';
import '../theme/app_theme.dart';

class PowerButton extends StatefulWidget {
  final VpnStatus status;
  final VoidCallback onTap;
  final double scale;

  const PowerButton({
    super.key,
    required this.status,
    required this.onTap,
    this.scale = 1.0,
  }) : assert(scale > 0);

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rippleController;
  late AnimationController _spinController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _pulseAnim = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _updateAnimations();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _updateAnimations();
  }

  void _updateAnimations() {
    if (widget.status == VpnStatus.connecting ||
        widget.status == VpnStatus.disconnecting) {
      _pulseController.repeat(reverse: true);
      _rippleController.repeat();
      _spinController.repeat();
    } else if (widget.status == VpnStatus.connected) {
      _pulseController.stop();
      _pulseController.reset();
      _rippleController.repeat();
      _spinController.stop();
      _spinController.reset();
    } else {
      _pulseController.stop();
      _pulseController.reset();
      _rippleController.stop();
      _rippleController.reset();
      _spinController.stop();
      _spinController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rippleController.dispose();
    _spinController.dispose();
    super.dispose();
  }

  List<Color> get _gradientColors {
    switch (widget.status) {
      case VpnStatus.connected:
        return [const Color(0xFF43E97B), const Color(0xFF38F9D7)];
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return [const Color(0xFF4FC3F7), const Color(0xFF2979FF)];
      case VpnStatus.error:
        return [const Color(0xFFFF8A80), const Color(0xFFEF5350)];
      case VpnStatus.disconnected:
        return [const Color(0xFF3A4268), const Color(0xFF1B1F3A)];
    }
  }

  Color get _glowColor {
    switch (widget.status) {
      case VpnStatus.connected:
        return const Color(0xFF00E676);
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return AppColors.accent;
      case VpnStatus.error:
        return AppColors.error;
      case VpnStatus.disconnected:
        return const Color(0xFF3D4880);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge(
            [_pulseController, _rippleController, _spinController]),
        builder: (context, _) {
          final isTransitioning = widget.status == VpnStatus.connecting ||
              widget.status == VpnStatus.disconnecting;
          final scale = isTransitioning ? _pulseAnim.value : 1.0;
          final size = 210 * widget.scale;
          final arcSize = 148 * widget.scale;
          final coreButtonSize = 120 * widget.scale;
          final progressSize = 40 * widget.scale;
          final iconSize = 56 * widget.scale;

          return Transform.scale(
            scale: scale,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // ── Ripple rings ──────────────────────────────────────────
                  if (widget.status == VpnStatus.connected ||
                      widget.status == VpnStatus.connecting)
                    CustomPaint(
                      size: Size(size, size),
                      painter: _RipplePainter(
                        color: _glowColor,
                        progress: _rippleController.value,
                        scale: widget.scale,
                      ),
                    ),

                  // ── Static faint rings ────────────────────────────────────
                  CustomPaint(
                    size: Size(size, size),
                    painter: _StaticRingsPainter(
                      color: _glowColor,
                      isActive: widget.status != VpnStatus.disconnected,
                      scale: widget.scale,
                    ),
                  ),

                  // ── Spinning arc (connecting) ─────────────────────────────
                  if (isTransitioning)
                    Transform.rotate(
                      angle: _spinController.value * 2 * math.pi,
                      child: CustomPaint(
                        size: Size(arcSize, arcSize),
                        painter:
                            _ArcPainter(color: _glowColor, scale: widget.scale),
                      ),
                    ),

                  // ── Main button ───────────────────────────────────────────
                  Container(
                    width: coreButtonSize,
                    height: coreButtonSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: _gradientColors,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _glowColor.withValues(
                              alpha:
                              widget.status == VpnStatus.disconnected
                                  ? 0.25
                                  : 0.5),
                          blurRadius: 30 * widget.scale,
                          spreadRadius: 4 * widget.scale,
                        ),
                        BoxShadow(
                          color: _glowColor.withValues(alpha: 0.15),
                          blurRadius: 60 * widget.scale,
                          spreadRadius: 12 * widget.scale,
                        ),
                      ],
                    ),
                    child: isTransitioning
                        ? Center(
                            child: SizedBox(
                              width: progressSize,
                              height: progressSize,
                              child: CircularProgressIndicator(
                                strokeWidth: 3 * widget.scale,
                                valueColor:
                                    const AlwaysStoppedAnimation(Colors.white),
                              ),
                            ),
                          )
                        : Icon(
                            Icons.power_settings_new_rounded,
                            size: iconSize,
                            color: Colors.white,
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────────────────

class _StaticRingsPainter extends CustomPainter {
  final Color color;
  final bool isActive;
  final double scale;

  _StaticRingsPainter({
    required this.color,
    required this.isActive,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radii = [68.0 * scale, 82.0 * scale, 96.0 * scale];
    for (int i = 0; i < radii.length; i++) {
      final opacity = isActive
          ? (0.18 - i * 0.05).clamp(0.0, 1.0)
          : (0.06 - i * 0.015).clamp(0.0, 1.0);
      canvas.drawCircle(
        center,
        radii[i],
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..strokeWidth = 1.2 * scale
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_StaticRingsPainter old) =>
      old.color != color || old.isActive != isActive;
}

class _RipplePainter extends CustomPainter {
  final Color color;
  final double progress;
  final double scale;

  _RipplePainter({
    required this.color,
    required this.progress,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (int i = 0; i < 2; i++) {
      final p = (progress + i * 0.5) % 1.0;
      final radius = 64.0 * scale + p * 46.0 * scale;
      final opacity = (0.4 * (1 - p)).clamp(0.0, 1.0);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..strokeWidth = 2.0 * scale
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.color != color;
}

class _ArcPainter extends CustomPainter {
  final Color color;
  final double scale;

  _ArcPainter({required this.color, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4 * scale;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 1.3,
      false,
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 3.5 * scale
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
