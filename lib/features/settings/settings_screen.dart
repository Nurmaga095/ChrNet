import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/services/app_info_service.dart';
import '../../core/services/storage_service.dart';
import '../../core/services/theme_provider.dart';
import '../../core/services/vpn_provider.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/glass_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _autoStart;
  late bool _bypassLan;
  late bool _ruRouting;
  late String _windowsVpnMode;
  late int _subscriptionAutoUpdateHours;
  final _subscriptionAutoUpdateController = TextEditingController();
  String _appVersion = '...';

  @override
  void initState() {
    super.initState();
    _autoStart = StorageService.getAutoStart();
    _bypassLan = StorageService.getBypassLan();
    _ruRouting = StorageService.getRuRouting();
    _windowsVpnMode = StorageService.getWindowsVpnMode();
    _subscriptionAutoUpdateHours =
        StorageService.getSubscriptionAutoUpdateHours();
    _subscriptionAutoUpdateController.text = _subscriptionAutoUpdateHours > 0
        ? _subscriptionAutoUpdateHours.toString()
        : '';
    _loadAppVersion();
  }

  @override
  void dispose() {
    _subscriptionAutoUpdateController.dispose();
    super.dispose();
  }

  Future<void> _loadAppVersion() async {
    final version = await AppInfoService.getVersion();
    if (!mounted) {
      return;
    }
    setState(() => _appVersion = version);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final isTablet = viewportWidth >= 700;
    final contentMaxWidth = isTablet ? 920.0 : 560.0;
    final menuItems = [
      _MenuItem(
        iconColor: const Color(0xFF25D366),
        icon: Icons.chat_bubble_rounded,
        label: 'Связаться с поддержкой',
        onTap: () => launchUrl(
          Uri.parse('https://t.me/VSupportV'),
          mode: LaunchMode.externalApplication,
        ),
      ),
      _MenuItem(
        iconColor: const Color(0xFF2979FF),
        icon: Icons.tune_rounded,
        label: 'Настройки соединения',
        onTap: () => _showSettingsSheet(context),
      ),
      _MenuItem(
        iconColor: const Color(0xFFFFA000),
        icon: Icons.info_rounded,
        label: 'О приложении',
        onTap: () => _showAbout(context),
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
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: contentMaxWidth),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              isTablet ? 24 : 16,
              4,
              isTablet ? 24 : 16,
              24,
            ),
            children: [
              const _ThemeSwitcher(),
              SizedBox(height: isTablet ? 14 : 10),
              if (isTablet)
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
            ],
          ),
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('О приложении', style: TextStyle(color: c.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ChrNet VPN  v$_appVersion',
                style: TextStyle(color: c.textSecondary)),
            const SizedBox(height: 8),
            Text('Протоколы: VLESS · VMess · Trojan',
                style: TextStyle(color: c.textDisabled, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Ядро: Xray-core',
                style: TextStyle(color: c.textDisabled, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Разработчик: Nurmaga095',
                style: TextStyle(color: c.textDisabled, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  void _showSettingsSheet(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isTablet = MediaQuery.sizeOf(context).width >= 700;
    if (isTablet) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Material(
                color: isDark
                    ? const Color(0xFF0E1020).withValues(alpha: 0.96)
                    : Colors.white.withValues(alpha: 0.97),
                child: _SettingsSheet(
                  autoStart: _autoStart,
                  bypassLan: _bypassLan,
                  ruRouting: _ruRouting,
                  windowsVpnMode: _windowsVpnMode,
                  subscriptionAutoUpdateHours: _subscriptionAutoUpdateHours,
                  subscriptionAutoUpdateController:
                      _subscriptionAutoUpdateController,
                  showCloseButton: true,
                  onChanged: () => setState(() {
                    _autoStart = StorageService.getAutoStart();
                    _bypassLan = StorageService.getBypassLan();
                    _ruRouting = StorageService.getRuRouting();
                    _windowsVpnMode = StorageService.getWindowsVpnMode();
                    _subscriptionAutoUpdateHours =
                        StorageService.getSubscriptionAutoUpdateHours();
                    _subscriptionAutoUpdateController.text =
                        _subscriptionAutoUpdateHours > 0
                            ? _subscriptionAutoUpdateHours.toString()
                            : '';
                  }),
                ),
              ),
            ),
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark
          ? const Color(0xFF0E1020).withValues(alpha: 0.92)
          : Colors.white.withValues(alpha: 0.92),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      isScrollControlled: true,
      builder: (ctx) => _SettingsSheet(
        autoStart: _autoStart,
        bypassLan: _bypassLan,
        ruRouting: _ruRouting,
        windowsVpnMode: _windowsVpnMode,
        subscriptionAutoUpdateHours: _subscriptionAutoUpdateHours,
        subscriptionAutoUpdateController: _subscriptionAutoUpdateController,
        showCloseButton: false,
        onChanged: () => setState(() {
          _autoStart = StorageService.getAutoStart();
          _bypassLan = StorageService.getBypassLan();
          _ruRouting = StorageService.getRuRouting();
          _windowsVpnMode = StorageService.getWindowsVpnMode();
          _subscriptionAutoUpdateHours =
              StorageService.getSubscriptionAutoUpdateHours();
          _subscriptionAutoUpdateController.text =
              _subscriptionAutoUpdateHours > 0
                  ? _subscriptionAutoUpdateHours.toString()
                  : '';
        }),
      ),
    );
  }
}

// ─── Переключатель темы ────────────────────────────────────────────────────────

class _ThemeSwitcher extends StatelessWidget {
  const _ThemeSwitcher();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final provider = context.watch<ThemeProvider>();
    final current = provider.themeMode;

    final options = [
      (ThemeMode.system, Icons.brightness_auto_rounded, 'Система'),
      (ThemeMode.light, Icons.light_mode_rounded, 'Светлая'),
      (ThemeMode.dark, Icons.dark_mode_rounded, 'Тёмная'),
    ];

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.palette_rounded,
                    color: AppColors.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Text(
                'Тема оформления',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: options.map((opt) {
              final (mode, icon, label) = opt;
              final isActive = current == mode;
              return Expanded(
                child: GestureDetector(
                  onTap: () => provider.setThemeMode(mode),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.accent : c.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isActive ? AppColors.accent : c.borderColor,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          icon,
                          size: 20,
                          color: isActive ? Colors.white : c.textSecondary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isActive ? Colors.white : c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─── Пункт меню ──────────────────────────────────────────────────────────────

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
                color: iconColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 22),
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

// ─── Bottom sheet настроек ────────────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  final bool autoStart;
  final bool bypassLan;
  final bool ruRouting;
  final String windowsVpnMode;
  final int subscriptionAutoUpdateHours;
  final TextEditingController subscriptionAutoUpdateController;
  final bool showCloseButton;
  final VoidCallback onChanged;

  const _SettingsSheet({
    required this.autoStart,
    required this.bypassLan,
    required this.ruRouting,
    required this.windowsVpnMode,
    required this.subscriptionAutoUpdateHours,
    required this.subscriptionAutoUpdateController,
    required this.showCloseButton,
    required this.onChanged,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _autoStart;
  late bool _bypassLan;
  late bool _ruRouting;
  late String _windowsVpnMode;
  late int _subscriptionAutoUpdateHours;

  @override
  void initState() {
    super.initState();
    _autoStart = widget.autoStart;
    _bypassLan = widget.bypassLan;
    _ruRouting = widget.ruRouting;
    _windowsVpnMode = widget.windowsVpnMode;
    _subscriptionAutoUpdateHours = widget.subscriptionAutoUpdateHours;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isTablet = MediaQuery.sizeOf(context).width >= 700;
    final primarySection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DNS', style: TextStyle(color: c.textSecondary, fontSize: 13)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.cardBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.borderColor),
          ),
          child: Text(
            'Берётся из подписки. Если DNS в подписке не указан, приложение использует встроенный fallback.',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Автообновление подписок',
            style: TextStyle(color: c.textSecondary, fontSize: 13)),
        const SizedBox(height: 8),
        TextField(
          controller: widget.subscriptionAutoUpdateController,
          style: TextStyle(color: c.textPrimary),
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: InputDecoration(
            hintText: '0',
            helperText: '0 - выключено, значение задаётся в часах',
            suffixIcon: TextButton(
              onPressed: () async {
                final text =
                    widget.subscriptionAutoUpdateController.text.trim();
                final hours = text.isEmpty ? 0 : int.tryParse(text);
                if (hours == null) return;

                await StorageService.setSubscriptionAutoUpdateHours(hours);
                setState(() => _subscriptionAutoUpdateHours = hours);
                widget.onChanged();
              },
              child: const Text(
                'Сохранить',
                style: TextStyle(color: AppColors.accent),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [0, 6, 12, 24].map((hours) {
            final isSelected = _subscriptionAutoUpdateHours == hours;
            return ActionChip(
              label: Text(
                hours == 0 ? 'Выкл' : '$hours ч',
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.white : AppColors.accent,
                ),
              ),
              backgroundColor: isSelected
                  ? AppColors.accent
                  : AppColors.accent.withValues(alpha: 0.08),
              side: BorderSide(
                color: isSelected ? AppColors.accent : AppColors.accent,
                width: 0.5,
              ),
              onPressed: () async {
                widget.subscriptionAutoUpdateController.text =
                    hours == 0 ? '' : hours.toString();
                await StorageService.setSubscriptionAutoUpdateHours(hours);
                setState(() => _subscriptionAutoUpdateHours = hours);
                widget.onChanged();
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          'Подписки обновляются при запуске и пока приложение открыто.',
          style: TextStyle(color: c.textDisabled, fontSize: 12),
        ),
        if (!kIsWeb &&
            Theme.of(context).platform == TargetPlatform.windows) ...[
          const SizedBox(height: 20),
          Text('Режим VPN (Windows)',
              style: TextStyle(color: c.textSecondary, fontSize: 13)),
          const SizedBox(height: 8),
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
            selected: {_windowsVpnMode},
            onSelectionChanged: (selection) async {
              final next = selection.first;
              await StorageService.setWindowsVpnMode(next);
              setState(() => _windowsVpnMode = next);
              widget.onChanged();
            },
          ),
          const SizedBox(height: 8),
          Text(
            _windowsVpnMode == 'tunnel'
                ? 'Туннель: полный перехват трафика (требуются права администратора).'
                : 'Системный прокси: совместимее и стабильнее, но не весь трафик приложений.',
            style: TextStyle(color: c.textDisabled, fontSize: 12),
          ),
        ],
      ],
    );
    final switchSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SheetSwitch(
          title: 'Bypass локальной сети',
          subtitle: 'LAN-трафик идёт напрямую',
          value: _bypassLan,
          onChanged: (v) async {
            await StorageService.setBypassLan(v);
            setState(() => _bypassLan = v);
            widget.onChanged();
          },
        ),
        const SizedBox(height: 16),
        _SheetSwitch(
          title: 'Российские сайты напрямую',
          subtitle: 'RU-домены и IP идут без прокси',
          value: _ruRouting,
          onChanged: (v) async {
            final vpn = context.read<VpnProvider>();
            await StorageService.setRuRouting(v);
            setState(() => _ruRouting = v);
            await vpn.syncQuickSettingsConfig();
            widget.onChanged();
            if (vpn.isConnected) await vpn.reconnect();
          },
        ),
        const SizedBox(height: 16),
        _SheetSwitch(
          title: 'Автозапуск',
          subtitle: 'Подключаться при включении телефона',
          value: _autoStart,
          onChanged: (v) async {
            await StorageService.setAutoStart(v);
            setState(() => _autoStart = v);
            widget.onChanged();
          },
        ),
      ],
    );

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isTablet ? 24 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Настройки',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (widget.showCloseButton)
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: c.textSecondary),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (isTablet)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: primarySection),
                  const SizedBox(width: 24),
                  Expanded(child: switchSection),
                ],
              )
            else ...[
              primarySection,
              const SizedBox(height: 20),
              switchSection,
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _SheetSwitch extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final void Function(bool) onChanged;

  const _SheetSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: c.textPrimary, fontSize: 14)),
              Text(subtitle,
                  style: TextStyle(color: c.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.accent,
        ),
      ],
    );
  }
}
