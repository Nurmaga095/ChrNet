import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
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
  late String _dns;
  late bool _autoStart;
  late bool _bypassLan;
  late bool _ruRouting;
  late String _windowsVpnMode;
  final _dnsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _dns = StorageService.getDns();
    _autoStart = StorageService.getAutoStart();
    _bypassLan = StorageService.getBypassLan();
    _ruRouting = StorageService.getRuRouting();
    _windowsVpnMode = StorageService.getWindowsVpnMode();
    _dnsController.text = _dns;
  }

  @override
  void dispose() {
    _dnsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          // ── Тема ──────────────────────────────────────────────────────────
          const _ThemeSwitcher(),
          const SizedBox(height: 10),

          _MenuItem(
            iconColor: const Color(0xFF25D366),
            icon: Icons.chat_bubble_rounded,
            label: 'Связаться с поддержкой',
            onTap: () => launchUrl(
              Uri.parse('https://t.me/VSupportV'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          const SizedBox(height: 10),
          _MenuItem(
            iconColor: const Color(0xFF2979FF),
            icon: Icons.tune_rounded,
            label: 'Настройки соединения',
            onTap: () => _showSettingsSheet(context),
          ),
          const SizedBox(height: 10),
          _MenuItem(
            iconColor: const Color(0xFFFFA000),
            icon: Icons.info_rounded,
            label: 'О приложении',
            onTap: () => _showAbout(context),
          ),
        ],
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
            Text('ChrNet VPN  v1.0.0',
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
        dns: _dns,
        autoStart: _autoStart,
        bypassLan: _bypassLan,
        ruRouting: _ruRouting,
        windowsVpnMode: _windowsVpnMode,
        dnsController: _dnsController,
        onChanged: () => setState(() {
          _dns = StorageService.getDns();
          _autoStart = StorageService.getAutoStart();
          _bypassLan = StorageService.getBypassLan();
          _ruRouting = StorageService.getRuRouting();
          _windowsVpnMode = StorageService.getWindowsVpnMode();
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
  final String dns;
  final bool autoStart;
  final bool bypassLan;
  final bool ruRouting;
  final String windowsVpnMode;
  final TextEditingController dnsController;
  final VoidCallback onChanged;

  const _SettingsSheet({
    required this.dns,
    required this.autoStart,
    required this.bypassLan,
    required this.ruRouting,
    required this.windowsVpnMode,
    required this.dnsController,
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

  @override
  void initState() {
    super.initState();
    _autoStart = widget.autoStart;
    _bypassLan = widget.bypassLan;
    _ruRouting = widget.ruRouting;
    _windowsVpnMode = widget.windowsVpnMode;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Настройки',
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Text('DNS-сервер',
                style: TextStyle(color: c.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              controller: widget.dnsController,
              style: TextStyle(color: c.textPrimary),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: '1.1.1.1',
                suffixIcon: TextButton(
                  onPressed: () async {
                    final dns = widget.dnsController.text.trim();
                    if (dns.isNotEmpty) {
                      await StorageService.setDns(dns);
                      widget.onChanged();
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Сохранить',
                      style: TextStyle(color: AppColors.accent)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: ['1.1.1.1', '8.8.8.8', '9.9.9.9'].map((dns) {
                return ActionChip(
                  label: Text(dns,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.accent)),
                  backgroundColor: AppColors.accent.withValues(alpha: 0.08),
                  side: const BorderSide(color: AppColors.accent, width: 0.5),
                  onPressed: () => widget.dnsController.text = dns,
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            if (!kIsWeb &&
                Theme.of(context).platform == TargetPlatform.windows) ...[
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
              const SizedBox(height: 20),
            ],
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
