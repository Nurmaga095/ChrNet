import 'dart:convert';

import 'package:chrnet/core/models/server_config.dart';
import 'package:chrnet/core/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shipped geo datasets are trimmed to the categories listed in
/// [XrayConfigBuilder.shippedGeoIpCategories] and
/// [XrayConfigBuilder.shippedGeoSiteCategories] (see tools/geo/README.md).
/// References an imported config brings in must not reach the core unless the
/// category is actually present, or Xray refuses to start.
ServerConfig _jsonServer(
  List<Map<String, dynamic>> rules, {
  Map<String, dynamic>? dns,
}) {
  return ServerConfig(
    id: 'test',
    name: 'Imported',
    host: 'example.com',
    port: 443,
    protocol: 'json',
    uuid: '',
    rawUri: '',
    addedAt: DateTime.utc(2026),
    extras: {
      'configJson': jsonEncode({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'users': [
                    {'id': '00000000-0000-0000-0000-000000000000'},
                  ],
                },
              ],
            },
          },
        ],
        'routing': {'rules': rules},
        if (dns != null) 'dns': dns,
      }),
    },
  );
}

Map<String, dynamic> _dnsOf(ServerConfig server) {
  final config =
      jsonDecode(XrayConfigBuilder.buildTunnelConfig(server)) as Map;
  return Map<String, dynamic>.from(config['dns'] as Map);
}

List<Map<String, dynamic>> _rulesOf(ServerConfig server) {
  final config =
      jsonDecode(XrayConfigBuilder.buildTunnelConfig(server)) as Map;
  final routing = config['routing'] as Map;
  return (routing['rules'] as List)
      .map((rule) => Map<String, dynamic>.from(rule as Map))
      .toList();
}

void main() {
  test('keeps geo categories that ship with the app', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'direct',
        'ip': ['geoip:ru', 'geoip:private'],
      },
    ]));

    expect(
      rules.where((rule) => rule['ip'] is List).expand((rule) => rule['ip']),
      containsAll(<String>['geoip:ru', 'geoip:private']),
    );
  });

  test('drops geoip categories the trimmed dataset cannot resolve', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'direct',
        'ip': ['geoip:cn', '8.8.8.8/32'],
      },
    ]));

    final imported = rules.firstWhere(
      (rule) => (rule['ip'] as List?)?.contains('8.8.8.8/32') ?? false,
    );
    expect(imported['ip'], ['8.8.8.8/32']);
    expect(
      rules.expand((rule) => (rule['ip'] as List?) ?? const []),
      isNot(contains('geoip:cn')),
    );
  });

  test('drops negated geo categories too', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'proxy',
        'ip': ['geoip:!cn', '1.1.1.1/32'],
      },
    ]));

    expect(
      rules.expand((rule) => (rule['ip'] as List?) ?? const []),
      isNot(contains('geoip:!cn')),
    );
  });

  test('drops geosite categories outside the trimmed dataset', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'block',
        // category-ads-all ships; cn does not.
        'domain': ['geosite:cn', 'ads.example.com'],
      },
    ]));

    final imported = rules.firstWhere(
      (rule) => (rule['domain'] as List?)?.contains('ads.example.com') ?? false,
    );
    expect(imported['domain'], ['ads.example.com']);
  });

  test('removes a rule whose only matcher was a missing geo category', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'block',
        'domain': ['geosite:cn'],
      },
    ]));

    // Left in place with an empty matcher it would match every request and
    // black-hole the whole session.
    expect(rules.any((rule) => rule['outboundTag'] == 'block'), isFalse);
  });

  group('dns section', () {
    // Xray builds DNS before routing, so a bad reference here kills the
    // connection with "failed to build DNS configuration" long before any
    // routing rule is looked at. This is what broke on a real device.
    test('keeps geosite categories that ship with the app', () {
      final dns = _dnsOf(_jsonServer(const [], dns: {
        'servers': [
          '1.1.1.1',
          {
            'address': '77.88.8.8',
            'domains': ['geosite:category-ru'],
          },
        ],
      }));

      final scoped = (dns['servers'] as List).whereType<Map>().single;
      expect(scoped['domains'], ['geosite:category-ru']);
    });

    test('drops geosite categories the trimmed dataset lacks', () {
      final dns = _dnsOf(_jsonServer(const [], dns: {
        'servers': [
          '1.1.1.1',
          {
            'address': '77.88.8.8',
            'domains': ['geosite:category-ru', 'geosite:cn'],
          },
        ],
      }));

      final scoped = (dns['servers'] as List).whereType<Map>().single;
      expect(scoped['domains'], ['geosite:category-ru']);
    });

    test('removes a resolver whose whole domain scope was unresolvable', () {
      final dns = _dnsOf(_jsonServer(const [], dns: {
        'servers': [
          '1.1.1.1',
          {
            'address': '223.5.5.5',
            'domains': ['geosite:cn'],
          },
        ],
      }));

      // Left in place with no domains it would answer for every lookup.
      expect((dns['servers'] as List).whereType<Map>(), isEmpty);
      expect(dns['servers'], contains('1.1.1.1'));
    });

    test('filters expectIPs without dropping the resolver', () {
      final dns = _dnsOf(_jsonServer(const [], dns: {
        'servers': [
          {
            'address': '77.88.8.8',
            'domains': ['geosite:category-ru'],
            'expectIPs': ['geoip:ru', 'geoip:cn'],
          },
        ],
      }));

      final scoped = (dns['servers'] as List).whereType<Map>().single;
      expect(scoped['expectIPs'], ['geoip:ru']);
    });

    test('never leaves the core without a resolver', () {
      final dns = _dnsOf(_jsonServer(const [], dns: {
        'servers': [
          {
            'address': '223.5.5.5',
            'domains': ['geosite:cn'],
          },
        ],
      }));

      expect(dns['servers'], isNotEmpty);
    });
  });

  test('geosite attribute syntax is matched on the category', () {
    final rules = _rulesOf(_jsonServer([
      {
        'type': 'field',
        'outboundTag': 'direct',
        'domain': ['geosite:category-ru@ads', 'geosite:cn@ads'],
      },
    ]));

    // Scan every rule rather than picking one by position: the app prepends its
    // own RU-direct rules, which also carry a `domain` list.
    final geoDomains = rules
        .expand((rule) => (rule['domain'] as List?) ?? const [])
        .map((value) => value.toString())
        .where((value) => value.startsWith('geosite:'))
        .toList();
    expect(geoDomains, ['geosite:category-ru@ads']);
  });
}
