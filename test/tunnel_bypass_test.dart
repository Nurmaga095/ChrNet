import 'dart:convert';

import 'package:chrnet/core/models/server_config.dart';
import 'package:chrnet/core/services/xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// In Windows tunnel mode every server the core dials has to leave through the
/// physical adapter. Connections to a server that the TUN default routes catch
/// are fed back into the core, where a random balancer picks a server for them
/// again: the session reports connected and carries nothing.
Map<String, dynamic> _vless(String tag, List<String> addresses) => {
      'tag': tag,
      'protocol': 'vless',
      'settings': {
        'vnext': [
          for (final address in addresses)
            {
              'address': address,
              'port': 2443,
              'users': [
                {
                  'id': '00000000-0000-0000-0000-000000000000',
                  'encryption': 'none',
                },
              ],
            },
        ],
      },
      'streamSettings': {'network': 'tcp', 'security': 'reality'},
    };

ServerConfig _balancerServer(List<Map<String, dynamic>> outbounds) {
  return ServerConfig(
    id: 'auto',
    name: 'Auto',
    host: 'swed.example.net',
    port: 2443,
    protocol: 'json',
    uuid: '',
    rawUri: '',
    addedAt: DateTime.utc(2026),
    extras: {
      'configJson': jsonEncode({
        'outbounds': outbounds,
        'routing': {
          'rules': [
            {
              'type': 'field',
              'network': 'tcp,udp',
              'balancerTag': 'Super_Balancer',
            },
          ],
          'balancers': [
            {
              'tag': 'Super_Balancer',
              'selector': ['proxy'],
              'strategy': {'type': 'random'},
            },
          ],
        },
      }),
    },
  );
}

ServerConfig _uriServer() {
  return ServerConfig(
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
}

Map<String, Map<String, dynamic>> _outboundsByTag(String configJson) {
  final outbounds = (jsonDecode(configJson) as Map)['outbounds'] as List;
  return {
    for (final outbound in outbounds.cast<Map>())
      outbound['tag'] as String: Map<String, dynamic>.from(outbound),
  };
}

void main() {
  final balancer = _balancerServer([
    _vless('proxy', ['swed.example.net']),
    _vless('proxy-2', ['ger.example.net', '203.0.113.7']),
    _vless('proxy-3', ['swed.example.net']),
    {'tag': 'direct', 'protocol': 'freedom'},
    {'tag': 'block', 'protocol': 'blackhole'},
  ]);

  group('tunnelBypassHosts', () {
    test('lists every balancer member, not only the first', () {
      expect(
        XrayConfigBuilder.tunnelBypassHosts(balancer),
        ['swed.example.net', 'ger.example.net', '203.0.113.7'],
      );
    });

    test('is the server host for URI configs', () {
      expect(
        XrayConfigBuilder.tunnelBypassHosts(_uriServer()),
        ['vless.example.net'],
      );
    });
  });

  group('tunnel config', () {
    test('binds every outbound that dials the network itself', () {
      final outbounds =
          _outboundsByTag(XrayConfigBuilder.buildTunnelConfig(balancer));

      for (final tag in ['proxy', 'proxy-2', 'proxy-3', 'direct']) {
        expect(outbounds[tag]!['sendThrough'], '0.0.0.0', reason: tag);
      }
      expect(outbounds['block']!.containsKey('sendThrough'), isFalse);
    });

    test('leaves outbounds chained through another outbound unbound', () {
      final chained = _vless('proxy-chained', ['relay.example.net'])
        ..['streamSettings'] = {
          'network': 'tcp',
          'sockopt': {'dialerProxy': 'proxy'},
        };
      final server = _balancerServer([
        _vless('proxy', ['swed.example.net']),
        chained,
      ]);

      final outbounds =
          _outboundsByTag(XrayConfigBuilder.buildTunnelConfig(server));
      expect(outbounds['proxy']!['sendThrough'], '0.0.0.0');
      expect(outbounds['proxy-chained']!.containsKey('sendThrough'), isFalse);
    });

    test('binds the proxy outbound of URI configs', () {
      final outbounds =
          _outboundsByTag(XrayConfigBuilder.buildTunnelConfig(_uriServer()));
      expect(outbounds['proxy']!['sendThrough'], '0.0.0.0');
    });

    test('system proxy mode binds nothing', () {
      final outbounds =
          _outboundsByTag(XrayConfigBuilder.buildSystemProxyConfig(balancer));
      expect(
        outbounds.values.where((outbound) => outbound['sendThrough'] != null),
        isEmpty,
      );
    });
  });
}
