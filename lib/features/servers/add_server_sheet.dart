import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/services/import_service.dart';
import '../../core/services/storage_service.dart';
import '../../ui/theme/app_theme.dart';

class AddServerSheet extends StatelessWidget {
  final VoidCallback onServersAdded;

  const AddServerSheet({super.key, required this.onServersAdded});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final supportsQrScan =
        Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS;
    return Container(
      decoration: BoxDecoration(
        color: c.cardBackground,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 20),
              decoration: BoxDecoration(
                color: c.borderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Добавить локацию',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            // ── Подписка (URL) ────────────────────────────────────────────
            _ImportOption(
              icon: Icons.link_rounded,
              title: 'Ссылка подписки',
              subtitle: 'Загрузить все локации по URL подписки',
              onTap: () => _showSubscriptionDialog(context),
            ),

            Divider(indent: 16, endIndent: 16, color: c.borderColor),

            // ── Буфер обмена ──────────────────────────────────────────────
            _ImportOption(
              icon: Icons.content_paste_rounded,
              title: 'Из буфера обмена',
              subtitle: 'Вставить скопированный vless:// vmess:// trojan://',
              onTap: () async {
                // Await result while sheet is still open, then close
                final result = await ImportService.importFromClipboard();
                if (!context.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                _handleResult(messenger, result);
              },
            ),

            Divider(indent: 16, endIndent: 16, color: c.borderColor),

            if (supportsQrScan) ...[
              // ── QR Code ─────────────────────────────────────────────────
              _ImportOption(
                icon: Icons.qr_code_scanner_rounded,
                title: 'Сканировать QR-код',
                subtitle: 'Открыть камеру и отсканировать конфиг',
                onTap: () {
                  // Capture nav + messenger before closing sheet
                  final nav = Navigator.of(context);
                  final messenger = ScaffoldMessenger.of(context);
                  nav.pop();
                  nav.push(
                    MaterialPageRoute(
                      builder: (_) => QrScanScreen(
                        onScanned: (uri) async {
                          final result =
                              await ImportService.importFromText(uri);
                          _handleResult(messenger, result);
                        },
                      ),
                    ),
                  );
                },
              ),
              Divider(indent: 16, endIndent: 16, color: c.borderColor),
            ],

            // ── Ввод URI вручную ──────────────────────────────────────────
            _ImportOption(
              icon: Icons.edit_rounded,
              title: 'Ввести URI вручную',
              subtitle: 'Вставить или ввести vless:// / vmess:// / trojan://',
              onTap: () => _showUriInputDialog(context),
            ),

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _showSubscriptionDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: c.borderColor),
          ),
          title: Text(
            'Ссылка подписки',
            style: TextStyle(color: c.textPrimary, fontSize: 16),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: c.textPrimary, fontSize: 13),
            decoration: const InputDecoration(hintText: 'https://...'),
            maxLines: 2,
            minLines: 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Отмена', style: TextStyle(color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () async {
                final url = controller.text.trim();
                if (url.isEmpty) return;
                // Capture before any pops — both contexts are still alive here
                final messenger = ScaffoldMessenger.of(context);
                final nav = Navigator.of(context);
                Navigator.pop(ctx); // close dialog
                nav.pop(); // close bottom sheet
                _showSnack(messenger, 'Загрузка подписки...', isError: false);
                final result =
                    await ImportService.importFromSubscriptionUrl(url);
                _handleResult(messenger, result);
              },
              child: const Text('Загрузить',
                  style: TextStyle(color: AppColors.accent)),
            ),
          ],
        );
      },
    );
  }

  void _showUriInputDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: c.borderColor),
          ),
          title: Text(
            'Введите ссылку',
            style: TextStyle(color: c.textPrimary, fontSize: 16),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: c.textPrimary, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'vless://... или vmess://... или trojan://...',
            ),
            maxLines: 4,
            minLines: 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Отмена', style: TextStyle(color: c.textSecondary)),
            ),
            TextButton(
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                final messenger = ScaffoldMessenger.of(context);
                final nav = Navigator.of(context);
                Navigator.pop(ctx); // close dialog
                nav.pop(); // close bottom sheet
                final result = await ImportService.importFromUri(text);
                _handleResult(messenger, result);
              },
              child: const Text('Добавить',
                  style: TextStyle(color: AppColors.accent)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleResult(
    ScaffoldMessengerState messenger,
    ImportResponse res,
  ) async {
    if (res.result == ImportResult.success && res.configs.isNotEmpty) {
      final newConfigs = res.configs
          .where((c) => !StorageService.serverExists(c.rawUri))
          .toList();

      if (newConfigs.isEmpty) {
        _showSnack(messenger, 'Сервер уже добавлен', isError: false);
        return;
      }

      await StorageService.saveServers(newConfigs);
      onServersAdded();
      _showSnack(
        messenger,
        newConfigs.length == 1
            ? 'Сервер добавлен: ${newConfigs.first.displayName}'
            : 'Добавлено серверов: ${newConfigs.length}',
        isError: false,
      );
    } else {
      _showSnack(messenger, res.error ?? 'Ошибка импорта');
    }
  }

  void _showSnack(ScaffoldMessengerState messenger, String message,
      {bool isError = true}) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.connected,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}

class _ImportOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImportOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListTile(
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AppColors.accent, size: 22),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: c.textSecondary, fontSize: 12),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: c.textSecondary,
        size: 20,
      ),
    );
  }
}

// ─── QR Scanner Screen ────────────────────────────────────────────────────────
class QrScanScreen extends StatefulWidget {
  final Future<void> Function(String uri) onScanned;

  const QrScanScreen({super.key, required this.onScanned});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _scanner = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
  );
  bool _scanned = false;
  DateTime? _lastUnsupportedNoticeAt;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Сканировать QR'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _scanner.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scanner,
            onDetect: (capture) async {
              if (_scanned) return;

              String? value;
              var hasDetectedText = false;

              for (final barcode in capture.barcodes) {
                final candidates = [
                  barcode.displayValue,
                  barcode.url?.url,
                  barcode.rawValue,
                ];

                for (final candidate in candidates) {
                  final text = candidate?.trim();
                  if (text == null || text.isEmpty) {
                    continue;
                  }
                  hasDetectedText = true;
                  if (ImportService.canImportText(text)) {
                    value = text;
                    break;
                  }
                }

                if (value != null) {
                  break;
                }
              }

              if (value == null) {
                if (hasDetectedText) {
                  _showUnsupportedQrNotice();
                }
                return;
              }

              _scanned = true;
              final navigator = Navigator.of(context);
              navigator.pop();

              try {
                await widget.onScanned(value);
              } catch (error, stackTrace) {
                debugPrint('QR import failed: $error\n$stackTrace');
              }
            },
          ),

          // Overlay
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          const Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Text(
              'Направьте камеру на QR-код конфигурации',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  void _showUnsupportedQrNotice() {
    final now = DateTime.now();
    final lastShown = _lastUnsupportedNoticeAt;
    if (lastShown != null &&
        now.difference(lastShown) < const Duration(seconds: 2)) {
      return;
    }

    _lastUnsupportedNoticeAt = now;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'QR-код не содержит VPN-конфиг или ссылку подписки',
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }
}
