import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/app_info_service.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/vpn_provider.dart';
import '../../ui/perf.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/theme_controller.dart';
import '../../ui/widgets/app_card.dart';
import '../../ui/widgets/app_nav_bar.dart';
import '../privacy/privacy_screens.dart';

const _supportUrl = 'https://t.me/VSupportV';

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

    final (icon, tint) = switch (type) {
      _VersionNoticeType.success => (Icons.check_circle_rounded, c.connectedText),
      _VersionNoticeType.warning => (Icons.system_update_alt_rounded, c.warningText),
      _VersionNoticeType.error => (Icons.error_outline_rounded, c.errorText),
      _VersionNoticeType.info => (Icons.info_outline_rounded, c.infoText),
    };

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.surface,
        elevation: 0,
        margin: const EdgeInsets.all(AppSpacing.md),
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
          side: BorderSide(color: c.border),
        ),
        content: Row(
          children: [
            Icon(icon, color: tint, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(color: c.textPrimary, fontSize: 14),
              ),
            ),
          ],
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
    final c = AppColors.of(context);
    if (_isCheckingGithubVersion) {
      return c.textSecondary;
    }
    if (_githubVersionCheckFailed) {
      return c.errorText;
    }
    if (_latestGithubVersion == null) {
      return c.textSecondary;
    }

    final comparison = AppInfoService.compareVersions(
      _appVersion,
      _latestGithubVersion!,
    );

    if (comparison < 0) {
      return c.warningText;
    }
    if (comparison == 0) {
      return c.connectedText;
    }
    return c.accentText;
  }

  Future<void> _openConnectionSettings() =>
      Navigator.of(context).push(pushFade(const _ConnectionSettingsScreen()));

  Future<void> _openPrivacyPolicy() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PrivacyPolicyScreen(),
      ),
    );
  }

  Future<void> _openSupport() =>
      launchUrl(Uri.parse(_supportUrl), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).width >= 700;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        titleSpacing: AppSpacing.page,
        title: const Text('Настройки', style: AppText.title),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isTablet ? 760 : 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.sm,
              AppSpacing.page,
              AppSpacing.xxl,
            ),
            children: [
              _AppSummaryCard(version: _appVersion),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionLabel(text: 'Оформление'),
              const _AppearanceCard(),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionLabel(text: 'Приложение'),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    SettingsNavRow(
                      icon: Icons.tune_rounded,
                      accent: AppColors.accent,
                      title: 'Настройки соединения',
                      subtitle: 'Маршруты, ping, автообновление подписок',
                      onTap: _openConnectionSettings,
                    ),
                    const SettingsDivider(),
                    SettingsNavRow(
                      icon: Icons.privacy_tip_outlined,
                      accent: AppColors.connected,
                      title: 'Приватность',
                      subtitle: 'Политика и раскрытие VPN-доступа',
                      onTap: _openPrivacyPolicy,
                    ),
                    const SettingsDivider(),
                    SettingsNavRow(
                      icon: Icons.support_agent_rounded,
                      accent: AppColors.info,
                      title: 'Поддержка',
                      subtitle: 'Написать в Telegram',
                      trailingIcon: Icons.open_in_new_rounded,
                      onTap: _openSupport,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionLabel(text: 'Протоколы'),
              const _ProtocolCard(),
              if (_isWindowsSelfUpdateSupported) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionLabel(text: 'Обновления'),
                _UpdatesCard(
                  status: _githubVersionStatus,
                  statusColor: _githubVersionStatusColor(context),
                  isChecking: _isCheckingGithubVersion,
                  showInstallAction:
                      _hasWindowsUpdateAvailable || _isInstallingUpdate,
                  isInstalling: _isInstallingUpdate,
                  installLabel: _windowsUpdateLabel,
                  downloadProgress: _updateDownloadProgress,
                  onCheckTap: _checkGithubVersion,
                  onInstallTap: _installWindowsUpdate,
                ),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: AppNavBar(
        activeTab: AppNavTab.settings,
        onConnectionTap: () => Navigator.of(context).maybePop(),
        onSettingsTap: () {},
      ),
    );
  }
}

