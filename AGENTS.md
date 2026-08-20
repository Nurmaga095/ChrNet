# Project Memory / AGENTS.md

This file is persistent memory for AI agents working in this repository.

Read this file before making changes.

The goal is that an AI can quickly understand:
- what the app does
- how the project is structured
- which files are responsible for what
- which flows are critical
- where changes should be made
- what must be handled carefully

---

# 1. Project Overview

This repository contains `ChrNet`, a Flutter VPN client.

Main user-facing responsibilities:
- import VPN configs
- import subscription URLs
- connect and disconnect from VPN servers
- display connection stats
- manage subscriptions and server lists
- support native VPN-related flows on Android and Windows

Important reality:
- this is not just a UI app
- connection logic depends on native platform channels and generated Xray configs
- careless edits in VPN flow can break the whole product
- Android is now a supported working target alongside Windows, not an experimental shell

---

# 2. Current Product Scope

Supported working targets:
- Android
- Windows

Secondary / caution targets:
- iOS folder exists, but support should not be assumed complete unless verified
- Web folder exists for Flutter compatibility, but VPN behavior must not be assumed there

Supported import sources:
- clipboard
- QR code
- raw URI input
- raw Xray JSON input
- HTTPS subscription URL
- client-side HTML/JS subscription templates that embed supported URIs
- deep link: `chrnet://add/<url>`

Supported config protocols currently visible in code:
- VLESS, over any Xray transport (tcp, ws, grpc, xhttp, mkcp, httpupgrade, h2)
  with TLS or Reality
- Xray JSON configs from subscriptions / manual import, provided their proxy
  outbound is VLESS

VMess, Trojan, Shadowsocks and Hysteria2 / HY2 were removed. Their schemes are
listed in `ConfigParser.retiredSchemes` purely so import can tell the user the
protocol was dropped instead of reporting an unrecognised key.

---

# 3. Single Sources of Truth

These are authoritative and should not be duplicated carelessly:

- App version and build number: `pubspec.yaml`
- Connection state and runtime VPN stats: `lib/core/services/vpn_provider.dart`
- Persistent local storage and settings: `lib/core/services/storage_service.dart`
- URI/subscription parsing rules: `lib/core/parsers/config_parser.dart`
- Xray runtime config generation: `lib/core/services/xray_config_builder.dart`
- Privacy disclosure acceptance state: `StorageService` + `lib/features/privacy/privacy_screens.dart`

Do not hardcode app versions in UI, platform resources, or scripts.

Current version at the time of this note:
- `1.1.0+7`

---

# 4. High-Level Architecture

The app uses a practical layered structure:

`lib/main.dart`
- app bootstrap
- orientation and system UI setup
- `StorageService.init()`
- deep-link initialization
- `Provider` registration
- app theme and root screen

`lib/core/`
- models, parsers, services, utilities
- this is where business logic and state coordination belong

`lib/features/`
- feature screens and user flows
- current main features: home, privacy, servers, settings

`lib/ui/`
- shared widgets and theme primitives

Keep this separation:
- business logic stays in `core/`
- screen-specific presentation stays in `features/`
- reusable visual building blocks stay in `ui/`

---

# 5. Mental Model Of The App

If an AI only remembers a few things, remember this:

1. `HomeScreen` is the main operational screen and orchestrates most user actions.
2. `VpnProvider` is the single runtime state owner for connection/disconnection/stats.
3. `StorageService` is the persistence gateway for servers, subscriptions, and settings.
4. `ImportService` turns external input into parsed configs and subscription metadata.
5. `SubscriptionService` refreshes existing subscriptions and replaces their server list.
6. `XrayConfigBuilder` converts a selected `ServerConfig` into the JSON config sent to native code.
7. Native integration is reached through `MethodChannel` / `EventChannel`; breaking payload shape can break VPN runtime.

---

# 6. File Responsibility Map

This section is the most important part of the memory.

## Entry and App Shell

`lib/main.dart`
- true app entry point
- initializes storage before UI
- sets up deep link handlers
- registers `VpnProvider`
- wraps app with `PrivacyDisclosureGate`
- contains app-wide background / shell visuals

## Core Models

