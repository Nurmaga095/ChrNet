import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/app_info_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/vpn_provider.dart';
import '../privacy/privacy_screens.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/glass_card.dart';
import '../../ui/widgets/liquid_bottom_bar.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _appVersion = '...';
  String? _latestGithubVersion;
  bool _isCheckingGithubVersion = false;
  bool _githubVersionCheckFailed = false;
  bool _isInstallingUpdate = false;
  double? _updateDownloadProgress;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_checkGithubVersion(showNotice: false));
    }
  }

  Future<void> _loadAppVersion() async {
    final version = await AppInfoService.getVersion();
    if (!mounted) {
      return;
    }
    setState(() => _appVersion = version);
  }

  bool get _isWindowsSelfUpdateSupported =>
      AppUpdateService.isWindowsSelfUpdateSupported;

  bool get _hasWindowsUpdateAvailable {
    if (!_isWindowsSelfUpdateSupported || _latestGithubVersion == null) {
      return false;
    }

    final installedVersion = _appVersion == '...' || _appVersion == 'unknown'
        ? '0.0.0'
        : _appVersion;
    return AppInfoService.compareVersions(
          installedVersion,
          _latestGithubVersion!,
        ) <
        0;
  }

  String get _windowsUpdateLabel {
    if (_isInstallingUpdate) {
      final progress = _updateDownloadProgress;
      if (progress == null) {
        return 'Подготовка обновления...';
      }

      return 'Скачивание обновления ${(progress * 100).round()}%';
    }

    if (_latestGithubVersion != null) {
      return 'Обновить до v$_latestGithubVersion';
    }

    return 'Обновить приложение';
  }

  Future<void> _checkGithubVersion({bool showNotice = true}) async {
    if (_isCheckingGithubVersion) {
      return;
    }

    setState(() => _isCheckingGithubVersion = true);

    final latestVersion = await AppInfoService.getLatestGithubVersion(
      forceRefresh: true,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isCheckingGithubVersion = false;
      _latestGithubVersion = latestVersion;
      _githubVersionCheckFailed = latestVersion == null;
    });

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();

    if (latestVersion == null) {
      if (showNotice) {
        _showVersionCheckNotice(
          message: 'Не удалось получить версию из GitHub.',
          type: _VersionNoticeType.error,
        );
      }
      return;
    }

    final installedVersion =
        _appVersion == '...' ? await AppInfoService.getVersion() : _appVersion;

    if (_appVersion == '...' && mounted) {
      setState(() => _appVersion = installedVersion);
    }

    final comparison = AppInfoService.compareVersions(
      installedVersion,
      latestVersion,
    );

    final message = comparison < 0
        ? 'Доступна новая версия: v$latestVersion'
        : comparison == 0
            ? 'У вас актуальная версия: v$latestVersion'
            : 'Локальная версия новее релиза GitHub: v$installedVersion';

    if (!mounted) {
      return;
    }

    if (showNotice) {
      _showVersionCheckNotice(
        message: message,
        type: comparison < 0
            ? _VersionNoticeType.warning
            : comparison == 0
                ? _VersionNoticeType.success
                : _VersionNoticeType.info,
      );
    }
  }

  Future<void> _installWindowsUpdate() async {
    if (_isInstallingUpdate || !_isWindowsSelfUpdateSupported) {
      return;
    }

    final vpnProvider = context.read<VpnProvider>();
    var latestVersion = _latestGithubVersion;
    if (latestVersion == null) {
      latestVersion = await AppInfoService.getLatestGithubVersion(
        forceRefresh: true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _latestGithubVersion = latestVersion;
        _githubVersionCheckFailed = latestVersion == null;
      });
    }

    if (latestVersion == null) {
      _showVersionCheckNotice(
        message: 'Сначала проверьте доступную версию на GitHub.',
        type: _VersionNoticeType.error,
      );
      return;
    }

    final installedVersion =
        _appVersion == '...' ? await AppInfoService.getVersion() : _appVersion;

    if (_appVersion == '...' && mounted) {
      setState(() => _appVersion = installedVersion);
    }

    final comparison = AppInfoService.compareVersions(
      installedVersion,
      latestVersion,
    );
    if (comparison >= 0) {
      _showVersionCheckNotice(
        message: 'У вас уже установлена актуальная версия.',
        type: _VersionNoticeType.success,
      );
      return;
    }

    setState(() {
      _isInstallingUpdate = true;
      _updateDownloadProgress = 0;
    });

    try {
      if (vpnProvider.isConnected || vpnProvider.isConnecting) {
        await vpnProvider.disconnect();
      }

      final installerFile =
          await AppUpdateService.downloadLatestWindowsInstaller(
        targetVersion: latestVersion,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() => _updateDownloadProgress = progress.clamp(0.0, 1.0));
        },
      );

      await AppUpdateService.launchInstaller(installerFile);

      if (!mounted) {
        return;
      }

      _showVersionCheckNotice(
        message:
            'Установщик обновления запущен. Подтвердите установку Windows.',
        type: _VersionNoticeType.info,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }

      _showVersionCheckNotice(
        message: 'Не удалось скачать или запустить обновление.',
        type: _VersionNoticeType.error,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isInstallingUpdate = false;
          _updateDownloadProgress = null;
        });
      }
    }
  }

  void _showVersionCheckNotice({
    required String message,
    required _VersionNoticeType type,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final c = AppColors.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;

    final (icon, tint) = switch (type) {
      _VersionNoticeType.success => (
          Icons.verified_rounded,
          AppColors.connected,
        ),
      _VersionNoticeType.warning => (
          Icons.system_update_alt_rounded,
          AppColors.warning,
        ),
      _VersionNoticeType.error => (
          Icons.error_rounded,
          AppColors.error,
        ),
      _VersionNoticeType.info => (
          Icons.info_rounded,
          AppColors.accent,
        ),
    };

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        width: viewportWidth > 420 ? 360 : viewportWidth - 24,
        margin: EdgeInsets.only(
          left: viewportWidth > 420 ? 0 : 12,
          right: viewportWidth > 420 ? 0 : 12,
          bottom: 18,
        ),
        duration: const Duration(seconds: 3),
        padding: EdgeInsets.zero,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: c.cardBackground.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: tint.withValues(alpha: 0.22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
              BoxShadow(
                color: tint.withValues(alpha: 0.08),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tint, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _githubVersionStatus {
    if (_isCheckingGithubVersion) {
      return 'Проверка версии...';
    }
    if (_githubVersionCheckFailed) {
      return 'Ошибка проверки версии';
    }
    if (_latestGithubVersion == null) {
      return 'Нажмите кнопку проверки';
    }

    final comparison = AppInfoService.compareVersions(
      _appVersion,
      _latestGithubVersion!,
    );

    if (comparison < 0) {
      return 'Доступна v$_latestGithubVersion';
    }
    if (comparison == 0) {
      return 'Актуальная v$_latestGithubVersion';
    }
    return 'Локальная сборка новее v$_latestGithubVersion';
  }

  Color _githubVersionStatusColor(BuildContext context) {
    if (_isCheckingGithubVersion) {
      return AppColors.of(context).textSecondary;
    }
    if (_githubVersionCheckFailed) {
      return AppColors.error;
    }
    if (_latestGithubVersion == null) {
      return AppColors.of(context).textSecondary;
    }

    final comparison = AppInfoService.compareVersions(
      _appVersion,
      _latestGithubVersion!,
    );

    if (comparison < 0) {
      return AppColors.warning;
    }
    if (comparison == 0) {
      return AppColors.connected;
    }
    return AppColors.accent;
  }

  Future<void> _openConnectionSettings() async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => const _ConnectionSettingsScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          return ColoredBox(
            color: AppColors.of(context).background,
            child: FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.035, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openPrivacyPolicy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PrivacyPolicyScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final isTablet = viewportWidth >= 700;
    final contentMaxWidth = isTablet ? 920.0 : 560.0;
    final menuItems = [
      _MenuItem(
        iconColor: AppColors.accent,
        icon: Icons.tune_rounded,
        label: 'Настройки соединения',
        onTap: _openConnectionSettings,
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        toolbarHeight: 70,
        titleSpacing: 4,
        title: Text(
          'Настройки',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  isTablet ? 24 : 16,
                  4,
                  isTablet ? 24 : 16,
                  72,
                ),
                children: [
                  if (isTablet && menuItems.length == 1)
                    menuItems.first
                  else if (isTablet)
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: menuItems
                          .map(
                            (item) => SizedBox(
                              width: (contentMaxWidth - 48 - 12) / 2,
                              child: item,
                            ),
                          )
                          .toList(),
                    )
                  else
                    ...menuItems.asMap().entries.expand((entry) {
                      final widgets = <Widget>[entry.value];
                      if (entry.key != menuItems.length - 1) {
                        widgets.add(const SizedBox(height: 10));
                      }
                      return widgets;
                    }),
                  SizedBox(height: isTablet ? 16 : 12),
                  _AboutAppBlock(
                    appVersion: _appVersion,
                    githubVersionStatus: _githubVersionStatus,
                    githubVersionStatusColor:
                        _githubVersionStatusColor(context),
                    showVersionTools: _isWindowsSelfUpdateSupported,
                    isCheckingGithubVersion: _isCheckingGithubVersion,
                    onCheckGithubVersionTap: _checkGithubVersion,
                    showWindowsUpdateAction:
                        _hasWindowsUpdateAvailable || _isInstallingUpdate,
                    isInstallingUpdate: _isInstallingUpdate,
                    windowsUpdateLabel: _windowsUpdateLabel,
                    updateDownloadProgress: _updateDownloadProgress,
                    onInstallUpdateTap: _isWindowsSelfUpdateSupported
                        ? _installWindowsUpdate
                        : null,
                    onPrivacyTap: _openPrivacyPolicy,
                    onSupportTap: () => launchUrl(
                      Uri.parse('https://t.me/VSupportV'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LiquidBottomBar(
              activeTab: LiquidBottomBarTab.settings,
              onConnectionTap: () => Navigator.of(context).maybePop(),
              onSettingsTap: () {},
            ),
          ),
        ],
      ),
    );
  }
}

enum _VersionNoticeType { success, warning, error, info }

class _MenuItem extends StatelessWidget {
  final Color iconColor;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MenuItem({
    required this.iconColor,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        borderRadius: BorderRadius.circular(20),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          iconColor.withValues(alpha: 0.15),
                          Colors.white.withValues(alpha: 0.03),
                        ]
                      : [
                          Colors.white.withValues(alpha: 0.76),
                          const Color(0xFFE4EBF4).withValues(alpha: 0.88),
                        ],
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark
                      ? Colors.transparent
                      : const Color(0xFFD7E0EA).withValues(alpha: 0.82),
                ),
              ),
              child: Icon(
                icon,
                color: isDark ? iconColor : const Color(0xFF67778F),
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textDisabled, size: 22),
          ],
        ),
      ),
    );
  }
}