enum _VersionNoticeType { success, warning, error, info }

/// Shared page transition for settings sub-screens.
PageRouteBuilder<void> pushFade(Widget page) {
  return PageRouteBuilder<void>(
    transitionDuration: AppMotion.normal,
    reverseTransitionDuration: AppMotion.fast,
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.curve,
        reverseCurve: Curves.easeInCubic,
      );

      return ColoredBox(
        color: AppColors.of(context).background,
        child: FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.04, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

// ─── Settings building blocks ────────────────────────────────────────────────

/// A tappable row that opens another screen or an external link.
class SettingsNavRow extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final IconData trailingIcon;
  final VoidCallback onTap;

  const SettingsNavRow({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailingIcon = Icons.chevron_right_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              AppIconPlate(icon: icon, color: accent),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppText.body.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppText.caption.copyWith(
                        color: c.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(trailingIcon, size: 20, color: c.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row with a trailing switch.
class SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            AppIconPlate(icon: icon, color: accent),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(
                      color: c.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
        height: 1,
        indent: 68,
        color: AppColors.of(context).border,
      );
}

/// Card header: icon, title and one line of explanation.
class SettingsCardHeader extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const SettingsCardHeader({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIconPlate(icon: icon, color: accent, size: 36),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.heading.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: AppText.caption.copyWith(
                  color: c.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

// ─── Settings cards ──────────────────────────────────────────────────────────

class _AppSummaryCard extends StatelessWidget {
  final String version;

  const _AppSummaryCard({required this.version});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      child: Row(
        children: [
          AppIconPlate(
            icon: Icons.shield_rounded,
            color: c.accentText,
            size: 48,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ChrNet VPN',
                  style: AppText.heading.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  'Версия $version · Xray-core',
                  style: AppText.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AppearanceCard extends StatefulWidget {
  const _AppearanceCard();

  @override
  State<_AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<_AppearanceCard> {
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final mode = AppThemeController.instance.mode;

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Тема',
                  style: AppText.body.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_rounded, size: 18),
                      label: Text('Авто'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_rounded, size: 18),
                      label: Text('Светлая'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_rounded, size: 18),
                      label: Text('Тёмная'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (selection) async {
                    await AppThemeController.instance.setMode(selection.first);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SettingsDivider(),
          SettingsSwitchRow(
            icon: Icons.animation_rounded,
            accent: AppColors.info,
            title: 'Меньше анимаций',
            subtitle: 'Отключает фоновые эффекты и экономит батарею',
            value: AppPerf.instance.reducedMotion,
            onChanged: (v) async {
              await AppPerf.instance.setOverride(v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _ProtocolCard extends StatelessWidget {
  const _ProtocolCard();

  static const _protocols = [
    'VLESS',
    'JSON-конфиги',
    'TLS',
    'Reality',
    'xhttp',
    'WebSocket',
    'gRPC',
    'TCP',
    'mKCP',
    'HTTPUpgrade',
  ];

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Что можно импортировать',
            style: AppText.body.copyWith(
              color: c.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final protocol in _protocols)
                AppPill(
                  icon: Icons.check_rounded,
                  label: protocol,
                  color: c.textSecondary,
                  background: c.surfaceMuted,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UpdatesCard extends StatelessWidget {
  final String status;
  final Color statusColor;
  final bool isChecking;
  final bool showInstallAction;
  final bool isInstalling;
  final String installLabel;
  final double? downloadProgress;
  final VoidCallback onCheckTap;
  final VoidCallback onInstallTap;

  const _UpdatesCard({
    required this.status,
    required this.statusColor,
    required this.isChecking,
    required this.showInstallAction,
    required this.isInstalling,
    required this.installLabel,
    required this.downloadProgress,
    required this.onCheckTap,
    required this.onInstallTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  status,
                  style: AppText.body.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Проверить версию',
                isBusy: isChecking,
                onTap: onCheckTap,
              ),
            ],
          ),
          if (showInstallAction) ...[
            const SizedBox(height: AppSpacing.md),
            if (isInstalling && downloadProgress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: downloadProgress,
                  minHeight: 5,
                  backgroundColor: c.surfaceMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            FilledButton.icon(
              onPressed: isInstalling ? null : onInstallTap,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(installLabel),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Connection settings ─────────────────────────────────────────────────────

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
  late String _pingMethod;
  late int _subscriptionAutoUpdateHours;
  final _subscriptionAutoUpdateController = TextEditingController();
  final _pingTestUrlController = TextEditingController();
  OverlayEntry? _topNoticeEntry;
  Timer? _topNoticeTimer;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _topNoticeTimer?.cancel();
    _topNoticeEntry?.remove();
    _topNoticeEntry = null;
    _subscriptionAutoUpdateController.dispose();
    _pingTestUrlController.dispose();
    super.dispose();
  }

  void _reload() {
    _bypassLan = StorageService.getBypassLan();
    _ruRouting = StorageService.getRuRouting();
    _windowsVpnMode = StorageService.getWindowsVpnMode();
    _pingMethod = StorageService.getPingMethod();
    _subscriptionAutoUpdateHours =
        StorageService.getSubscriptionAutoUpdateHours();
    _subscriptionAutoUpdateController.text =
        _subscriptionAutoUpdateHours.toString();
    _pingTestUrlController.text = StorageService.getPingTestUrl();
  }

  int _normalizeSubscriptionAutoUpdateHours(int? hours) {
    if (hours == null || hours <= 0) {
      return StorageService.defaultSubscriptionAutoUpdateHours;
    }
    if (hours > StorageService.maxSubscriptionAutoUpdateHours) {
      return StorageService.maxSubscriptionAutoUpdateHours;
    }
    return hours;
  }

  void _showNotice(
    String message, {
    IconData icon = Icons.check_circle_outline_rounded,
    _VersionNoticeType type = _VersionNoticeType.success,
  }) {
    if (!mounted) {
      return;
    }

    _topNoticeTimer?.cancel();
    _topNoticeEntry?.remove();
    _topNoticeEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<_TopNoticeHostState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final c = AppColors.of(ctx);
        final safeTop = MediaQuery.of(ctx).padding.top + AppSpacing.sm;
        final tint = switch (type) {
          _VersionNoticeType.success => c.connectedText,
          _VersionNoticeType.warning => c.warningText,
          _VersionNoticeType.error => c.errorText,
          _VersionNoticeType.info => c.infoText,
        };

        return Positioned(
          top: safeTop,
          left: AppSpacing.page,
          right: AppSpacing.page,
          child: _TopNoticeHost(
            key: key,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: AppRadius.mdAll,
                    border: Border.all(color: c.border),
                    boxShadow: c.floatingShadow,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: tint, size: 18),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          message,
                          style: AppText.body.copyWith(
                            color: c.textPrimary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    _topNoticeEntry = entry;
    _topNoticeTimer = Timer(const Duration(seconds: 2), () async {
      if (_topNoticeEntry != entry) {
        return;
      }
      await key.currentState?.dismiss();
      if (_topNoticeEntry == entry) {
        entry.remove();
        _topNoticeEntry = null;
      }
    });
  }

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
    final parsedHours = text.isEmpty
        ? StorageService.defaultSubscriptionAutoUpdateHours
        : int.tryParse(text);
    if (parsedHours == null) {
      return;
    }
    final normalizedHours = _normalizeSubscriptionAutoUpdateHours(parsedHours);
    if (normalizedHours == _subscriptionAutoUpdateHours) {
      _subscriptionAutoUpdateController.text = '$normalizedHours';
      _showNotice('Интервал уже сохранён: $normalizedHours ч.');
      return;
    }
    await _setSubscriptionAutoUpdateHours(normalizedHours);
    if (!mounted) {
      return;
    }
    if (text.isEmpty || parsedHours <= 0) {
      _showNotice(
        'Сохранено: ${StorageService.defaultSubscriptionAutoUpdateHours} ч '
        'по умолчанию.',
        type: _VersionNoticeType.warning,
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    if (parsedHours > StorageService.maxSubscriptionAutoUpdateHours) {
      _showNotice(
        'Максимум 24 ч. Сохранено: '
        '${StorageService.maxSubscriptionAutoUpdateHours} ч.',
        type: _VersionNoticeType.warning,
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    _showNotice('Интервал сохранён: $normalizedHours ч.');
  }

  Future<void> _savePingTestUrl() async {
    final text = _pingTestUrlController.text.trim();
    final nextUrl = text.isEmpty ? StorageService.defaultPingTestUrl : text;
    final uri = Uri.tryParse(nextUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _showNotice(
        'Укажите HTTP/HTTPS URL для проверки.',
        type: _VersionNoticeType.error,
        icon: Icons.error_outline_rounded,
      );
      return;
    }

    await StorageService.setPingTestUrl(nextUrl);
    if (!mounted) {
      return;
    }
    setState(() {
      _pingTestUrlController.text = nextUrl;
    });
    _showNotice('URL проверки ping сохранён.');
  }

  String get _pingMethodHint {
    if (_pingMethod == StorageService.pingMethodProxyGet ||
        _pingMethod == StorageService.pingMethodProxyHead) {
      return 'GET/HEAD сначала пробует TCP до порта сервера, а если не вышло — '
          'гонит запрос через временный Xray.';
    }
    if (_pingMethod == StorageService.pingMethodIcmp) {
      return 'ICMP использует системный ping до адреса сервера. Если ICMP '
          'закрыт, проверка падает обратно на TCP.';
    }
    return 'TCP проверяет подключение к порту сервера. Самый быстрый и точный '
        'способ для VLESS.';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final vpnProvider = context.read<VpnProvider>();
    final isWindows =
        !kIsWeb && Theme.of(context).platform == TargetPlatform.windows;
    final isTablet = MediaQuery.sizeOf(context).width >= 700;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        titleSpacing: 0,
        title: const Text('Соединение', style: AppText.title),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isTablet ? 760 : 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.sm,
              AppSpacing.page,
              AppSpacing.xxl,
            ),
            children: [
              // ── Маршрутизация ───────────────────────────────────────────
              const AppSectionLabel(text: 'Маршрутизация'),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    SettingsSwitchRow(
                      icon: Icons.router_rounded,
                      accent: AppColors.accent,
                      title: 'Локальная сеть',
                      subtitle: 'LAN идёт напрямую, минуя туннель',
                      value: _bypassLan,
                      onChanged: (v) async {
                        await StorageService.setBypassLan(v);
                        setState(() => _bypassLan = v);
                      },
                    ),
                    const SettingsDivider(),
                    SettingsSwitchRow(
                      icon: Icons.public_rounded,
                      accent: AppColors.connected,
                      title: 'RU напрямую',
                      subtitle: 'Российские сайты идут без VPN',
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
              ),

              // ── Проверка ping ───────────────────────────────────────────
              const SizedBox(height: AppSpacing.xl),
              const AppSectionLabel(text: 'Проверка ping'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SettingsCardHeader(
                      icon: Icons.speed_rounded,
                      accent: AppColors.accent,
                      title: 'Метод проверки',
                      subtitle: 'Как измеряется задержка в списке серверов',
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SizedBox(
                      width: double.infinity,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: StorageService.pingMethodProxyGet,
                              label: Text('GET'),
                            ),
                            ButtonSegment(
                              value: StorageService.pingMethodProxyHead,
                              label: Text('HEAD'),
                            ),
                            ButtonSegment(
                              value: StorageService.pingMethodTcp,
                              label: Text('TCP'),
                            ),
                            ButtonSegment(
                              value: StorageService.pingMethodIcmp,
                              label: Text('ICMP'),
                            ),
                          ],
                          selected: {_pingMethod},
                          onSelectionChanged: (selection) async {
                            final next = selection.first;
                            await StorageService.setPingMethod(next);
                            setState(() => _pingMethod = next);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _pingTestUrlController,
                      maxLines: 1,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      style: AppText.body.copyWith(color: c.textPrimary),
                      onSubmitted: (_) => _savePingTestUrl(),
                      onTapOutside: (_) => _savePingTestUrl(),
                      decoration: InputDecoration(
                        labelText: 'Тестовый URL (через прокси)',
                        hintText: StorageService.defaultPingTestUrl,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.check_rounded, size: 20),
                          onPressed: _savePingTestUrl,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      _pingMethodHint,
                      style: AppText.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),

              // ── Автообновление ──────────────────────────────────────────
              const SizedBox(height: AppSpacing.xl),
              const AppSectionLabel(text: 'Подписки'),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsCardHeader(
                      icon: Icons.autorenew_rounded,
                      accent: AppColors.connected,
                      title: 'Автообновление',
                      subtitle: 'Проверка при запуске и во время работы',
                      trailing: AppPill(
                        label: '$_subscriptionAutoUpdateHours ч',
                        color: c.accentText,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        for (final hours in const [6, 12, 24]) ...[
                          Expanded(
                            child: _PresetChip(
                              label: '$hours ч',
                              isSelected: _subscriptionAutoUpdateHours == hours,
                              onTap: () =>
                                  _setSubscriptionAutoUpdateHours(hours),
                            ),
                          ),
                          if (hours != 24) const SizedBox(width: AppSpacing.sm),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _subscriptionAutoUpdateController,
                      maxLines: 1,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      style: AppText.body.copyWith(color: c.textPrimary),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(2),
                      ],
                      onSubmitted: (_) => _saveSubscriptionAutoUpdateHours(),
                      onTapOutside: (_) => _saveSubscriptionAutoUpdateHours(),
                      decoration: InputDecoration(
                        labelText: 'Свой интервал, часов',
                        hintText:
                            '${StorageService.defaultSubscriptionAutoUpdateHours}',
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.check_rounded, size: 20),
                          onPressed: _saveSubscriptionAutoUpdateHours,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Допустимо от 1 до 24 часов. Пустое значение или 0 '
                      'сбрасываются на '
                      '${StorageService.defaultSubscriptionAutoUpdateHours} ч.',
                      style: AppText.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),

              // ── Windows ─────────────────────────────────────────────────
              if (isWindows) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionLabel(text: 'Windows'),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SettingsCardHeader(
                        icon: Icons.desktop_windows_rounded,
                        accent: AppColors.warning,
                        title: 'Режим подключения',
                        subtitle: 'Как перехватывается системный трафик',
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 'system_proxy',
                            label: Text('Системный прокси'),
                          ),
                          ButtonSegment(
                            value: 'tunnel',
                            label: Text('Туннель'),
                          ),
                        ],
                        selected: {_windowsVpnMode},
                        onSelectionChanged: (selection) async {
                          final next = selection.first;
                          await StorageService.setWindowsVpnMode(next);
                          setState(() => _windowsVpnMode = next);
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _windowsVpnMode == 'tunnel'
                            ? 'Туннель: полный перехват трафика, нужны права '
                                'администратора.'
                            : 'Системный прокси: стабильнее, но перехватывает '
                                'не весь трафик приложений.',
                        style: AppText.caption.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: AppNavBar(
        activeTab: AppNavTab.settings,
        onConnectionTap: () =>
            Navigator.of(context).popUntil((route) => route.isFirst),
        onSettingsTap: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: isSelected ? c.accentSoft : c.surfaceMuted,
      borderRadius: AppRadius.mdAll,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdAll,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdAll,
            border: Border.all(
              color: isSelected ? c.accentText : c.border,
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Text(
            label,
            style: AppText.body.copyWith(
              color: isSelected ? c.accentText : c.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Top notice animated host ────────────────────────────────────────────────

class _TopNoticeHost extends StatefulWidget {
  final Widget child;
  const _TopNoticeHost({super.key, required this.child});

  @override
  State<_TopNoticeHost> createState() => _TopNoticeHostState();
}

class _TopNoticeHostState extends State<_TopNoticeHost>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppMotion.normal);
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.8),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: AppMotion.curve));
    _ctrl.forward();
  }

  Future<void> dismiss() async {
    if (_ctrl.isDismissed) return;
    await _ctrl.reverse();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
