import 'dart:convert';

import 'package:chrnet/core/models/server_config.dart';
import 'package:chrnet/core/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows tunnel mode points the system resolver at an address inside the TUN
/// and answers it with Xray's DNS module. Name resolution then goes through
/// the tunnel like everything else, instead of leaking to the ISP or to a
/// resolver the ISP can tamper with.
ServerConfig _uriServer() => ServerConfig(
      id: 'uri',
      name: 'URI',
      host: 'vless.example.net',
      port: 443,
      protocol: 'vless',
      uuid: '00000000-0000-0000-0000-000000000000',
      rawUri: '',
      addedAt: DateTime.utc(2026),
      extras: const {'type': 'tcp', 'security': 'reality', 'sni': 'github.com'},
    );

ServerConfig _jsonServer({Map<String, dynamic>? dns}) => ServerConfig(
      id: 'json',
      name: 'JSON',
      host: 'swed.example.net',
      port: 2443,
      protocol: 'json',
      uuid: '',
      rawUri: '',
      addedAt: DateTime.utc(2026),
      extras: {
        'configJson': jsonEncode({
          if (dns != null) 'dns': dns,
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'swed.example.net',
                    'port': 2443,
                    'users': [
                      {'id': '00000000-0000-0000-0000-000000000000'},
                    ],
                  },
                ],
              },
            },
            {
              'tag': 'proxy-2',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'ger.example.net',
                    'port': 2443,
                    'users': [
                      {'id': '00000000-0000-0000-0000-000000000000'},
                    ],
                  },
                ],
              },
            },
            {'tag': 'direct', 'protocol': 'freedom'},
            {'tag': 'block', 'protocol': 'blackhole'},
          ],
          'routing': {
            'rules': [
              {
                'type': 'field',
                'network': 'tcp,udp',
                'outboundTag': 'proxy',
              },
            ],
          },
        }),
      },
    );

Map<String, dynamic> _windowsTunnel(
  ServerConfig server, {
  Map<String, List<String>> pinnedHosts = const {},
}) {
  return jsonDecode(XrayConfigBuilder.buildTunnelConfig(
    server,
    hijackDns: true,
    pinnedHosts: pinnedHosts,
    metricsPort: XrayConfigBuilder.windowsMetricsPort,
  )) as Map<String, dynamic>;
}

List<Map<String, dynamic>> _rules(Map<String, dynamic> config) =>
    ((config['routing'] as Map)['rules'] as List)
        .map((rule) => Map<String, dynamic>.from(rule as Map))
        .toList();

List<Map<String, dynamic>> _outbounds(Map<String, dynamic> config) =>
    (config['outbounds'] as List)
        .map((outbound) => Map<String, dynamic>.from(outbound as Map))
        .toList();

