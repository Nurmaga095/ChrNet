import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/storage_service.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_card.dart';

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

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xl,
                      AppSpacing.xxl,
                      AppSpacing.xl,
                      AppSpacing.lg,
                    ),
                    children: [
                      AppIconPlate(
                        icon: Icons.privacy_tip_rounded,
                        color: c.warningText,
                        size: 52,
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Text(
                        'Перед использованием приложения',
                        style: AppText.title.copyWith(color: c.textPrimary),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'ChrNet отправляет данные на сервер подписки, который '
                        'вы добавляете сами. Это нужно для проверки привязки '
                        'подписки и защиты от передачи доступа третьим лицам.',
                        style: AppText.body.copyWith(
                          color: c.textSecondary,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      const _DisclosureBullet(
                        title: 'Что передается серверу подписки',
                        body: 'HWID (на Android — Android ID, на Windows — '
                            'идентификатор установки системы), модель '
                            'устройства, версия ОС и User-Agent.',
                      ),
                      const _DisclosureBullet(
                        title: 'Когда это происходит',
                        body: 'При загрузке подписки, ее обновлении и '
                            'автообновлении подписок.',
                      ),
                      const _DisclosureBullet(
                        title: 'Что хранится на устройстве',
                        body: 'URL подписки, импортированные VPN-конфиги, '
                            'статистика подписки и настройки приложения.',
                      ),
                      const _DisclosureBullet(
                        title: 'Чего приложение не делает',
                        body: 'Не отправляет ваш интернет-трафик разработчику '
                            'и не использует рекламные или аналитические SDK.',
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppCard(
                        muted: true,
                        borderRadius: AppRadius.mdAll,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(
                          'Продолжая, вы подтверждаете, что понимаете передачу '
                          'HWID и данных устройства на выбранный вами сервер '
                          'подписки.',
                          style: AppText.caption.copyWith(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    0,
                    AppSpacing.xl,
                    AppSpacing.sm,
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const PrivacyPolicyScreen(),
                                  ),
                                );
                              },
                              child: const Text('Политика'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: FilledButton(
                              onPressed: () async {
                                await onAccepted();
                              },
                              child: const Text('Продолжить'),
                            ),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: SystemNavigator.pop,
                        style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary,
                        ),
                        child: const Text('Закрыть приложение'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        title: const Text('Политика конфиденциальности'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.sm,
              AppSpacing.page,
              AppSpacing.xxl,
            ),
            children: const [
              _PolicySection(
                title: 'Дата вступления в силу',
                body: '16 марта 2026 г.',
              ),
              _PolicySection(
                title: 'Какие данные передаются',
                body:
                    'При загрузке или обновлении подписки приложение отправляет на выбранный пользователем '
                    'сервер подписки HWID (на Android — Android ID, на Windows — идентификатор установки '
                    'системы), модель устройства, версию ОС и User-Agent. '
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
        ),
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
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: c.accentText,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: AppText.caption.copyWith(
                  color: c.textSecondary,
                  fontSize: 13.5,
                  height: 1.45,
                ),
                children: [
                  TextSpan(
                    text: '$title. ',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w600,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
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
            const SizedBox(height: AppSpacing.sm),
            Text(
              body,
              style: AppText.caption.copyWith(
                color: c.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