`lib/core/models/server_config.dart`
- canonical in-memory representation of one VPN server/config
- contains protocol, host, port, uuid/password, extras, raw URI
- may belong to a subscription through `subscriptionId`

`lib/core/models/subscription.dart`
- canonical representation of a subscription source
- stores subscription URL, refresh metadata, DNS servers, traffic usage, expiry, description

`lib/core/models/vpn_stats.dart`
- runtime stats model for connected session
- also defines `VpnStatus`

## Parsing and Import

`lib/core/parsers/config_parser.dart`
- parses single URIs and subscription payloads into `ServerConfig`
- handles `vless://` only; other schemes are matched by
  `ConfigParser.isRetiredScheme` and rejected with an explanatory message
- handles Remnawave-style `XRAY_JSON` payloads (JSON object / JSON array of configs)
- generates IDs for parsed configs
- this is where protocol parsing must be extended if new protocols are added

`lib/core/services/import_service.dart`
- main import entry for clipboard, text, URI, QR, subscription URL, and deep links
- normalizes incoming text
- rejects insecure `http://` subscription URLs
- fetches subscription payloads over HTTP
- accepts subscription bodies that contain URI lists or Xray JSON configs
- extracts configs, DNS, profile title, subscription traffic data, expire timestamp, and description
- attaches device info headers during subscription fetch

## Storage and Persistence

`lib/core/services/storage_service.dart`
- single storage layer built on Hive
- stores servers, subscriptions, selected server ID, VPN mode, routing flags, auto-update interval, privacy disclosure acceptance
- owns settings schema migration logic
- if storage keys or persisted shapes change, migrations must be updated carefully

Important stored concepts:
- servers box: imported configs
- subscriptions box: subscription metadata
- settings box: selected server, routing, update interval, privacy acceptance, Windows mode

## VPN Runtime

`lib/core/services/vpn_provider.dart`
- the most sensitive runtime file in the Dart layer
- owns selected server state
- owns connect / reconnect / disconnect flow
- communicates with native code via:
  - `com.chrnet.vpn/service`
  - `com.chrnet.vpn/stats`
- syncs state with native service on app resume
- tracks duration and traffic stats
- rebuilds runtime config before connection
- updates Android quick settings config

This file should be treated as the single runtime state machine for VPN.

`lib/core/services/xray_config_builder.dart`
- builds Xray JSON config from `ServerConfig`
- supports system proxy mode and tunnel mode
- injects stats API when needed
- applies DNS from subscription when available
- applies RU direct-routing rules when enabled

If connection works incorrectly only on one mode/platform, inspect this file early.

## Subscription Lifecycle

`lib/core/services/subscription_service.dart`
- refreshes an existing subscription by re-fetching its URL
- replaces old servers belonging to that subscription
- preserves server identity when possible by matching `rawUri`
- updates subscription metadata
- may choose a replacement selected server if the previously selected one disappears

## Platform / System Services

`lib/core/services/deep_link_service.dart`
- handles `chrnet://add/<url>`
- Windows: reads URL from CLI args
- Android: receives URL over method channel
- stores pending deep link and exposes stream for live handling

`lib/core/services/device_service.dart`
- fetches device ID / OS version / model from native side
- used mainly for subscription requests

`lib/core/services/app_info_service.dart`
- reads installed app version
- checks latest GitHub release version
- compares version strings

`lib/core/services/app_update_service.dart`
- Windows self-update helper
- downloads latest installer from GitHub releases
- launches downloaded installer

## Feature Screens

`lib/features/home/home_screen.dart`
- main screen of the app
- biggest orchestration file in the UI layer
- loads servers and subscriptions from storage
- handles import result application
- reacts to deep links
- schedules subscription auto-refresh
- manages server selection, ping checks, and notices
- opens settings

Important note:
- this file is large and acts as an integration hub
- many bugs that feel “UI-related” are actually behavior bugs here

`lib/features/settings/settings_screen.dart`
- app settings UI
- version display
- GitHub release check
- Windows self-update flow
- VPN-related settings backed by `StorageService`
- navigation to privacy policy/disclosure screens

