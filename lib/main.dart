import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/storage_service.dart';
import 'core/services/theme_provider.dart';
import 'core/services/vpn_provider.dart';
import 'features/home/home_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  await StorageService.init();

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    DeepLinkService.initFromArgs(args);
  }

  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows)) {
    DeepLinkService.initChannel();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => VpnProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const ChrNetApp(),
    ),
  );
}

class ChrNetApp extends StatelessWidget {
  const ChrNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeProvider>().themeMode;

    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
      ));
    }

    return MaterialApp(
      title: 'ChrNet VPN',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();

        Widget content = child;
        if (!kIsWeb && Theme.of(context).platform == TargetPlatform.windows) {
          content = Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 500, child: content),
          );
        }

        Widget watermark = IgnorePointer(
          child: CustomPaint(
            painter: _BrandWatermarkPainter(
              AppColors.of(context).textSecondary.withValues(alpha: 0.13),
            ),
            child: const SizedBox.expand(),
          ),
        );

        if (!kIsWeb && Theme.of(context).platform == TargetPlatform.windows) {
          watermark = Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 500, child: watermark),
          );
        }

        return Stack(
          children: [
            const Positioned.fill(child: _AuroraBackground()),
            Positioned.fill(child: watermark),
            Positioned.fill(child: content),
          ],
        );
      },
      home: const HomeScreen(),
    );
  }
}

// ─── Aurora Background ────────────────────────────────────────────────────────

class _AuroraBackground extends StatefulWidget {
  const _AuroraBackground();

  @override
  State<_AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<_AuroraBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => CustomPaint(
          painter: _AuroraPainter(_ctrl.value, isDark),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final bool isDark;

  const _AuroraPainter(this.t, this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const pi2 = math.pi * 2;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..color = isDark ? const Color(0xFF08091A) : const Color(0xFFECEEFF),
    );

    _drawBlob(
      canvas,
      cx: w * (0.28 + 0.14 * math.sin(t * pi2 * 0.7)),
      cy: h * (0.22 + 0.12 * math.cos(t * pi2 * 0.5)),
      radius: w * 0.50,
      color: isDark
          ? const Color(0xFF1A3AFF).withValues(alpha: 0.28)
          : const Color(0xFF90C2FF).withValues(alpha: 0.36),
    );

    _drawBlob(
      canvas,
      cx: w * (0.78 + 0.10 * math.cos(t * pi2 * 0.6)),
      cy: h * (0.30 + 0.14 * math.sin(t * pi2 * 0.4)),
      radius: w * 0.45,
      color: isDark
          ? const Color(0xFF7C1AFF).withValues(alpha: 0.22)
          : const Color(0xFFD4A0FF).withValues(alpha: 0.28),
    );

    _drawBlob(
      canvas,
      cx: w * (0.50 + 0.10 * math.sin(t * pi2 * 0.9)),
      cy: h * (0.68 + 0.10 * math.cos(t * pi2 * 0.7)),
      radius: w * 0.40,
      color: isDark
          ? const Color(0xFF00B4D8).withValues(alpha: 0.16)
          : const Color(0xFFA0E8F0).withValues(alpha: 0.25),
    );

    _drawBlob(
      canvas,
      cx: w * (0.15 + 0.08 * math.cos(t * pi2 * 1.1)),
      cy: h * (0.80 + 0.08 * math.sin(t * pi2 * 0.8)),
      radius: w * 0.35,
      color: isDark
          ? const Color(0xFFFF1A6B).withValues(alpha: 0.12)
          : const Color(0xFFFFB8D0).withValues(alpha: 0.26),
    );
  }

  void _drawBlob(
    Canvas canvas, {
    required double cx,
    required double cy,
    required double radius,
    required Color color,
  }) {
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(
          Rect.fromCircle(center: Offset(cx, cy), radius: radius),
        ),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t || old.isDark != isDark;
}

class _BrandWatermarkPainter extends CustomPainter {
  final Color color;

  const _BrandWatermarkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const text = 'ChrNet';
    const fontSize = 20.0;
    const spacingX = 120.0;
    const spacingY = 75.0;
    const angle = -math.pi / 6;

    final textStyle = TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    );

    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final diagonal =
        math.sqrt(size.width * size.width + size.height * size.height);
    final cols = (diagonal / spacingX).ceil() + 2;
    final rows = (diagonal / spacingY).ceil() + 2;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle);
    canvas.translate(-diagonal / 2, -diagonal / 2);

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final offset = Offset(
          col * spacingX + (row.isOdd ? spacingX / 2 : 0),
          row * spacingY,
        );
        tp.paint(canvas, offset);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_BrandWatermarkPainter old) => old.color != color;
}
