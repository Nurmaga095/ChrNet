# ChrNet VPN — Инструкция по запуску

## 1. Установка Flutter

1. Скачать Flutter SDK: https://docs.flutter.dev/get-started/install/windows
2. Распаковать в C:\flutter
3. Добавить C:\flutter\bin в PATH
4. Проверить: `flutter doctor`

## 2. Установка Java (JDK 17)

1. Скачать: https://adoptium.net/
2. Установить, добавить JAVA_HOME в переменные среды

## 3. Android Studio

1. Скачать: https://developer.android.com/studio
2. Установить Android SDK (через SDK Manager)
3. Создать эмулятор или подключить телефон через USB

## 4. Запуск проекта

```bash
cd C:\Users\User\Desktop\chrnet
flutter pub get
flutter run
```

## 5. Сборка APK

```bash
flutter build apk --release
# APK будет в: build/app/outputs/flutter-apk/app-release.apk
```

## 6. Подключение Xray-core (реальный VPN)

В файле `android/build.gradle` добавить jitpack уже есть.
В `android/app/build.gradle` раскомментировать строку:
```
implementation 'com.github.2dust:AndroidLibXrayLite:0.7.21'
```

В `XrayVpnService.kt` раскомментировать вызовы Libv2ray.

## Структура файлов

```
lib/
├── main.dart                          — точка входа
├── core/
│   ├── models/
│   │   ├── server_config.dart         — модель сервера
│   │   ├── vpn_stats.dart             — статистика трафика
│   │   └── subscription.dart          — модель подписки
│   ├── services/
│   │   ├── vpn_provider.dart          — управление VPN
│   │   ├── import_service.dart        — импорт конфигов
│   │   └── storage_service.dart       — хранилище данных
│   └── parsers/
│       └── config_parser.dart         — парсер VLESS/VMess/Trojan/SS
├── features/
│   ├── home/home_screen.dart          — главный экран
│   ├── servers/
│   │   ├── servers_screen.dart        — список серверов
│   │   └── add_server_sheet.dart      — добавление (буфер/QR/ввод)
│   ├── subscriptions/
│   │   └── subscriptions_screen.dart  — управление подписками
│   └── settings/
│       └── settings_screen.dart       — настройки
└── ui/
    ├── theme/app_theme.dart           — тёмная тема ChrNet
    └── widgets/
        ├── power_button.dart          — кнопка включения
        └── stats_card.dart            — карточка трафика

android/app/src/main/kotlin/com/chrnet/vpn/
├── MainActivity.kt                    — точка входа Android
├── XrayVpnService.kt                  — VPN сервис
├── VpnPlugin.kt                       — Flutter <-> Android мост
└── BootReceiver.kt                    — автозапуск
```
