# Privacy Policy for ChrNet VPN

Last updated: March 16, 2026

> Replace the placeholders in square brackets before publishing.

## 1. Who we are

`ChrNet VPN` is developed and published by **Nurmaga095 / ChrNet**.

If you have privacy questions, contact:

- Email: **nurmaga907@gmail.com**
- Telegram: **[@VSupportV]**

## 2. Scope of this policy

This Privacy Policy explains how `ChrNet VPN` accesses, collects, uses, stores, and shares data when you use the Android version of the app.

The app is a VPN client. It lets users import VPN configurations manually, by QR code, or by subscription URL, and connect to VPN servers chosen by the user.

## 3. Data we collect and transmit

### 3.1 Subscription server requests

When you add or update a subscription in the Android app, the app sends a request to the subscription URL provided by you.

During that request, the app may transmit the following technical data to the selected subscription server:

- `HWID (Android ID)`
- Device model
- Android version
- App `User-Agent`

We use this transmission to support subscription authorization, anti-sharing controls, fraud prevention, and subscription compatibility checks.

Important:

- These data are sent to the **subscription server selected by the user**, not automatically to the developer.
- If your subscription provider uses `Remnawave` or similar anti-sharing logic, this device data may be required for the subscription to work.

### 3.2 VPN traffic

When you connect to a VPN server, your internet traffic is routed through the VPN server defined in your imported configuration.

The developer of `ChrNet VPN` does **not** receive or store the contents of your VPN traffic.

However, the VPN server operator you choose may process your traffic according to that operator’s own privacy practices. You should review the privacy terms of your VPN provider.

## 4. Data we access locally on your device

The app may access the following data locally on your device:

- Clipboard text, when you choose import from clipboard
- Camera, when you choose scan QR code
- VPN configuration data entered or imported by you
- Subscription URLs entered by you
- Device information needed for subscription authorization on Android

## 5. Data stored locally on your device

The app stores the following data locally on the device:

- Imported VPN configurations
- Subscription URLs
- Subscription metadata returned by the subscription server, such as:
  - subscription name
  - expiry date
  - traffic usage values
  - DNS values
  - description text
- App settings, such as:
  - selected server
  - routing preferences
  - subscription auto-update interval
  - privacy disclosure acceptance state

This local data is used to make the app function and is not uploaded to the developer by default.

## 6. How we use data

We use data only for the following purposes:

- Importing and updating VPN subscriptions
- Verifying subscription access on the selected provider’s server
- Preventing subscription sharing and abuse
- Building and maintaining a VPN connection requested by the user
- Saving settings and imported configurations locally
- Showing subscription status and VPN statistics inside the app

## 7. Data sharing

We do **not** sell user data.

We do **not** use advertising SDKs, marketing SDKs, or analytics SDKs in the Android app.

Data may be transmitted to:

- The subscription server URL selected by the user
- The VPN server selected by the user

We do not share user data with ad networks.

## 8. Security

We take reasonable steps to protect data handled by the app:

- Subscription URLs on Android are limited to `HTTPS`
- Android VPN connections are limited to secure transport types supported by the app
- The app does not allow insecure subscription loading over plain `HTTP`
- Sensitive subscription response headers are not logged by the app

No software can guarantee absolute security. Third-party subscription servers and VPN servers remain outside the developer’s control.

## 9. Data retention and deletion

### 9.1 Data stored by the app locally

Local data stays on the device until one of the following happens:

- you delete a subscription or configuration in the app
- you clear app data
- you uninstall the app

### 9.2 Data transmitted to third-party servers

Data sent to subscription servers or VPN servers is controlled by those server operators, not by the app developer.

If you want such data deleted, you must contact the relevant subscription or VPN provider directly, unless otherwise stated by that provider.

## 10. Children

`ChrNet VPN` is not directed to children under 13.

## 11. Changes to this policy

We may update this Privacy Policy from time to time. The updated version will be published at the same public URL with a new effective date.

## 12. Contact

For privacy requests and questions, contact:

- Developer / Company: **Nurmaga095 / ChrNet**
- Email: **nurmaga907@gmail.com**
- Telegram: **[@VSupportV]**

---

## Publishing notes for GitHub Pages

Use a public GitHub Pages URL, for example:

- `https://<your-username>.github.io/chrnet/privacy-policy/`

Before publishing:

- Replace all placeholders in brackets
- Keep the page public and accessible without login
- Do not publish as PDF
- Use a stable URL and keep it active
- Make sure the page title clearly says `Privacy Policy`