`lib/features/privacy/privacy_screens.dart`
- privacy disclosure gate for Android
- disclosure acceptance version is controlled by `privacyDisclosureVersion`
- changing disclosure text or behavior may require updating the accepted version

`lib/features/servers/add_server_sheet.dart`
- import UI entry points
- subscription URL input
- clipboard import
- QR scan flow
- manual URI entry
- also contains QR scanning screen used by the app

## Shared UI

`lib/ui/theme/app_theme.dart`
- app visual theme and color tokens

`lib/ui/widgets/glass_card.dart`
`lib/ui/widgets/liquid_bottom_bar.dart`
`lib/ui/widgets/power_button.dart`
`lib/ui/widgets/stats_card.dart`
- reusable shared widgets used across feature screens

## Utilities

`lib/core/utils/tcp_ping.dart`
`lib/core/utils/tcp_ping_io.dart`
`lib/core/utils/tcp_ping_stub.dart`
- TCP ping implementation with platform split
- used by server quality checks in the home screen

---

# 7. Core Data Flows

These flows are more important than individual widgets.

## Import Flow

Expected flow:
1. user provides clipboard / QR / manual URI / deep link / subscription URL
2. `ImportService` normalizes and validates input
3. `ConfigParser` parses one or more configs
4. parsed configs and/or subscription metadata are saved through `StorageService`
5. UI reloads from storage

Notes:
- subscription URLs must be HTTPS
- deep links eventually become subscription URLs
- importing a subscription may also bring DNS servers, profile title, traffic data, and expiry data
- subscription bodies may contain classic URI lists or Remnawave `XRAY_JSON` payloads
- every subscription request carries device headers from `DeviceService`
  (`x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model`, `User-Agent`);
  `x-hwid` is never empty — a locally generated UUID is stored and reused when
  the platform cannot supply an id
- anti-sharing panels answer an unrecognised device with `200` plus a stub
  config (`0.0.0.0`, remark carrying the refusal text), so import rejects such a
  response instead of saving it as a server

## Subscription Refresh Flow

Expected flow:
1. `HomeScreen` decides a subscription is due for refresh
2. `SubscriptionService.refreshSubscription()` fetches latest data
3. old servers of that subscription are replaced
4. subscription metadata is updated
5. if selected server disappeared, a replacement may be chosen
6. UI reloads state from storage

Important:
- server replacement logic tries to preserve identity when `rawUri` matches
- this matters for selected server continuity

## Connection Flow

Expected flow:
1. selected server exists in `VpnProvider`
2. `VpnProvider` builds config using `XrayConfigBuilder`
3. payload is sent to native service over method channel
4. native service connects
5. provider receives connected/disconnected/error events or polls status
6. stats are tracked and exposed to UI
7. disconnect cleans runtime state and stats

Do not casually change:
- method channel names
- payload field names
- config builder assumptions
- connect/reconnect/disconnect ordering

## Privacy Flow

Expected flow:
1. app starts
2. `PrivacyDisclosureGate` checks accepted disclosure version from storage
3. on Android, disclosure is shown if version is not accepted
4. acceptance is persisted in storage

If disclosure meaning materially changes:
- bump `privacyDisclosureVersion`

---

# 8. Critical Invariants

These are project rules, not suggestions.

1. `VpnProvider` is the source of truth for connection state in Dart.
2. `StorageService` is the source of truth for persisted app state.
3. `pubspec.yaml` is the source of truth for app version/build number.
4. Subscription imports must stay HTTPS-only unless there is an explicit product decision otherwise.
5. VPN config generation must remain compatible with native platform expectations.
6. Deep link format `chrnet://add/<url>` must remain stable unless coordinated across platforms.
7. Changes to persisted storage keys or schema require migration awareness.
8. Changing selected server behavior can affect reconnect logic and quick settings sync.

---

# 9. High-Risk Files

If editing these files, move carefully and make minimal changes:

- `lib/core/services/vpn_provider.dart`
- `lib/core/services/xray_config_builder.dart`
- `lib/core/services/storage_service.dart`
- `lib/core/services/import_service.dart`
- `lib/core/parsers/config_parser.dart`
- `lib/core/services/subscription_service.dart`
- `lib/core/services/deep_link_service.dart`

