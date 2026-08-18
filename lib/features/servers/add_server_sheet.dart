import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/services/import_service.dart';
import '../../core/services/storage_service.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_card.dart';

class AddServerSheet extends StatelessWidget {
  final VoidCallback onServersAdded;

  const AddServerSheet({super.key, required this.onServersAdded});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final supportsQrScan =
        Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          0,
          AppSpacing.page,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Text(
                'Добавить локацию',
                textAlign: TextAlign.center,
                style: AppText.heading.copyWith(color: c.textPrimary),
              ),
            ),
            _ImportOption(
              icon: Icons.link_rounded,
              title: 'Ссылка подписки',
              subtitle: 'Загрузить все локации по URL подписки',
              onTap: () => _showSubscriptionDialog(context),
            ),
            const SizedBox(height: AppSpacing.sm),
            _ImportOption(
              icon: Icons.content_paste_rounded,
              title: 'Из буфера обмена',
              subtitle: 'Вставить URI или JSON-конфиг из буфера обмена',
              onTap: () async {
                // Await result while sheet is still open, then close
                final result = await ImportService.importFromClipboard();
                if (!context.mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                _handleResult(messenger, result);
              },
            ),
            if (supportsQrScan) ...[
              const SizedBox(height: AppSpacing.sm),
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
            ],
            const SizedBox(height: AppSpacing.sm),
            _ImportOption(
              icon: Icons.edit_rounded,
              title: 'Ввести URI вручную',
              subtitle: 'Вставить URI или Xray JSON вручную',
              onTap: () => _showUriInputDialog(context),
            ),
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
        return AlertDialog(
          title: const Text('Ссылка подписки'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'https://...'),
            maxLines: 2,
            minLines: 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.of(ctx).textSecondary,
              ),
              child: const Text('Отмена'),
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
              child: const Text('Загрузить'),
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
        return AlertDialog(
          title: const Text('Введите ссылку'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'vless://... или JSON-конфиг',
            ),
            maxLines: 4,
            minLines: 1,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.of(ctx).textSecondary,
              ),
              child: const Text('Отмена'),
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
              child: const Text('Добавить'),
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

  void _showSnack(
    ScaffoldMessengerState messenger,
    String message, {
    bool isError = true,
  }) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.connected,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        margin: const EdgeInsets.all(AppSpacing.lg),
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
    return AppCard(
      muted: true,
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          AppIconPlate(icon: icon, color: c.accentText),
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
          Icon(Icons.chevron_right_rounded, color: c.textDisabled, size: 20),
        ],
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
  bool _torchOn = false;
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
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Сканировать QR'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(
              _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
            ),
            onPressed: () async {
              await _scanner.toggleTorch();
              if (mounted) setState(() => _torchOn = !_torchOn);
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
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

          // Viewfinder
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2.5),
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
            ),
          ),

          Positioned(
            bottom: 72,
            left: AppSpacing.xl,
            right: AppSpacing.xl,
            child: Text(
              'Направьте камеру на QR-код конфигурации',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: Colors.white70),
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
      const SnackBar(
        content: Text(
          'QR-код не содержит VPN-конфиг или ссылку подписки',
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        margin: EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }
}
