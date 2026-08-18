import 'dart:convert';

import 'package:chrnet/core/parsers/config_parser.dart';
import 'package:chrnet/core/services/import_service.dart';
import 'package:chrnet/core/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses vless uri and builds xray outbound', () {
    final server = ConfigParser.parse(
      'vless://00000000-0000-0000-0000-000000000001@example.com:443'
      '?type=xhttp&security=reality&sni=edge.example.com'
      '&flow=xtls-rprx-vision#VLESS%20Node',
    );

    expect(server, isNotNull);
    expect(server!.protocol, 'vless');
    expect(server.name, 'VLESS Node');
    expect(server.host, 'example.com');
    expect(server.port, 443);
    expect(server.uuid, '00000000-0000-0000-0000-000000000001');

    final config = jsonDecode(
      XrayConfigBuilder.buildSystemProxyConfig(server),
    ) as Map<String, dynamic>;
    final outbound = (config['outbounds'] as List).first as Map;
    final stream = outbound['streamSettings'] as Map;
    final user =
        ((outbound['settings'] as Map)['vnext'] as List).first as Map;

    expect(outbound['protocol'], 'vless');
    expect((user['users'] as List).first, containsPair('encryption', 'none'));
    expect(
      (user['users'] as List).first,
      containsPair('flow', 'xtls-rprx-vision'),
    );
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'reality');
  });

  test('extracts vless uris from client-side templates', () {
    final configs = ConfigParser.parseText(
      '''
      <script>
        window.nodes = ["vless:\\/\\/00000000-0000-0000-0000-000000000002@example.org:8443?security=tls&sni=edge.example.org#One"];
      </script>
      <a href="vless://00000000-0000-0000-0000-000000000003@example.net:443?security=tls&amp;sni=example.net#Two"></a>
      ''',
    );

    expect(configs, hasLength(2));
    expect(configs.every((config) => config.protocol == 'vless'), isTrue);
    expect(configs.map((config) => config.host),
        containsAll(<String>['example.org', 'example.net']));
  });

  test('parses vless json template after a service outbound', () {
    final configs = ConfigParser.parseText(
      jsonEncode({
        'remarks': 'Finland',
        'outbounds': [
          {'tag': 'selector', 'protocol': 'selector'},
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'fi.example.com',
                  'port': 443,
                  'users': [
                    {'id': 'secret', 'encryption': 'none'},
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': 'xhttp',
              'security': 'reality',
              'realitySettings': {'serverName': 'edge.example.com'},
            },
          },
        ],
      }),
    );

    expect(configs, hasLength(1));
    expect(configs.single.protocol, 'json');
    expect(configs.single.extras['sourceProtocol'], 'vless');
    expect(configs.single.name, 'Finland');
    expect(configs.single.host, 'fi.example.com');
    expect(configs.single.uuid, 'secret');
  });

  group('retired protocols', () {
    const retiredUris = [
      'trojan://password@example.com:443#Trojan',
      'ss://YWVzLTI1Ni1nY206cGFzcw==@example.com:8388#SS',
      'hysteria2://pass@example.com:443#HY2',
      'hy2://pass@example.com:443#HY2',
      'hysteria://pass@example.com:443#HY',
    ];

    test('are no longer parsed', () {
      for (final uri in retiredUris) {
        expect(ConfigParser.parse(uri), isNull, reason: uri);
      }
      // vmess is base64-encoded JSON rather than a query string.
      final vmess = 'vmess://${base64Encode(utf8.encode(jsonEncode({
            'add': 'example.com',
            'port': 443,
            'id': '00000000-0000-0000-0000-000000000004',
            'ps': 'VMess',
          })))}';
      expect(ConfigParser.parse(vmess), isNull);
    });

    test('are skipped when mixed into a subscription', () {
      final configs = ConfigParser.parseText([
        'trojan://password@example.com:443#Trojan',
        'vless://00000000-0000-0000-0000-000000000005@example.com:443'
            '?security=tls&sni=example.com#Keep',
        'hysteria2://pass@example.com:443#HY2',
      ].join('\n'));

      expect(configs, hasLength(1));
      expect(configs.single.protocol, 'vless');
      expect(configs.single.name, 'Keep');
    });

    test('are recognised so import can explain itself', () {
      for (final uri in retiredUris) {
        expect(ConfigParser.isRetiredScheme(uri), isTrue, reason: uri);
        expect(ImportService.isValidVpnUri(uri), isFalse, reason: uri);
      }
      expect(
        ConfigParser.isRetiredScheme('vless://x@example.com:443'),
        isFalse,
      );
    });
  });

  test('json template with a non-vless outbound is rejected', () {
    // The core no longer carries Trojan, so importing this would produce a
    // server that fails only at connect time.
    final configs = ConfigParser.parseText(
      jsonEncode({
        'remarks': 'Trojan template',
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'trojan',
            'settings': {
              'servers': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'password': 'secret',
                },
              ],
            },
            'streamSettings': {'network': 'tcp', 'security': 'tls'},
          },
        ],
      }),
    );

    expect(configs, isEmpty);
  });
}
