import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/storage_service.dart';
import '../../ui/theme/app_theme.dart';

const privacyDisclosureVersion = '2026-03-16';

class PrivacyDisclosureGate extends StatefulWidget {
  final Widget child;

  const PrivacyDisclosureGate({super.key, required this.child});

  @override
  State<PrivacyDisclosureGate> createState() => _PrivacyDisclosureGateState();
}

class _PrivacyDisclosureGateState extends State<PrivacyDisclosureGate> {
  late bool _accepted;

  bool get _requiresDisclosure =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _accepted = !_requiresDisclosure ||
        StorageService.getPrivacyDisclosureAcceptedVersion() ==
            privacyDisclosureVersion;
  }

  Future<void> _acceptDisclosure() async {
    await StorageService.setPrivacyDisclosureAcceptedVersion(
      privacyDisclosureVersion,
    );
    if (!mounted) {
      return;
    }
    setState(() => _accepted = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted) {
      return widget.child;
    }

    return PrivacyDisclosureScreen(onAccepted: _acceptDisclosure);
  }
}

class PrivacyDisclosureScreen extends StatelessWidget {
  final Future<void> Function() onAccepted;

  const PrivacyDisclosureScreen({super.key, required this.onAccepted});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final borderRadius = BorderRadius.circular(28);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: SizedBox(
                    height: constraints.maxHeight - 40,
                    child: ClipRRect(
                      borderRadius: borderRadius,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.cardBackground.withValues(alpha: 0.96),
                          borderRadius: borderRadius,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 24,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SingleChildScrollView(
                                  padding: EdgeInsets.zero,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: AppColors.warning.withValues(
                                            alpha: 0.16,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.privacy_tip_rounded,
                                          color: AppColors.warning,
                                          size: 24,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Перед использованием приложения',
                                        style: TextStyle(
                                          color: c.textPrimary,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        'ChrNet отправляет данные на сервер подписки, который вы добавляете сами. '
                                        'Это нужно для проверки привязки подписки и защиты от передачи доступа третьим лицам.',
                                        style: TextStyle(
                                          color: c.textSecondary,
                                          fontSize: 14,
                                          height: 1.45,
                                        ),
                                      ),
                                      const SizedBox(height: 18),
                                      const _DisclosureBullet(
                                        title:
                                            'Что передается серверу подписки',
                                        body:
                                            'HWID (Android ID), модель устройства, версия Android и User-Agent.',
                                      ),
                                      const _DisclosureBullet(
                                        title: 'Когда это происходит',
                                        body:
                                            'При загрузке подписки, ее обновлении и автообновлении подписок.',
                                      ),
                                      const _DisclosureBullet(
                                        title: 'Что хранится на устройстве',
                                        body:
                                            'URL подписки, импортированные VPN-конфиги, статистика подписки и настройки приложения.',
                                      ),
                                      const _DisclosureBullet(
                                        title: 'Чего приложение не делает',
                                        body:
                                            'Не отправляет ваш интернет-трафик разработчику и не использует рекламные или аналитические SDK.',
                                      ),
                                      const SizedBox(height: 18),
                                      Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.04,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'Продолжая, вы подтверждаете, что понимаете передачу HWID и данных устройства '
                                          'на выбранный вами сервер подписки.',
                                          style: TextStyle(
                                            color: c.textPrimary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                const PrivacyPolicyScreen(),
                                          ),
                                        );
                                      },
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(
                                          color: Colors.white.withValues(
                                            alpha: 0.14,
                                          ),
                                        ),
                                        foregroundColor: c.textPrimary,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child: const Text('Политика'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: () async {
                                        await onAccepted();
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: AppColors.accent,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child: const Text('Продолжить'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Center(
                                child: TextButton(
                                  onPressed: () {
                                    SystemNavigator.pop();
                                  },
                                  child: Text(
                                    'Закрыть приложение',
                                    style: TextStyle(color: c.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

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
        title: Text(
          'Политика конфиденциальности',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: const [
          _PolicySection(
            title: 'Дата вступления в силу',
            body: '16 марта 2026 г.',
          ),
          _PolicySection(
            title: 'Какие данные передаются',
            body:
                'При загрузке или обновлении подписки приложение отправляет на выбранный пользователем '
                'сервер подписки Android ID (HWID), модель устройства, версию Android и User-Agent. '
                'Это используется для авторизации подписки и ограничения передачи доступа третьим лицам.',
          ),
          _PolicySection(
            title: 'Какие данные хранятся локально',
            body:
                'На устройстве сохраняются URL подписки, импортированные конфиги VPN, настройки приложения, '
                'дата последнего обновления подписки, объем трафика и срок действия подписки, если эти данные '
                'вернул сервер подписки.',
          ),
          _PolicySection(
            title: 'Как используется VPN-трафик',
            body:
                'Интернет-трафик пользователя направляется через VPN-серверы, указанные в импортированных '
                'конфигурациях. Разработчик приложения не получает содержимое трафика и не ведет журналы '
                'посещенных сайтов, DNS-запросов или содержимого сообщений.',
          ),
          _PolicySection(
            title: 'Когда данные отправляются',
            body:
                'Передача данных серверу подписки происходит только при загрузке подписки, ручном обновлении '
                'подписки и автообновлении подписки. Для подписок поддерживаются только HTTPS-ссылки.',
          ),
          _PolicySection(
            title: 'Чего приложение не использует',
            body:
                'Приложение не содержит рекламных SDK, аналитических SDK, трекеров, Crashlytics, Firebase, '
                'геолокации, контактов, микрофона или SMS-доступа.',
          ),
          _PolicySection(
            title: 'Контакт',
            body: 'Telegram: @VSupportV',
          ),
        ],
      ),
    );
  }
}

class _DisclosureBullet extends StatelessWidget {
  final String title;
  final String body;

  const _DisclosureBullet({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 7),
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
                children: [
                  TextSpan(
                    text: '$title. ',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicySection extends StatelessWidget {
  final String title;
  final String body;

  const _PolicySection({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.cardBackground.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