Why they are risky:
- they affect connection success
- they affect data persistence
- they affect subscription correctness
- they affect platform/native integration

---

# 10. Where To Make Changes

Use this as a routing guide before editing.

If the task is about importing configs:
- start with `lib/core/services/import_service.dart`
- then inspect `lib/core/parsers/config_parser.dart`
- then inspect `lib/features/home/home_screen.dart` or `lib/features/servers/add_server_sheet.dart`

If the task is about connection / disconnection / runtime stats:
- start with `lib/core/services/vpn_provider.dart`
- then inspect `lib/core/services/xray_config_builder.dart`

If the task is about stored settings, selected server, or migrations:
- start with `lib/core/services/storage_service.dart`

If the task is about subscription refresh behavior:
- start with `lib/core/services/subscription_service.dart`
- then inspect `lib/core/services/import_service.dart`
- then inspect `lib/features/home/home_screen.dart`

If the task is about privacy notice behavior:
- start with `lib/features/privacy/privacy_screens.dart`
- then inspect `lib/core/services/storage_service.dart`

If the task is about app version / update flow:
- version value: `pubspec.yaml`
- installed/latest version logic: `lib/core/services/app_info_service.dart`
- Windows updater: `lib/core/services/app_update_service.dart`

If the task is about deep links:
- start with `lib/core/services/deep_link_service.dart`
- then inspect `lib/main.dart`
- then inspect handling in `lib/features/home/home_screen.dart`

If the task is mostly styling:
- inspect `lib/ui/theme/app_theme.dart`
- shared widgets in `lib/ui/widgets/`
- feature screen layout in the corresponding `lib/features/...`

---

# 11. Editing Rules For AI

When modifying this repository:

- prefer minimal changes
- do not rewrite large files unless necessary
- preserve valid existing comments and documentation
- keep business logic out of widgets when possible
- prefer extending existing services rather than duplicating logic
- preserve current architecture unless explicitly asked to refactor
- do not introduce version duplication outside `pubspec.yaml`

When uncertain:
- inspect the surrounding flow first
- avoid guessing payload formats used by native code
- avoid changing storage keys casually

---

# 12. Flutter / UI Rules

- use `StatelessWidget` whenever practical
- avoid unnecessary widget nesting
- prefer small reusable widgets when a block becomes hard to read
- keep feature-specific UI inside `lib/features/`
- keep shared visual components inside `lib/ui/widgets/`
- preserve current responsive/platform-aware behavior in `main.dart` and main screens

Important practical note:
- `HomeScreen` is already a large integration file, so add new behavior carefully and avoid making it even harder to reason about unless necessary

---

# 13. Storage Notes

Storage is Hive-based and initialized before app UI starts.

Current persisted areas include:
- servers
- subscriptions
- settings

Important settings currently stored:
- selected server ID
- bypass LAN
- RU routing
- Windows VPN mode
- ping check method (`proxy_get` / `proxy_head` / `tcp` / `icmp`) and proxy ping test URL
- subscription auto-update interval
- privacy disclosure accepted version

If you change:
- storage keys
- default values
- schema version
- interpretation of stored values

then update migration logic in `StorageService`.

---

# 14. Platform Notes

Android:
- current supported runtime target
- supports native VPN service integration
- supports quick settings config sync
- receives deep links through method channel
- privacy disclosure gate is relevant here
- subscription requests include device info headers
- verify Android changes against native platform-channel expectations and generated Xray config payloads

Windows:
- current supported runtime target
- supports native VPN integration
- supports tunnel/system proxy behavior
- reads deep links from CLI args
- supports self-update from GitHub installer
- uses polling for stats

Web:
- should be treated as non-VPN runtime unless specifically implemented and verified

---

# 15. Known Behavioral Details

Useful small facts for future AI sessions:

- `StorageService.getServers()` sorts servers so subscription-owned servers preserve subscription order when possible
- selected server is persisted separately from the server list
- `SubscriptionService` may replace all servers of one subscription during refresh
- `XrayConfigBuilder` can inject subscription DNS into runtime config
- RU routing is enabled through stored setting and affects generated routing rules
- `VpnProvider.selectServer()` may trigger reconnect when server changes during an active connection
- `VpnProvider` also syncs quick settings config on Android
- `HomeScreen` auto-refreshes subscriptions on a timer and also handles deep-link-driven imports

