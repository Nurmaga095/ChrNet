# Настройка iOS в Xcode

## 1. Открыть проект
```
open ios/Runner.xcworkspace
```

## 2. Настройки Runner таргета (Signing & Capabilities)
- Team: выбери свой Apple Developer аккаунт
- Bundle Identifier: `com.chrnet.vpn`
- Добавь Capability → **App Groups** → `group.com.chrnet.vpn`
- Добавь Capability → **Network Extensions** → отметь **Packet Tunnel**
- Entitlements File: `Runner/Runner.entitlements`

## 3. Добавить PacketTunnel Extension
1. File → New → Target → **Network Extension**
2. Product Name: `PacketTunnel`
3. Bundle Identifier: `com.chrnet.vpn.PacketTunnel`
4. Заменить сгенерированный `PacketTunnelProvider.swift` нашим файлом из `ios/PacketTunnel/`
5. Signing & Capabilities:
   - App Groups → `group.com.chrnet.vpn`
   - Network Extensions → Packet Tunnel
   - Entitlements File: `PacketTunnel/PacketTunnel.entitlements`

## 4. Добавить LibXray.xcframework
Скачать/собрать `LibXray.xcframework`:
```bash
# Установить gomobile
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

# Клонировать и собрать
git clone https://github.com/2dust/AndroidLibXrayLite
cd AndroidLibXrayLite
gomobile bind -target=ios -o LibXray.xcframework .
```

В Xcode:
- Выбрать таргет **PacketTunnel**
- General → Frameworks and Libraries → **+** → добавить `LibXray.xcframework`
- Embed: **Do Not Embed** (статически линкуется)

## 5. Убрать stub в PacketTunnelProvider.swift
После добавления LibXray раскомментировать вызовы и удалить `throw makeError(...)`.

## 6. App Groups в Apple Developer Portal
На developer.apple.com:
- Identifiers → App Groups → создать `group.com.chrnet.vpn`
- Identifiers → `com.chrnet.vpn` → добавить App Groups + Network Extensions
- Identifiers → `com.chrnet.vpn.PacketTunnel` → создать, добавить те же capability

## 7. Сборка иконок
```bash
dart run flutter_launcher_icons
```

## 8. Запуск
```bash
flutter run -d <device-id>
```
