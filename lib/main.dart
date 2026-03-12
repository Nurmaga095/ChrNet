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
            Positioned.fill(
              child: ColoredBox(color: AppColors.of(context).background),
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