---

# 16. First Files To Open

If an AI starts a new task and has no other context, this is the recommended reading order.

For general orientation:
1. `AGENTS.md`
2. `pubspec.yaml`
3. `lib/main.dart`
4. `lib/features/home/home_screen.dart`
5. `lib/core/services/vpn_provider.dart`
6. `lib/core/services/storage_service.dart`
7. `lib/core/services/import_service.dart`
8. `lib/core/services/xray_config_builder.dart`

For import-related tasks:
1. `lib/core/services/import_service.dart`
2. `lib/core/parsers/config_parser.dart`
3. `lib/features/servers/add_server_sheet.dart`
4. `lib/features/home/home_screen.dart`

For subscription-related tasks:
1. `lib/core/services/subscription_service.dart`
2. `lib/core/services/import_service.dart`
3. `lib/core/services/storage_service.dart`
4. `lib/features/home/home_screen.dart`
5. `lib/core/models/subscription.dart`

For connection/runtime tasks:
1. `lib/core/services/vpn_provider.dart`
2. `lib/core/services/xray_config_builder.dart`
3. `lib/core/services/storage_service.dart`
4. `lib/core/models/server_config.dart`
5. `lib/core/models/vpn_stats.dart`

For settings/update tasks:
1. `lib/features/settings/settings_screen.dart`
2. `lib/core/services/storage_service.dart`
3. `lib/core/services/app_info_service.dart`
4. `lib/core/services/app_update_service.dart`
5. `pubspec.yaml`

For privacy/deep-link tasks:
1. `lib/features/privacy/privacy_screens.dart`
2. `lib/core/services/deep_link_service.dart`
3. `lib/main.dart`
4. `lib/features/home/home_screen.dart`
5. `lib/core/services/storage_service.dart`

---

# 17. Common Pitfalls

These are common ways an AI can misunderstand the project.

- Do not assume this is a simple CRUD Flutter app; connection behavior depends on native channels and Xray config generation.
- Do not assume Web or iOS behavior matches Android and Windows behavior.
- Do not add version strings directly in UI; use `pubspec.yaml` as the only release source of truth.
- Do not change storage keys or schema behavior without checking `StorageService` migrations.
- Do not treat `HomeScreen` as presentation-only; it contains important orchestration logic.
- Do not change `VpnProvider` payload structure unless native expectations are understood.
- Do not allow insecure `http://` subscription imports unless there is an explicit product decision.
- Do not break selected-server continuity during subscription refreshes.
- Do not forget that changing the active server may trigger reconnect logic.
- Do not edit privacy disclosure text meaningfully without considering a `privacyDisclosureVersion` bump.
- Do not assume subscription imports only return configs; they may also return DNS, profile title, traffic usage, expiry, and description.
- Do not assume subscription bodies are always base64 URI lists; some providers return JSON config arrays/objects.
- Do not move business logic into widgets just because the current task starts from a screen file.
- Do not make broad refactors inside `HomeScreen` unless the user explicitly asked for it.

Quick rule of thumb:
- if a change touches import, connection, storage, subscriptions, or deep links, inspect the full flow before editing

---

# 18. Testing / Verification Expectations

After code changes:
- ensure formatting remains consistent
- avoid analyzer warnings
- ensure the code still compiles when the task touches logic

Current test coverage appears minimal, so manual reasoning is important.

If a change touches:
- VPN runtime
- storage/migrations
- import parsing
- subscription refresh
- deep links

then verify more carefully than for pure UI text/style edits.

---

# 19. If You Discover Bigger Improvements

If you notice broader architectural or UX improvements that are outside the user request:
- do not silently refactor large parts of the app
- mention them as follow-up ideas or TODOs
- keep the requested task scoped

---

# 20. When To Update This File

Update `AGENTS.md` when:
- architecture changes
- folder structure changes
- supported platform scope changes
- key file responsibilities change
- import/connection/subscription/privacy flows change
- major features are added
