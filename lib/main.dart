import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/storage_service.dart';
import 'core/services/vpn_provider.dart';
import 'features/home/home_screen.dart';
import 'features/privacy/privacy_screens.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/theme_controller.dart';

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

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
      ],
      child: const ChrNetApp(),
    ),
  );
}

class ChrNetApp extends StatelessWidget {
  const ChrNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'ChrNet VPN',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: AppThemeController.instance.mode,
          builder: (context, child) {
            if (child == null) return const SizedBox.shrink();

            // Text scale beyond ~1.3 breaks the fixed-height hero and the
            // two-line server rows, so the app clamps it rather than clipping.
            final media = MediaQuery.of(context);
            Widget content = MediaQuery(
              data: media.copyWith(
                textScaler: media.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              child: child,
            );

            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: AppTheme.overlayStyle(AppColors.of(context)),
              child: ColoredBox(
                color: AppColors.of(context).background,
                child: content,
              ),
            );
          },
          home: const PrivacyDisclosureGate(
            child: HomeScreen(),
          ),
        );
      },
    );
  }
}
