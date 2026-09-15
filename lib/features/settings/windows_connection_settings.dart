import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/storage_service.dart';
import '../../core/services/vpn_provider.dart';
import '../../core/services/windows_integration_service.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_card.dart';
import 'settings_screen.dart'
    show SettingsCardHeader, SettingsDivider, SettingsSwitchRow;

/// Windows connection settings: how traffic is captured, starting with Windows
/// and connecting on launch.
class WindowsConnectionSettings extends StatefulWidget {
  const WindowsConnectionSettings({super.key});

  @override
  State<WindowsConnectionSettings> createState() =>
      _WindowsConnectionSettingsState();
}

class _WindowsConnectionSettingsState extends State<WindowsConnectionSettings> {
  String _mode = 'tunnel';
  bool _autoConnect = false;
  bool _launchAtStartup = false;
  // Optimistic until the native side answers, so the note does not flash a
  // warning on every visit.
  bool _tunnelAvailable = true;

  @override
  void initState() {
    super.initState();
    _mode = StorageService.getWindowsVpnMode();
    _autoConnect = StorageService.getAutoConnect();
    _loadNativeState();
  }

  Future<void> _loadNativeState() async {
    final launchAtStartup = await WindowsIntegrationService.getLaunchAtStartup();
    final service = await WindowsIntegrationService.getServiceInfo();
    if (!mounted) return;
    setState(() {
      _launchAtStartup = launchAtStartup;
      _tunnelAvailable = service.available || service.elevated;
    });
  }

  Future<void> _setMode(String mode) async {
    final vpn = context.read<VpnProvider>();
    await StorageService.setWindowsVpnMode(mode);
    if (!mounted) return;
    setState(() => _mode = mode);
    // The mode is read when the core starts; restarting it now makes the
    // switch take effect instead of silently waiting for the next connect.
    if (vpn.isConnected) await vpn.reconnect();
  }

  Future<void> _setLaunchAtStartup(bool enabled) async {
    await WindowsIntegrationService.setLaunchAtStartup(enabled);
    final actual = await WindowsIntegrationService.getLaunchAtStartup();
    if (!mounted) return;
    setState(() => _launchAtStartup = actual);
  }

  Future<void> _setAutoConnect(bool enabled) async {
    await StorageService.setAutoConnect(enabled);
    if (!mounted) return;
    setState(() => _autoConnect = enabled);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tunnel = _mode == 'tunnel';
    final String note;
    if (!tunnel) {
      note = 'Системный прокси: через VPN идут программы, которые берут '
          'настройки прокси Windows (браузеры, Telegram). Остальные ходят '
          'напрямую.';
    } else if (_tunnelAvailable) {
      note = 'Туннель: через VPN идёт весь трафик компьютера, включая DNS. '
          'Программам, которым нужен прокси, доступны 127.0.0.1:10808 '
          'и :10809.';
    } else {
      note = 'Служба ChrNet не отвечает, поэтому туннель не запустится. '
          'Переустановите приложение или выберите системный прокси.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                selected: {_mode},
                onSelectionChanged: (selection) => _setMode(selection.first),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                note,
                style: AppText.caption.copyWith(
                  color: tunnel && !_tunnelAvailable
                      ? c.errorText
                      : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SettingsSwitchRow(
                icon: Icons.power_settings_new_rounded,
                accent: AppColors.accent,
                title: 'Запускать вместе с Windows',
                subtitle: 'ChrNet стартует свёрнутым в трей',
                value: _launchAtStartup,
                onChanged: _setLaunchAtStartup,
              ),
              const SettingsDivider(),
              SettingsSwitchRow(
                icon: Icons.bolt_rounded,
                accent: AppColors.connected,
                title: 'Подключаться при запуске',
                subtitle: 'Сразу включает VPN с выбранным сервером',
                value: _autoConnect,
                onChanged: _setAutoConnect,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
