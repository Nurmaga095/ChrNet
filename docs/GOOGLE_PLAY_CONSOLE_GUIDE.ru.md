# Гайд по Google Play Console для ChrNet VPN

Дата последнего обновления: 16 марта 2026 г.

Этот файл — практический чеклист для публикации текущей Android-версии приложения в Google Play.

Он основан на текущем коде в этом репозитории:

- Android-приложение отправляет `HWID (Android ID)`, модель устройства, версию Android и `User-Agent` на выбранный пользователем сервер подписки при импорте или обновлении подписки.
- Android-приложение больше не разрешает `HTTP`-ссылки подписок.
- Android-приложение не проверяет релизы GitHub и не обновляет себя в обход Google Play.
- Android-приложение показывает in-app disclosure до обычного использования.
- Android-приложение содержит встроенный экран политики конфиденциальности.
- Android-приложение использует foreground VPN service с типом `specialUse`.

## 1. URL политики конфиденциальности

### Раздел в Play Console

`App content` или `Store settings` -> `Privacy policy`

### Что туда вставлять

Используйте публичный URL GitHub Pages, а не локальный файл, не PDF и не приватную ссылку на репозиторий.

Рекомендуемый формат:

- `https://<your-username>.github.io/chrnet/privacy-policy/`

### Что должно быть на странице

Опубликованная страница должна явно раскрывать:

- название приложения `ChrNet VPN`
- кто публикует приложение
- email или иной способ связи по вопросам конфиденциальности
- какие данные приложение передаёт
- какие данные хранятся локально
- какие третьи стороны получают данные
- политику хранения и удаления данных

### Важно

Google требует публичный, активный, не ограниченный по географии URL политики конфиденциальности. Отрендеренная страница GitHub Pages — нормальный вариант.

## 2. Data safety

### Раздел в Play Console

`App content` -> `Data safety`

### Рекомендуемые ответы верхнего уровня

#### Collect or share any of the required user data types?

Выбрать: **Yes**

Причина:

Приложение передаёт данные устройства на выбранный пользователем сервер подписки.

#### Is all user data collected by your app encrypted in transit?

Выбрать: **Yes**

Причина:

- загрузка подписок теперь работает только по `HTTPS`
- Android-приложение больше не допускает plain `HTTP` для подписок

#### Do you provide a way for users to request that their data is deleted?

Наиболее безопасный ответ сейчас: **No**

Причина:

- разработчик не ведёт аккаунты пользователей внутри приложения
- большая часть передаваемых off-device данных уходит на сторонние серверы подписок, выбранные самим пользователем
- локальные данные можно удалить очисткой данных приложения или удалением приложения, но для Play Console это не то же самое, что отдельный deletion request mechanism

Если позже ты сделаешь email-канал или форму для обработки запросов на удаление любых данных, которые реально находятся под твоим контролем, тогда можно пересмотреть этот ответ.

## 3. Какие типы данных декларировать

### Тип данных

Выбрать:

- `Device or other IDs`

### Почему

Приложение отправляет `HWID (Android ID)` на сервер подписки.

Google описывает эту категорию как идентификаторы, относящиеся к конкретному устройству, браузеру или приложению.

### Не выбирать, если код не изменится

Для текущей Android-версии **не** выбирай:

- Location
- Contacts
- Photos
- Videos
- Audio files
- Files and docs
- Calendar
- Financial info
- Health info
- App interactions
- Crash logs
- Diagnostics
- Advertising ID related categories

### Примечание про модель устройства и версию Android

Приложение также передаёт модель устройства и версию Android, но в таксономии Play нет удобной отдельной категории `device info` вне `Device or other IDs` и некоторых performance-категорий. Для текущего кода критическая и минимально точная декларация — `Device or other IDs`.

Если Google позже попросит более широкое раскрытие, расширяй формулировки в privacy policy, но в Data safety минимально точная категория сейчас именно `Device or other IDs`.

## 4. Использование и обработка для `Device or other IDs`

Когда Play Console задаёт follow-up questions для `Device or other IDs`, используй:

### Is this data collected, shared, or both?

Выбрать: **Collected**

Рекомендуемо: **не выбирать Shared**

Причина:

- приложение передаёт ID за пределы устройства, значит это `collected`
- для `sharing` у Google есть исключения для user-initiated transfers и случаев с prominent disclosure и consent
- здесь пользователь сам указывает URL подписки, а приложение теперь показывает in-app disclosure до обычного использования

### Is this data processed ephemerally?

Выбрать: **No**

Причина:

Ты не можешь гарантировать, что внешний сервер подписки обрабатывает эти данные только в памяти и нигде не хранит их.

### Is this data required or optional?

Рекомендуемый ответ: **Optional**

Причина:

Приложением всё ещё можно пользоваться с ручным импортом конфигов, QR-импортом или прямым URI-импортом, не добавляя URL подписки.

Если позже ты уберёшь ручной импорт и сделаешь подписки обязательными, смени это на `Required`.

### Why is this data collected?

Выбрать:

- `App functionality`
- `Fraud prevention, security, and compliance`

Не выбирай, если код не изменится:

- `Analytics`
- `Advertising or marketing`
- `Developer communications`
- `Personalization`
- `Account management`

### Текст внутреннего обоснования для себя

`ChrNet VPN collects Android ID as a device-linked identifier during subscription import and subscription refresh to allow the selected subscription server to authorize access, bind subscriptions to a device, and reduce unauthorized subscription sharing.`

## 5. App access

### Раздел в Play Console

`App content` -> `App access`

### Рекомендуемый ответ

Выбрать: **Some functionality is restricted**

### Почему

Для проверки полного VPN-флоу приложению нужен валидный пользовательский конфиг или подписка.

### Что написать

