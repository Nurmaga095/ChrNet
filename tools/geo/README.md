# Android geo assets

`libv2ray.with-geo.aar` bundles the full upstream datasets — a 19.3 MB
`geoip.dat` covering 260 countries and a 10 MB `geosite.dat`. Assets declared
here take priority over the ones inside a library dependency, so these two files
replace them during the asset merge and the originals never reach the APK.

ChrNet's own configs use exactly one geo category, `geoip:ru`
(`XrayConfigBuilder._ruDirectIpRules`, `XrayVpnService.buildRuDirectIpRule`).
Configs the user imports as raw Xray JSON reference more than that, so the
shipped sets cover what RU subscriptions realistically use:

- `geoip.dat` keeps `RU` and `PRIVATE` — 374 KB instead of 19.3 MB.
- `geosite.dat` keeps the RU categories, `PRIVATE`, `CATEGORY-ANTIVIRUS` and
  `CATEGORY-ADS-ALL` — 3.8 MB instead of 9.5 MB. `CATEGORY-ADS-ALL` alone is
  3.76 MB of that; drop it if ad-blocking rules do not matter to you.

Anything outside these sets is stripped from the config before it reaches the
core, in both the routing rules and the DNS block — see
`XrayConfigBuilder._stripUnresolvableGeoRules` and `_stripUnresolvableGeoDns`.
The DNS pass matters most: Xray builds DNS before routing, so a stray
`geosite:` reference there fails the whole config with "failed to build DNS
configuration" and the connection never starts.

## Regenerating

    python tools/geo/trim_geodata.py tools/xray/dist/geoip.dat android/app/src/main/assets/geoip.dat

    python tools/geo/trim_geodata.py tools/xray/dist/geosite.dat android/app/src/main/assets/geosite.dat       CATEGORY-RU CATEGORY-GOV-RU CATEGORY-MEDIA-RU CATEGORY-ECOMMERCE-RU CATEGORY-ENTERTAINMENT-RU       CATEGORY-RETAIL-RU CATEGORY-ADS-ALL CATEGORY-ANTIVIRUS PRIVATE YANDEX VK MAILRU MAILRU-GROUP       RUTRACKER RUTUBE TELEGRAM

Whatever you ship must match `XrayConfigBuilder.shippedGeoIpCategories` and
`shippedGeoSiteCategories`; the stripping logic reads those sets, not the files.