class _AboutAppBlock extends StatelessWidget {
  final String appVersion;
  final String githubVersionStatus;
  final Color githubVersionStatusColor;
  final bool showVersionTools;
  final bool isCheckingGithubVersion;
  final VoidCallback onCheckGithubVersionTap;
  final bool showWindowsUpdateAction;
  final bool isInstallingUpdate;
  final String windowsUpdateLabel;
  final double? updateDownloadProgress;
  final VoidCallback? onInstallUpdateTap;
  final VoidCallback onPrivacyTap;
  final VoidCallback onSupportTap;

  const _AboutAppBlock({
    required this.appVersion,
    required this.githubVersionStatus,
    required this.githubVersionStatusColor,
    required this.showVersionTools,
    required this.isCheckingGithubVersion,
    required this.onCheckGithubVersionTap,
    required this.showWindowsUpdateAction,
    required this.isInstallingUpdate,
    required this.windowsUpdateLabel,
    required this.updateDownloadProgress,
    required this.onInstallUpdateTap,
    required this.onPrivacyTap,
    required this.onSupportTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const lightGlassBorder = Color(0xFFD7E0EA);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 340;

        return GlassCard(
          padding: const EdgeInsets.all(14),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        AppColors.accent.withValues(alpha: 0.14),
                        Colors.white.withValues(alpha: 0.02),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.8),
                        const Color(0xFFE8EEF6).withValues(alpha: 0.72),
                      ],
              ),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : lightGlassBorder.withValues(alpha: 0.78),
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFA000).withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.info_rounded,
                        color: Color(0xFFFFA000),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'О приложении',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (showVersionTools) ...[
                      _CompactGithubVersionButton(
                        isLoading: isCheckingGithubVersion,
                        onTap: onCheckGithubVersionTap,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _CompactPrivacyButton(onTap: onPrivacyTap),
                    const SizedBox(width: 8),
                    _CompactSupportButton(onTap: onSupportTap),
                  ],
                ),
                const SizedBox(height: 10),
                if (showVersionTools) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : const Color(0xFFF1F5FA).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : lightGlassBorder.withValues(alpha: 0.78),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.system_update_alt_rounded,
                          size: 16,
                          color: githubVersionStatusColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            githubVersionStatus,
                            style: TextStyle(
                              color: githubVersionStatusColor,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (showWindowsUpdateAction) ...[
                    _WindowsUpdateButton(
                      isLoading: isInstallingUpdate,
                      label: windowsUpdateLabel,
                      progress: updateDownloadProgress,
                      onTap: onInstallUpdateTap,
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _AboutTag(
                      icon: Icons.sell_rounded,
                      text: 'v$appVersion',
                    ),
                    const _AboutTag(
                      icon: Icons.shield_rounded,
                      text: 'VLESS · VMess · Trojan',
                    ),
                    const _AboutTag(
                      icon: Icons.memory_rounded,
                      text: 'Xray-core',
                    ),
                    if (!isCompact)
                      const _AboutTag(
                        icon: Icons.person_rounded,
                        text: 'Nurmaga095',
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AboutTag extends StatelessWidget {
  final IconData icon;
  final String text;

  const _AboutTag({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : const Color(0xFFF1F5FA).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFD7E0EA).withValues(alpha: 0.82),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isDark ? AppColors.accentGlow : const Color(0xFF627188),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactSupportButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CompactSupportButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Поддержка',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF25D366).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0xFF25D366).withValues(alpha: 0.24),
              ),
            ),
            child: const Icon(
              Icons.chat_bubble_rounded,
              color: Color(0xFF25D366),
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactPrivacyButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CompactPrivacyButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Политика конфиденциальности',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.24),
              ),
            ),
            child: const Icon(
              Icons.shield_outlined,
              color: AppColors.accent,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactGithubVersionButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onTap;

  const _CompactGithubVersionButton({
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final buttonColor = isDark ? AppColors.accent : const Color(0xFF6C7B92);

    return Tooltip(
      message: 'Проверить версию на GitHub',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: buttonColor.withValues(alpha: isDark ? 0.12 : 0.1),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: buttonColor.withValues(alpha: isDark ? 0.22 : 0.18),
              ),
            ),
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppColors.accent),
                      ),
                    )
                  : Icon(
                      Icons.system_update_alt_rounded,
                      color: buttonColor,
                      size: 18,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowsUpdateButton extends StatelessWidget {
  final bool isLoading;
  final String label;
  final double? progress;
  final VoidCallback? onTap;

  const _WindowsUpdateButton({
    required this.isLoading,
    required this.label,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = AppColors.warning;
    final progressValue = progress?.clamp(0.0, 1.0);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: accent.withValues(alpha: isDark ? 0.14 : 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accent.withValues(alpha: isDark ? 0.24 : 0.18),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (isLoading)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.9,
                          value: progressValue,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            accent,
                          ),
                        ),
                      )
                    else
                      const Icon(
                        Icons.download_rounded,
                        size: 17,
                        color: accent,
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 12.8,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                    ),
                    if (isLoading && progressValue != null)
                      Text(
                        '${(progressValue * 100).round()}%',
                        style: const TextStyle(
                          color: accent,
                          fontSize: 11.8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                if (isLoading && progressValue != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progressValue,
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(
                        alpha: isDark ? 0.08 : 0.4,
                      ),
                      valueColor: const AlwaysStoppedAnimation<Color>(accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionSettingsScreen extends StatefulWidget {
  const _ConnectionSettingsScreen();

  @override
  State<_ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<_ConnectionSettingsScreen> {
  late bool _bypassLan;
  late bool _ruRouting;
  late String _windowsVpnMode;
  late int _subscriptionAutoUpdateHours;
  final _subscriptionAutoUpdateController = TextEditingController();

  int _normalizeSubscriptionAutoUpdateHours(int? hours) {
    if (hours == null || hours <= 0) {
      return StorageService.defaultSubscriptionAutoUpdateHours;
    }
    return hours;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _subscriptionAutoUpdateController.dispose();
    super.dispose();
  }

  void _reload() {
    _bypassLan = StorageService.getBypassLan();
    _ruRouting = StorageService.getRuRouting();
    _windowsVpnMode = StorageService.getWindowsVpnMode();
    _subscriptionAutoUpdateHours =
        StorageService.getSubscriptionAutoUpdateHours();
    _subscriptionAutoUpdateController.text =
        _subscriptionAutoUpdateHours.toString();
  }

  String get _subscriptionAutoUpdateLabel => '$_subscriptionAutoUpdateHours ч';

  Future<void> _setSubscriptionAutoUpdateHours(int hours) async {
    final normalizedHours = _normalizeSubscriptionAutoUpdateHours(hours);
    await StorageService.setSubscriptionAutoUpdateHours(normalizedHours);
    if (!mounted) {
      return;
    }
    setState(() {
      _subscriptionAutoUpdateHours = normalizedHours;
      _subscriptionAutoUpdateController.text = normalizedHours.toString();
    });
  }

  Future<void> _saveSubscriptionAutoUpdateHours() async {
    final text = _subscriptionAutoUpdateController.text.trim();
    final hours = text.isEmpty
        ? StorageService.defaultSubscriptionAutoUpdateHours
        : int.tryParse(text);
    if (hours == null) {
      return;
    }
    final normalizedHours = _normalizeSubscriptionAutoUpdateHours(hours);
    if (normalizedHours == _subscriptionAutoUpdateHours) {
      _subscriptionAutoUpdateController.text = '$normalizedHours';
      return;
    }
    await _setSubscriptionAutoUpdateHours(normalizedHours);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final vpnProvider = context.read<VpnProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWindows =
        !kIsWeb && Theme.of(context).platform == TargetPlatform.windows;
    final isTablet = MediaQuery.sizeOf(context).width >= 700;
    final isDesktopSettings =
        isWindows && MediaQuery.sizeOf(context).width >= 960;
    final contentMaxWidth = isDesktopSettings
        ? 1140.0
        : isTablet
            ? 920.0
            : 560.0;
    final pageHorizontalPadding = isDesktopSettings
        ? 28.0
        : isTablet
            ? 24.0
            : 14.0;
    final cardPadding = EdgeInsets.all(isDesktopSettings
        ? 24
        : isTablet
            ? 22
            : 14);
    final controlHeight = isDesktopSettings
        ? 50.0
        : isTablet
            ? 52.0
            : 46.0;
    const desktopSideWidth = 390.0;
    final glassBorder = isDark
        ? Colors.white.withValues(alpha: 0.22)
        : const Color(0xFFD3DDE8).withValues(alpha: 0.82);
    final glassSurface = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : const Color(0xFFF4F7FB).withValues(alpha: 0.72);
    final glassSurfaceSoft = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : const Color(0xFFE8EEF6).withValues(alpha: 0.6);
    final glassLabel =
        isDark ? const Color(0xFFF4F7FB) : const Color(0xFF1F2937);
    final glassMutedLabel =
        isDark ? const Color(0xFFD6DCE6) : const Color(0xFF5E6A78);
    final accentSurface =
        AppColors.accent.withValues(alpha: isDark ? 0.16 : 0.1);
    final accentSurfaceSoft =
        AppColors.accent.withValues(alpha: isDark ? 0.1 : 0.06);
    final accentBorder =
        AppColors.accent.withValues(alpha: isDark ? 0.34 : 0.18);
    final warningSurface =
        AppColors.warning.withValues(alpha: isDark ? 0.14 : 0.08);

    Widget buildSectionHeader({
      required IconData icon,
      required String title,
      required String subtitle,
      required Color accent,
      Widget? trailing,
    }) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: isDark ? 0.34 : 0.18),
                  accent.withValues(alpha: isDark ? 0.14 : 0.08),
                ],
              ),
              border: Border.all(color: accent.withValues(alpha: 0.36)),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: glassMutedLabel,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      );
    }

    Widget buildInfoPill(
      String label,
      Color accent, {
      IconData? icon,
      bool compact = false,
    }) {
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 7 : 8,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: isDark ? 0.16 : 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: accent.withValues(alpha: 0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 14 : 15, color: accent),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: compact ? c.textPrimary : glassLabel,
                fontSize: compact ? 11.5 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    Widget buildDesktopStatTile({
      required IconData icon,
      required String label,
      required String value,
      required Color accent,
    }) {
      return Container(
        constraints: const BoxConstraints(minWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: isDark ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.26)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: isDark ? 0.2 : 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: accent, size: 18),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget buildPresetChips({
      double spacing = 6,
      double runSpacing = 6,
    }) {
      return Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        children: [6, 12, 24].map((hours) {
          final isSelected = _subscriptionAutoUpdateHours == hours;
          return SizedBox(
            height: 34,
            child: ActionChip(
              label: Text(
                '$hours ч',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? glassLabel : glassMutedLabel,
                ),
              ),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              backgroundColor: isSelected ? accentSurface : glassSurface,
              side: BorderSide(
                color: isSelected ? accentBorder : glassBorder,
                width: 0.8,
              ),
              onPressed: () => _setSubscriptionAutoUpdateHours(hours),
            ),
          );
        }).toList(),
      );
    }

    Widget buildAutoUpdateEditor({required bool desktopPanel}) {
      final inputSurface = isDark
          ? Colors.black.withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.72);
      final inputBorder = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : glassBorder.withValues(alpha: 0.9);
      final controlGroup = Container(
        width: double.infinity,
        height: controlHeight,
        decoration: BoxDecoration(
          color: accentSurfaceSoft,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accentBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: inputSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: inputBorder),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextField(
                        controller: _subscriptionAutoUpdateController,
                        maxLines: 1,
                        minLines: 1,
                        cursorHeight: 18,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        textAlignVertical: TextAlignVertical.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onSubmitted: (_) => _saveSubscriptionAutoUpdateHours(),
                        onTapOutside: (_) => _saveSubscriptionAutoUpdateHours(),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: false,
                          fillColor: Colors.transparent,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          hintText:
                              '${StorageService.defaultSubscriptionAutoUpdateHours}',
                          hintStyle: TextStyle(
                            color: c.textDisabled,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Center(
                child: Text(
                  'ч',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 1,
                height: 20,
                color: accentBorder,
              ),
            ),
            SizedBox(
              width: 44,
              height: controlHeight,
              child: Center(
                child: IconButton(
                  onPressed: _saveSubscriptionAutoUpdateHours,
                  splashRadius: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  icon: const Icon(Icons.check_rounded, size: 20),
                  color: c.textPrimary,
                ),
              ),
            ),
          ],
        ),
      );

      if (!desktopPanel) {
        return controlGroup;
      }

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: glassSurfaceSoft,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: glassBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Интервал',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Автообновление всегда включено. По умолчанию каждые 6 часов.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 11.8,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 12),
            controlGroup,
            const SizedBox(height: 8),
            Text(
              'Минимум 1 час. Пустое значение сбрасывается на 6 часов.',
              style: TextStyle(
                color: c.textDisabled,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      );
    }

    final autoUpdateCard = GlassCard(
      borderRadius: BorderRadius.circular(isDesktopSettings ? 28 : 24),
      padding: cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildSectionHeader(
            icon: Icons.autorenew_rounded,
            title: 'Автообновление',
            subtitle: 'Автообновление всегда включено, интервал в часах.',
            accent: AppColors.accent,
            trailing: buildInfoPill(
              _subscriptionAutoUpdateLabel,
              AppColors.accent,
              compact: true,
            ),
          ),
          SizedBox(height: isDesktopSettings ? 18 : 16),
          if (isDesktopSettings)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: accentSurfaceSoft,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: accentBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Подписки обновляются автоматически при запуске приложения и во время работы клиента.',
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 13,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                buildInfoPill(
                                  'Сейчас: $_subscriptionAutoUpdateLabel',
                                  AppColors.accent,
                                  icon: Icons.schedule_rounded,
                                  compact: true,
                                ),
                                buildInfoPill(
                                  'Ручное сохранение',
                                  AppColors.warning,
                                  icon: Icons.edit_rounded,
                                  compact: true,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Быстрые значения',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      buildPresetChips(spacing: 8, runSpacing: 8),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                SizedBox(
                  width: 268,
                  child: buildAutoUpdateEditor(desktopPanel: true),
                ),
              ],
            )
          else ...[
            buildAutoUpdateEditor(desktopPanel: false),
            const SizedBox(height: 12),
            buildPresetChips(),
            const SizedBox(height: 12),
            Text(
              'Автообновление всегда включено. По умолчанию интервал 6 часов. Проверка идёт при запуске и пока приложение открыто.',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );

    final behaviorCard = GlassCard(
      borderRadius: BorderRadius.circular(isDesktopSettings ? 28 : 24),
      padding: cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildSectionHeader(
            icon: Icons.route_rounded,
            title: 'Поведение VPN',
            subtitle: 'Маршруты и запуск подключения.',
            accent: AppColors.connected,
          ),
          SizedBox(height: isDesktopSettings ? 16 : 12),
          if (isDesktopSettings) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                buildInfoPill(
                  _bypassLan ? 'LAN: напрямую' : 'LAN: через VPN',
                  AppColors.accent,
                  icon: Icons.router_rounded,
                  compact: true,
                ),
                buildInfoPill(
                  _ruRouting ? 'RU: напрямую' : 'RU: через VPN',
                  AppColors.connected,
                  icon: Icons.public_rounded,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          _SheetSwitch(
            icon: Icons.router_rounded,
            accentColor: AppColors.accent,
            title: 'Локальная сеть',
            subtitle: 'LAN идёт напрямую',
            value: _bypassLan,
            onChanged: (v) async {
              await StorageService.setBypassLan(v);
              setState(() => _bypassLan = v);
            },
          ),
          const SizedBox(height: 8),
          _SheetSwitch(
            icon: Icons.public_rounded,
            accentColor: AppColors.connected,
            title: 'RU напрямую',
            subtitle: 'Российские сайты без VPN',
            value: _ruRouting,
            onChanged: (v) async {
              await StorageService.setRuRouting(v);
              setState(() => _ruRouting = v);
              await vpnProvider.syncQuickSettingsConfig();
              if (vpnProvider.isConnected) {
                await vpnProvider.reconnect();
              }
            },
          ),
        ],
      ),
    );

    final windowsCard = isWindows
        ? GlassCard(
            borderRadius: BorderRadius.circular(isDesktopSettings ? 28 : 24),
            padding: cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildSectionHeader(
                  icon: Icons.desktop_windows_rounded,
                  title: 'Режим Windows',
                  subtitle:
                      'Выберите совместимый режим подключения для системы.',
                  accent: AppColors.warning,
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment<String>(
                      value: 'system_proxy',
                      label: Text('Системный прокси'),
                    ),
                    ButtonSegment<String>(
                      value: 'tunnel',
                      label: Text('Туннель'),
                    ),
                  ],
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? warningSurface
                          : glassSurfaceSoft;
                    }),
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? glassLabel
                          : glassMutedLabel;
                    }),
                    side: WidgetStateProperty.resolveWith((states) {
                      return BorderSide(
                        color: states.contains(WidgetState.selected)
                            ? AppColors.warning.withValues(alpha: 0.34)
                            : glassBorder,
                      );
                    }),
                    textStyle: WidgetStateProperty.all(
                      const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    padding: WidgetStateProperty.all(
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  selected: {_windowsVpnMode},
                  onSelectionChanged: (selection) async {
                    final next = selection.first;
                    await StorageService.setWindowsVpnMode(next);
                    setState(() => _windowsVpnMode = next);
                  },
                ),
                if (isDesktopSettings) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      buildInfoPill(
                        _windowsVpnMode == 'tunnel'
                            ? 'Нужны права администратора'
                            : 'Совместимый режим',
                        AppColors.warning,
                        icon: Icons.info_outline_rounded,
                        compact: true,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  _windowsVpnMode == 'tunnel'
                      ? 'Туннель: полный перехват трафика, нужны права администратора.'
                      : 'Системный прокси: стабильнее, но перехватывает не весь трафик приложений.',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          )
        : null;

    final desktopHeaderCard = isDesktopSettings
        ? GlassCard(
            borderRadius: BorderRadius.circular(28),
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Настройки соединения',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Управление обновлением подписок, маршрутизацией и режимом работы Windows.',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Flexible(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.end,
                    children: [
                      buildDesktopStatTile(
                        icon: Icons.update_rounded,
                        label: 'Автообновление',
                        value: _subscriptionAutoUpdateLabel,
                        accent: AppColors.accent,
                      ),
                      buildDesktopStatTile(
                        icon: Icons.public_rounded,
                        label: 'RU-маршрут',
                        value: _ruRouting ? 'Напрямую' : 'Через VPN',
                        accent: AppColors.connected,
                      ),
                      buildDesktopStatTile(
                        icon: Icons.desktop_windows_rounded,
                        label: 'Режим',
                        value: _windowsVpnMode == 'tunnel'
                            ? 'Туннель'
                            : 'Системный прокси',
                        accent: AppColors.warning,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        : null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        toolbarHeight: 70,
        titleSpacing: 4,
        title: Text(
          'Настройки соединения',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  pageHorizontalPadding,
                  4,
                  pageHorizontalPadding,
                  72,
                ),
                children: [
                  if (isDesktopSettings) ...[
                    desktopHeaderCard!,
                    const SizedBox(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: desktopSideWidth,
                          child: Column(
                            children: [
                              autoUpdateCard,
                              if (windowsCard != null) ...[
                                const SizedBox(height: 18),
                                windowsCard,
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(child: behaviorCard),
                      ],
                    ),
                  ] else if (isTablet)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              autoUpdateCard,
                              if (windowsCard != null) ...[
                                const SizedBox(height: 16),
                                windowsCard,
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(child: behaviorCard),
                      ],
                    )
                  else ...[
                    autoUpdateCard,
                    if (windowsCard != null) ...[
                      const SizedBox(height: 16),
                      windowsCard,
                    ],
                    const SizedBox(height: 16),
                    behaviorCard,
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LiquidBottomBar(
              activeTab: LiquidBottomBarTab.settings,
              onConnectionTap: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              onSettingsTap: () {},
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSwitch extends StatelessWidget {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final bool value;
  final void Function(bool) onChanged;

  const _SheetSwitch({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark
        ? Colors.white.withValues(alpha: value ? 0.05 : 0.028)
        : value
            ? const Color(0xFFF1F7F6)
            : const Color(0xFFF3F6FB);
    final borderColor = value
        ? accentColor.withValues(alpha: isDark ? 0.22 : 0.16)
        : isDark
            ? Colors.white.withValues(alpha: 0.1)
            : const Color(0xFFD6DFEA);
    final iconSurface = value
        ? accentColor.withValues(alpha: isDark ? 0.18 : 0.1)
        : isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFE7EEF7);
    final trackColor = value
        ? accentColor.withValues(alpha: isDark ? 0.38 : 0.24)
        : isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFEFF3F8);
    final thumbColor = isDark
        ? Colors.white.withValues(alpha: value ? 0.96 : 0.82)
        : Colors.white.withValues(alpha: value ? 0.98 : 0.95);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: iconSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Icon(
              icon,
              color: value ? accentColor : c.textSecondary,
              size: 17,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 11.2,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Transform.scale(
            scale: 0.78,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: thumbColor,
              inactiveThumbColor: thumbColor,
              activeTrackColor: trackColor,
              inactiveTrackColor: trackColor,
            ),
          ),
        ],
      ),
    );
  }
}
