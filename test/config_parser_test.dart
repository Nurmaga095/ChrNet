import 'dart:convert';

import 'package:chrnet/core/parsers/config_parser.dart';
import 'package:chrnet/core/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses hysteria2 uri and builds xray outbound', () {
    final server = ConfigParser.parse(
      'hysteria2://pass%201@example.com:443'
      '?sni=edge.example.com&insecure=1&obfs=salamander'
      '&obfs-password=mask#Hysteria%20Node',
    );

    expect(server, isNotNull);
    expect(server!.protocol, 'hysteria2');
    expect(server.name, 'Hysteria Node');
    expect(server.host, 'example.com');
    expect(server.port, 443);
    expect(server.uuid, 'pass 1');

    final config = jsonDecode(
      XrayConfigBuilder.buildSystemProxyConfig(server),
    ) as Map<String, dynamic>;
    final outbound = (config['outbounds'] as List).first as Map;
    final stream = outbound['streamSettings'] as Map;

    expect(outbound['protocol'], 'hysteria');
    expect(outbound['settings'], containsPair('version', 2));
    expect(stream['network'], 'hysteria');
    expect(stream['hysteriaSettings'], containsPair('auth', 'pass 1'));
    expect(
        stream['tlsSettings'], containsPair('serverName', 'edge.example.com'));
    expect(stream['tlsSettings'], containsPair('allowInsecure', true));
    expect(stream['finalmask'], isNotNull);
  });

  test('extracts supported uris from client-side templates', () {
    final configs = ConfigParser.parseText(
      '''
      <script>
        window.nodes = ["hysteria:\\/\\/secret@example.org:8443?sni=edge.example.org#HY2"];
      </script>
      <a href="vless://00000000-0000-0000-0000-000000000000@example.net:443?security=tls&amp;sni=example.net#VLESS"></a>
      ''',
    );

    expect(configs, hasLength(2));
    expect(configs.map((config) => config.protocol), contains('hysteria2'));
    expect(configs.map((config) => config.protocol), contains('vless'));
  });

  test('parses hysteria json after a service outbound', () {
    final configs = ConfigParser.parseText(
      jsonEncode({
        'remarks': 'Finland',
        'outbounds': [
          {'tag': 'selector', 'protocol': 'selector'},
          {
            'tag': 'proxy',
            'protocol': 'hysteria',
            'settings': {
              'version': 2,
              'address': 'fi.example.com',
              'port': 443,
            },
            'streamSettings': {
              'network': 'hysteria',
              'security': 'tls',
              'hysteriaSettings': {
                'version': 2,
                'auth': 'secret',
              },
              'tlsSettings': {
                'serverName': 'edge.example.com',
              },
            },
          },
        ],
      }),
    );

    expect(configs, hasLength(1));
    expect(configs.single.protocol, 'json');
    expect(configs.single.extras['sourceProtocol'], 'hysteria');
    expect(configs.single.name, 'Finland');
    expect(configs.single.host, 'fi.example.com');
    expect(configs.single.uuid, 'secret');
  });
}
