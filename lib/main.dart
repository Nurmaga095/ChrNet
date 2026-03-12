import 'dart:math' as math;
import 'dart:ui';
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
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logicalSize = view.physicalSize / view.devicePixelRatio;
    final shortestSide = math.min(logicalSize.width, logicalSize.height);
    final isTablet = shortestSide >= 600;

    await SystemChrome.setPreferredOrientations(
      isTablet
          ? DeviceOrientation.values
          : [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
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
            Positioned.fill(child: _AuroraBackground(isDark: isDark)),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: ColoredBox(
                  color: (isDark ? Colors.black : Colors.white)
                      .withValues(alpha: 0.45),
                ),
              ),
            ),
            Positioned.fill(child: watermark),
            Positioned.fill(child: content),
          ],
        );
      },
      home: const HomeScreen(),
    );
  }
}

// ─── Aurora animated background ─────────────────────────────────────────────

class _AuroraBackground extends StatefulWidget {
  final bool isDark;
  const _AuroraBackground({required this.isDark});

  @override
  State<_AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<_AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _AuroraPainter(_ctrl.value, widget.isDark),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Blob {
  final Color color;
  final double dx, dy, r, speedX, speedY;
  const _Blob({
    required this.color,
    required this.dx,
    required this.dy,
    required this.r,
    required this.speedX,
    required this.speedY,
  });
}

class _AuroraPainter extends CustomPainter {
  final double t;
  final bool isDark;

  const _AuroraPainter(this.t, this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = isDark ? const Color(0xFF0D0F14) : const Color(0xFFF0F4FA);
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final blobs = isDark
        ? [
            const _Blob(
              color: Color(0x501A237E),
              dx: 0.15, dy: 0.2, r: 0.5,
              speedX: 0.07, speedY: 0.05,
            ),
            const _Blob(
              color: Color(0x400D47A1),
              dx: 0.75, dy: 0.55, r: 0.45,
              speedX: -0.05, speedY: 0.08,
            ),
            const _Blob(
              color: Color(0x38311B92),
              dx: 0.45, dy: 0.85, r: 0.4,
              speedX: 0.06, speedY: -0.07,
            ),
            const _Blob(
              color: Color(0x2801579B),
              dx: 0.6, dy: 0.15, r: 0.38,
              speedX: -0.08, speedY: 0.06,
            ),
          ]
        : [
            const _Blob(
              color: Color(0x38BBDEFB),
              dx: 0.15, dy: 0.2, r: 0.5,
              speedX: 0.07, speedY: 0.05,
            ),
            const _Blob(
              color: Color(0x301565C0),
              dx: 0.75, dy: 0.55, r: 0.45,
              speedX: -0.05, speedY: 0.08,
            ),
            const _Blob(
              color: Color(0x28E3F2FD),
              dx: 0.45, dy: 0.85, r: 0.4,
              speedX: 0.06, speedY: -0.07,
            ),
            const _Blob(
              color: Color(0x2090CAF9),
              dx: 0.6, dy: 0.15, r: 0.38,
              speedX: -0.08, speedY: 0.06,
            ),
          ];

    final maxR = math.max(size.width, size.height);
    for (final b in blobs) {
      final x =
          size.width * (b.dx + math.sin(t * math.pi * 2 * b.speedX) * 0.18);
      final y =
          size.height * (b.dy + math.cos(t * math.pi * 2 * b.speedY) * 0.18);
      final r = maxR * b.r;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [b.color, b.color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: Offset(x, y), radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t || old.isDark != isDark;
}

// ─── Brand watermark ─────────────────────────────────────────────────────────

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
