# Google Play Console Guide for ChrNet VPN

Last updated: March 16, 2026

This file is a practical checklist for publishing the current Android app on Google Play.

It is based on the current code in this repository:

- Android app sends `HWID (Android ID)`, device model, Android version, and `User-Agent` to the user-selected subscription server during subscription import/update.
- Android app no longer allows `HTTP` subscription URLs.
- Android app does not check GitHub releases and does not self-update outside Google Play.
- Android app shows an in-app disclosure before normal usage.
- Android app includes an in-app privacy policy screen.
- Android app uses a foreground VPN service with `specialUse`.

## 1. Privacy policy URL

### Play Console section

`App content` or `Store settings` -> `Privacy policy`

### What to put there

Use a public GitHub Pages URL, not a local file, not a PDF, and not a private repo link.

Recommended format:

- `https://<your-username>.github.io/chrnet/privacy-policy/`

### What the page must contain

The published page must clearly disclose:

- the app name `ChrNet VPN`
- who publishes the app
- privacy contact email or contact method
- what data the app transmits
- what data is stored locally
- what third parties receive data
- retention and deletion policy

### Important

Google requires a public, active, non-geofenced privacy policy URL. The rendered GitHub Pages page is the correct choice.

## 2. Data safety

### Play Console section

`App content` -> `Data safety`

### Recommended high-level answers

#### Does your app collect or share any of the required user data types?

Select: **Yes**

Reason:

The app transmits device-related data to the subscription server selected by the user.

#### Is all user data collected by your app encrypted in transit?

Select: **Yes**

Reason:

- subscription loading is now `HTTPS` only
- Android app no longer permits plain `HTTP` subscription URLs

#### Do you provide a way for users to request that their data is deleted?

Safest answer right now: **No**

Reason:

- the developer does not operate user accounts in the app
- most collected off-device data is sent to third-party subscription servers selected by the user
- local app data can be removed by deleting app data or uninstalling, but that is not the same as a dedicated deletion request mechanism in Play Console

If later you create a support email or form and commit to processing deletion requests for any data under your control, you can revisit this answer.

## 3. Data types to declare

### Data type

Select:

- `Device or other IDs`

### Why

The app sends `HWID (Android ID)` to the subscription server.

Google describes this category as identifiers related to an individual device, browser, or app.

### Do not select unless your code changes

Do **not** select these for the current Android code:

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

### Notes about device model and Android version

The app also transmits device model and Android version, but Play’s taxonomy does not provide a neat dedicated `device info` bucket outside `Device or other IDs` and app performance categories. For the current code, the critical declaration is `Device or other IDs`.

If Google later asks for a broader disclosure, expand the privacy policy wording, but for the Data safety form the minimum accurate declaration is `Device or other IDs`.

## 4. Data usage and handling for `Device or other IDs`

When Play Console asks follow-up questions for `Device or other IDs`, use:

### Is this data collected, shared, or both?

Select: **Collected**

Recommended: **Do not select Shared**

Reason:

- the app transmits the ID off-device, so it is collected
- for sharing, Google provides exceptions for user-initiated transfers and cases with prominent disclosure and consent
- here the user provides the subscription URL and the app now shows an in-app disclosure before normal use

### Is this data processed ephemerally?

Select: **No**

Reason:

You cannot guarantee that the external subscription server only processes it ephemerally in memory and never stores it.

### Is this data required or optional?

Recommended answer: **Optional**

Reason:

The app can still be used with manually imported configs, QR import, or direct URI import, without adding a subscription URL.

If you later remove manual import and make subscriptions mandatory, change this to `Required`.

### Why is this data collected?

Select:

- `App functionality`
- `Fraud prevention, security, and compliance`

Do **not** select unless your code changes:

- `Analytics`
- `Advertising or marketing`
- `Developer communications`
- `Personalization`
- `Account management`

### Suggested internal justification text for your records

`ChrNet VPN collects Android ID as a device-linked identifier during subscription import and subscription refresh to allow the selected subscription server to authorize access, bind subscriptions to a device, and reduce unauthorized subscription sharing.`

## 5. App access

### Play Console section

`App content` -> `App access`

### Recommended answer

Select: **Some functionality is restricted**

### Why

The app’s core VPN connection flow requires a valid user-provided config or subscription before full connection behavior can be tested.

### What to write

Use something close to this:

`The app opens without login, but VPN connection requires importing a test subscription or test configuration. Reviewers can access the UI without credentials. To test the full VPN flow, use the review subscription URL below.`

Then provide:

- a working HTTPS test subscription URL, or
- a working test config