Используй что-то близкое к этому тексту:

`The app opens without login, but VPN connection requires importing a test subscription or test configuration. Reviewers can access the UI without credentials. To test the full VPN flow, use the review subscription URL below.`

И потом предоставить:

- рабочий HTTPS test subscription URL, или
- рабочий тестовый конфиг

### Если тестовый доступ пока не можешь дать

Минимум напиши:

`The app does not require account login. However, VPN connectivity features are only available after the reviewer imports a valid VPN config or subscription URL.`

Дать тестовый доступ безопаснее, чем оставлять ревьюера без возможности проверить подключение.

## 6. Декларация foreground service

### Раздел в Play Console

`App content` -> `Foreground service permissions` или текущая страница FGS declaration, которую покажет Play Console

### Что использует текущее приложение

Приложение декларирует:

- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_SPECIAL_USE`

И использует VPN service с:

- `foregroundServiceType="specialUse"`
- subtype: `VPN connectivity service`

### Что выбрать

Выбрать тип foreground service, соответствующий текущей реализации:

- `Special use`

### Что написать в описании

Можно использовать текст, близкий к этому:

`ChrNet VPN uses a foreground service to maintain an active device-level VPN tunnel after the user explicitly taps Connect. The service shows a persistent notification while the VPN is active, and the user can stop the VPN at any time from the app or notification. Without the foreground service, the user-requested VPN tunnel would be interrupted by the system and the core functionality of the app would fail.`

### Что написать в user impact description

Можно использовать текст, близкий к этому:

`Users start the VPN manually. While active, the app shows an ongoing notification with connection status and a stop action. The foreground service runs only while the user expects the VPN tunnel to remain active.`

### Demo video

Запиши короткое видео, где показано:

1. запуск приложения
2. импорт тестового конфига или тестовой подписки
3. пользователь нажимает Connect
4. появляется VPN permission dialog
5. появляется persistent notification
6. пользователь отключает VPN из уведомления или из приложения

Если Play Console просит видео, не отправляй декларацию без нормального demo video.

## 7. Ads

### Раздел в Play Console

`App content` -> `Ads`

### Рекомендуемый ответ

Выбрать: **No, my app does not contain ads**

Причина:

В текущем коде нет ad SDK и рекламных поверхностей.

## 8. Target audience

### Раздел в Play Console

`App content` -> `Target audience and content`

### Наиболее безопасный вариант

Выбрать:

- `18 and over`

### Почему

Для VPN-приложения это самый безопасный вариант аудитории: приложение не предназначено для детей и так ты избежишь лишней child-safety проверки.

Если хочешь более широкую аудиторию, сначала проверь, устраивает ли тебя это с юридической и policy-стороны.

## 9. Content rating

### Раздел в Play Console

`App content` -> `Content rating`

### Рекомендуемый подход

Отвечай честно. Для текущего VPN-клиента итог обычно остаётся низким, потому что приложение не содержит:

- насилие
- сексуальный контент
- азартные игры
- публичный user-generated social content

Если в анкете будет вопрос про unrestricted internet access, отвечай аккуратно и последовательно с тем, что это VPN-клиент.

## 10. News app

### Раздел в Play Console

`App content` -> `News apps`

### Рекомендуемый ответ

Выбрать: **No**

## 11. Health, finance, government, account deletion

### Рекомендуемые ответы для текущего приложения

- Health features: **No**
- Finance features: **No**
- Government affiliation: **No**
- Account creation in app: **No**
- Account deletion requirement: **Not applicable**

## 12. Тексты store listing

### Где

- `Main store listing`

### Чего избегать

Не заявляй:

- anonymous, если приложение отправляет HWID на сервер подписки
- no data collection, если ты декларируешь `Device or other IDs`
- unlimited free VPN, если работа зависит от сторонних подписок
- affiliation with Google, Android или операторами связи

### Более безопасный short description

`VPN client for importing secure VLESS, VMess, Trojan, and Shadowsocks configurations.`

### Более безопасные блоки full description

Используй формулировки типа:

`ChrNet VPN is a client app for connecting to VPN servers using configurations provided by the user or the user’s subscription provider.`

`The Android app supports importing configurations by HTTPS subscription URL, QR code, clipboard, and direct URI input.`

`For subscription authorization, the app may transmit Android device information such as HWID (Android ID), device model, and Android version to the user-selected subscription server.`

`ChrNet VPN does not include advertising SDKs or analytics SDKs.`

## 13. Reviewer notes

### Где

`Publishing overview`, release notes или reviewer notes fields, если они есть

### Рекомендуемый текст

`This app is a VPN client. To test connection, reviewers need a valid test subscription URL or VPN config. The app includes an in-app privacy disclosure and privacy policy link describing Android ID / device info transmission to the selected subscription server for subscription authorization and anti-sharing controls.`

## 14. Перед финальной отправкой

Убедись, что все пункты ниже выполняются:

- Privacy policy URL публичный и уже работает
- In-app disclosure совпадает с тем, что заявлено в Play
- В Data safety отмечено `Device or other IDs`
- Ads выставлено в `No`
- В App access есть тестовый конфиг или тестовая подписка, если нужно
- FGS declaration совпадает с реальным поведением приложения
- В store listing нет фраз типа `no data collection`
- Release build собран уже после этих policy-правок

## 15. Официальные источники

Официальные страницы Google, на которые опирается этот гайд:

- https://support.google.com/googleplay/android-developer/answer/10787469?hl=en
- https://support.google.com/googleplay/android-developer/answer/10144311?hl=en
- https://support.google.com/googleplay/android-developer/answer/16070163
- https://support.google.com/googleplay/android-developer/answer/16273414?hl=en
- https://support.google.com/googleplay/answer/2666094?hl=en