void main() {
  for (final entry in {
    'URI config': _uriServer(),
    'JSON config': _jsonServer(),
  }.entries) {
    group('${entry.key} in Windows tunnel mode', () {
      final config = _windowsTunnel(entry.value);

      test('answers the TUN resolver with the DNS module', () {
        final dnsOut = _outbounds(config)
            .singleWhere((outbound) => outbound['tag'] == 'dns-out');
        expect(dnsOut['protocol'], 'dns');
        // HTTPS/SVCB lookups get an immediate answer instead of a timeout.
        expect((dnsOut['settings'] as Map)['nonIPQuery'], 'reject');

        final rule = _rules(config).first;
        expect(rule['inboundTag'], ['tun-in']);
        expect(rule['ip'], [XrayConfigBuilder.tunnelDnsServer]);
        expect(rule['port'], '53');
        expect(rule['outboundTag'], 'dns-out');
      });

      test('keeps the hijack ahead of the rule blocking the TUN subnet', () {
        final rules = _rules(config);
        final blockIndex = rules.indexWhere((rule) =>
            rule['outboundTag'] == 'block' &&
            ((rule['ip'] as List?)?.contains('198.18.0.0/30') ?? false));
        expect(blockIndex, greaterThan(0));
      });

      test('serves stats over the metrics endpoint, not an API inbound', () {
        expect(config['metrics'], {
          'tag': 'metrics',
          'listen': '127.0.0.1:${XrayConfigBuilder.windowsMetricsPort}',
        });
        expect(config['stats'], isA<Map>());
        expect(
          (config['inbounds'] as List).map((inbound) => (inbound as Map)['tag']),
          isNot(contains('api-in')),
        );
      });

      test('resolves only IPv4, which the tunnel carries', () {
        expect((config['dns'] as Map)['queryStrategy'], 'UseIPv4');
      });
    });
  }

  test('pins server addresses so the core dials the routed IPs', () {
    final config = _windowsTunnel(
      _jsonServer(),
      pinnedHosts: {
        'swed.example.net': ['203.0.113.10'],
        'ger.example.net': ['203.0.113.20', '203.0.113.21'],
      },
    );
    final hosts = (config['dns'] as Map)['hosts'] as Map;
    expect(hosts['swed.example.net'], ['203.0.113.10']);
    expect(hosts['ger.example.net'], ['203.0.113.20', '203.0.113.21']);
  });

  test('keeps hosts an imported config defines itself', () {
    final config = _windowsTunnel(
      _jsonServer(dns: {
        'servers': ['1.1.1.1'],
        'hosts': {
          'panel.example.net': '198.51.100.1',
          'swed.example.net': '198.51.100.2',
        },
      }),
      pinnedHosts: {
        'swed.example.net': ['203.0.113.10'],
      },
    );
    final hosts = (config['dns'] as Map)['hosts'] as Map;
    expect(hosts['panel.example.net'], '198.51.100.1');
    expect(hosts['swed.example.net'], '198.51.100.2');
  });

  test('drops the system resolver, which would loop through the TUN', () {
    final config = _windowsTunnel(_jsonServer(dns: {
      'servers': [
        {'address': 'tcp+local://77.88.8.8', 'domains': ['domain:ru']},
        'tcp+local://8.8.8.8',
        'localhost',
        {'address': 'localhost'},
      ],
    }));
    final servers = (config['dns'] as Map)['servers'] as List;
    expect(servers, hasLength(2));
    expect(jsonEncode(servers), isNot(contains('localhost')));
  });

  test('keeps an imported queryStrategy', () {
    final config = _windowsTunnel(_jsonServer(dns: {
      'servers': ['1.1.1.1'],
      'queryStrategy': 'UseIP',
    }));
    expect((config['dns'] as Map)['queryStrategy'], 'UseIP');
  });

  test('system proxy mode gets metrics but no DNS hijack', () {
    final config = jsonDecode(XrayConfigBuilder.buildSystemProxyConfig(
      _jsonServer(),
      metricsPort: XrayConfigBuilder.windowsMetricsPort,
    )) as Map<String, dynamic>;
    expect(config['metrics'], isA<Map>());
    expect(
      _outbounds(config).where((outbound) => outbound['tag'] == 'dns-out'),
      isEmpty,
    );
  });

  test('Android config stays without hijack and metrics', () {
    final config = jsonDecode(XrayConfigBuilder.buildAndroidVpnConfig(
      _jsonServer(),
      statsApi: true,
    )) as Map<String, dynamic>;
    expect(config.containsKey('metrics'), isFalse);
    expect(
      _outbounds(config).where((outbound) => outbound['tag'] == 'dns-out'),
      isEmpty,
    );
  });

  test('proxyOutboundTags lists the outbounds that carry VPN traffic', () {
    final config = XrayConfigBuilder.buildTunnelConfig(
      _jsonServer(),
      hijackDns: true,
      metricsPort: XrayConfigBuilder.windowsMetricsPort,
    );
    expect(XrayConfigBuilder.proxyOutboundTags(config), ['proxy', 'proxy-2']);
  });
}