### If you cannot provide a test config

At minimum write:

`The app does not require account login. However, VPN connectivity features are only available after the reviewer imports a valid VPN config or subscription URL.`

Providing test access is safer than leaving the reviewer blocked.

## 6. Foreground service declaration

### Play Console section

`App content` -> `Foreground service permissions` or the current FGS declaration page shown by Play Console

### Current manifest usage

The app declares:

- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_SPECIAL_USE`

And uses a VPN service with:

- `foregroundServiceType="specialUse"`
- subtype: `VPN connectivity service`

### What to select

Select the foreground service type matching your current Android implementation:

- `Special use`

### Description to write

Use something close to this:

`ChrNet VPN uses a foreground service to maintain an active device-level VPN tunnel after the user explicitly taps Connect. The service shows a persistent notification while the VPN is active, and the user can stop the VPN at any time from the app or notification. Without the foreground service, the user-requested VPN tunnel would be interrupted by the system and the core functionality of the app would fail.`

### User impact description

Use something close to this:

`Users start the VPN manually. While active, the app shows an ongoing notification with connection status and a stop action. The foreground service runs only while the user expects the VPN tunnel to remain active.`

### Demo video

Record a short video showing:

1. App launch
2. Import of a test config or test subscription
3. User taps Connect
4. VPN permission dialog
5. Persistent notification appears
6. User disconnects from notification or app

Do not submit the declaration without a clean demo video if Play Console requests one.

## 7. Ads

### Play Console section

`App content` -> `Ads`

### Recommended answer

Select: **No, my app does not contain ads**

Reason:

Current code does not include ad SDKs or ad surfaces.

## 8. Target audience

### Play Console section

`App content` -> `Target audience and content`

### Safest recommendation

Select:

- `18 and over`

### Why

This is the safest audience selection for a VPN app that is not intended for children and avoids extra child-safety scrutiny.

If you want a broader audience, review your legal and policy position first.

## 9. Content rating

### Play Console section

`App content` -> `Content rating`

### Recommended approach

Answer honestly. For the current VPN client, the result should normally stay low because the app does not include:

- violence
- sexual content
- gambling
- user-generated public social content

If the questionnaire asks whether the app gives unrestricted internet access, answer carefully and consistently with the VPN nature of the app.

## 10. News app

### Play Console section

`App content` -> `News apps`

### Recommended answer

Select: **No**

## 11. Health, finance, government, account deletion

### Recommended answers for the current app

- Health features: **No**
- Finance features: **No**
- Government affiliation: **No**
- Account creation in app: **No**
- Account deletion requirement: **Not applicable**

## 12. Store listing text

### Where

- `Main store listing`

### What to avoid

Do not claim:

- anonymous if you send HWID to a subscription server
- no data collection if you declare `Device or other IDs`
- unlimited free VPN if service depends on third-party subscriptions
- affiliation with Google, Android, or telecom providers

### Safer short description example

`VPN client for importing secure VLESS, VMess, Trojan, and Shadowsocks configurations.`

### Safer full description blocks

Use wording like:

`ChrNet VPN is a client app for connecting to VPN servers using configurations provided by the user or the user’s subscription provider.`

`The Android app supports importing configurations by HTTPS subscription URL, QR code, clipboard, and direct URI input.`

`For subscription authorization, the app may transmit Android device information such as HWID (Android ID), device model, and Android version to the user-selected subscription server.`

`ChrNet VPN does not include advertising SDKs or analytics SDKs.`

## 13. Reviewer notes

### Where

`Publishing overview`, release notes, or reviewer notes fields if available

### Suggested note

`This app is a VPN client. To test connection, reviewers need a valid test subscription URL or VPN config. The app includes an in-app privacy disclosure and privacy policy link describing Android ID / device info transmission to the selected subscription server for subscription authorization and anti-sharing controls.`

## 14. Before final submission

Make sure all of these are true:

- Privacy policy URL is public and live
- In-app disclosure text matches Play declarations
- Data safety says `Device or other IDs`
- Ads is set to `No`
- App access includes test config if needed
- FGS declaration text matches actual behavior
- Store listing description does not claim `no data collection`
- Release build was generated after these policy changes

## 15. Official references

Official sources used for this guide:

- https://support.google.com/googleplay/android-developer/answer/10787469?hl=en
- https://support.google.com/googleplay/android-developer/answer/10144311?hl=en
- https://support.google.com/googleplay/android-developer/answer/16070163
- https://support.google.com/googleplay/android-developer/answer/16273414?hl=en
- https://support.google.com/googleplay/answer/2666094?hl=en
