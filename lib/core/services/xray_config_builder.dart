import 'dart:convert';

import '../models/server_config.dart';
import 'storage_service.dart';

class XrayConfigBuilder {
  const XrayConfigBuilder._();
  static const List<String> _fallbackDnsServers = ['1.1.1.1', '8.8.8.8'];

  static String buildProxyConfig(ServerConfig server) {
    return buildSystemProxyConfig(server);
  }

  static String buildSystemProxyConfig(ServerConfig server,
      {bool statsApi = false}) {
    final outbound = _buildOutbound(server);
    final ruRouting = StorageService.getRuRouting();
    final dnsServers = _resolveDnsServers(server);
    final inbounds = <Map<String, dynamic>>[
      <String, dynamic>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': 10808,
        'protocol': 'socks',
        'settings': <String, dynamic>{'udp': true},
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls'],
        },
      },
      <String, dynamic>{
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': 10809,
        'protocol': 'http',
        'settings': <String, dynamic>{},
      },
      if (statsApi) _statsApiInbound(),
    ];
    final routingRules = <Map<String, dynamic>>[
      if (statsApi) _statsApiRoutingRule(),
      <String, dynamic>{
        'type': 'field',
        'outboundTag': 'direct',
        'ip': <String>[
          '127.0.0.0/8',
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
        ],
      },
      if (ruRouting) ..._russiaDirectRules(),
    ];
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{
        'servers': dnsServers,
      },
      'inbounds': inbounds,
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': routingRules,
      },
    };
    if (statsApi) {
      config['stats'] = <String, dynamic>{};
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
      config['policy'] = <String, dynamic>{
        'system': <String, dynamic>{
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      };
    }
    return jsonEncode(config);
  }

  static String buildTunnelConfig(ServerConfig server,
      {bool statsApi = false}) {
    final outbound = _buildOutbound(server);
    final ruRouting = StorageService.getRuRouting();
    final dnsServers = _resolveDnsServers(server);
    final isIp =
        RegExp(r'^[\d.]+$').hasMatch(server.host) || server.host.contains(':');
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{
        'servers': dnsServers,
      },
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'tun-in',
          'port': 0,
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': 'chrnet0',
            'mtu': 1500,
            'userLevel': 8,
            'autoRoute': true,
            'strictRoute': false,
          },
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls'],
          },
        },
        if (statsApi) _statsApiInbound(),
      ],
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[
          if (statsApi) _statsApiRoutingRule(),
          // Proxy server goes direct — avoids TUN routing loop
          <String, dynamic>{
            'type': 'field',
            'outboundTag': 'direct',
            if (isIp)
              'ip': <String>[server.host]
            else
              'domain': <String>[server.host],
          },
          // Local networks bypass TUN
          <String, dynamic>{
            'type': 'field',
            'inboundTag': <String>['tun-in'],
            'ip': <String>[
              '127.0.0.0/8',
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ],
            'outboundTag': 'direct',
          },
          // Russian traffic goes direct when preset is enabled
          if (ruRouting) ..._russiaDirectRules(),
          // All other traffic through proxy
          <String, dynamic>{
            'type': 'field',
            'inboundTag': <String>['tun-in'],
            'outboundTag': 'proxy',
          },
        ],
      },
    };
    if (statsApi) {
      config['stats'] = <String, dynamic>{};
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
      config['policy'] = <String, dynamic>{
        'system': <String, dynamic>{
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      };
    }
    return jsonEncode(config);
  }

  static Map<String, dynamic> _buildOutbound(ServerConfig server) {
    final protocol = server.protocol.toLowerCase();
    switch (protocol) {
      case 'vless':
        return _buildVless(server);
      case 'vmess':
        return _buildVmess(server);
      case 'trojan':
        return _buildTrojan(server);
      case 'ss':
        return _buildShadowsocks(server);
      default:
        throw UnsupportedError('Unsupported protocol: ${server.protocol}');
    }
  }

  static Map<String, dynamic> _buildVless(ServerConfig server) {
    final extras = server.extras;
    final flow = extras['flow'] ?? '';
    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': <String, dynamic>{
        'vnext': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': server.host,
            'port': server.port,
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': server.uuid,
                'encryption': 'none',
                if (flow.isNotEmpty) 'flow': flow,
              },
            ],
          },
        ],
      },
      'streamSettings': _buildStream(
        network: extras['type'] ?? 'tcp',
        security: extras['security'] ?? 'none',
        sni: extras['sni'] ?? server.host,
        extras: extras,
      ),
    };
  }

  static Map<String, dynamic> _buildVmess(ServerConfig server) {
    final extras = server.extras;
    final alterId = int.tryParse(extras['aid'] ?? '') ?? 0;
    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vmess',
      'settings': <String, dynamic>{
        'vnext': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': server.host,
            'port': server.port,
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': server.uuid,
                'alterId': alterId,
                'security': 'auto',
              },
            ],
          },
        ],
      },
      'streamSettings': _buildStream(
        network: extras['type'] ?? 'tcp',
        security: extras['security'] ?? 'none',
        sni: extras['sni'] ?? server.host,
        extras: extras,
      ),
    };
  }

  static Map<String, dynamic> _buildTrojan(ServerConfig server) {
    final extras = server.extras;
    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'trojan',
      'settings': <String, dynamic>{
        'servers': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': server.host,
            'port': server.port,
            'password': server.uuid,
          },
        ],
      },
      'streamSettings': _buildStream(
        network: extras['type'] ?? 'tcp',
        security: extras['security'] ?? 'tls',
        sni: extras['sni'] ?? server.host,
        extras: extras,
      ),
    };
  }

  static Map<String, dynamic> _buildShadowsocks(ServerConfig server) {
    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'shadowsocks',
      'settings': <String, dynamic>{
        'servers': <Map<String, dynamic>>[
          <String, dynamic>{
            'address': server.host,
            'port': server.port,
            'method': server.extras['method'] ?? 'aes-128-gcm',
            'password': server.uuid,
          },
        ],
      },
    };
  }

  static const int _statsApiPort = 10853;

  static Map<String, dynamic> _statsApiInbound() => <String, dynamic>{
        'tag': 'api-in',
        'listen': '127.0.0.1',
        'port': _statsApiPort,
        'protocol': 'dokodemo-door',
        'settings': <String, dynamic>{'address': '127.0.0.1'},
      };

  static Map<String, dynamic> _statsApiRoutingRule() => <String, dynamic>{
        'type': 'field',
        'inboundTag': <String>['api-in'],
        'outboundTag': 'api',
      };

  static List<Map<String, dynamic>> _russiaDirectRules() {
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'field',
        'outboundTag': 'direct',
        'domain': <String>['geosite:category-ru'],
      },
      <String, dynamic>{
        'type': 'field',
        'outboundTag': 'direct',
        'ip': <String>['geoip:ru'],
      },
    ];
  }

  static Map<String, dynamic> _buildStream({
    required String network,
    required String security,
    required String sni,
    required Map<String, String> extras,
  }) {
    final transport = network.toLowerCase();
    final stream = <String, dynamic>{'network': transport};

    switch (security) {
      case 'tls':
        stream['security'] = 'tls';
        stream['tlsSettings'] = <String, dynamic>{
          'serverName': sni,
          'allowInsecure': false,
          if ((extras['fp'] ?? '').isNotEmpty) 'fingerprint': extras['fp'],
          if ((extras['alpn'] ?? '').isNotEmpty)
            'alpn': extras['alpn']!.split(','),
        };
      case 'reality':
        stream['security'] = 'reality';
        stream['realitySettings'] = <String, dynamic>{
          'serverName': sni,
          'fingerprint': extras['fp'] ?? 'chrome',
          'shortId': extras['sid'] ?? '',
          'publicKey': extras['pbk'] ?? '',
        };
      default:
        stream['security'] = 'none';
    }

    switch (transport) {
      case 'ws':
        stream['wsSettings'] = <String, dynamic>{
          'path': extras['path'] ?? '/',
          'headers': <String, dynamic>{'Host': extras['host'] ?? sni},
        };
      case 'grpc':
        stream['grpcSettings'] = <String, dynamic>{
          'serviceName': extras['serviceName'] ?? '',
        };
      case 'h2':
      case 'http':
        stream['httpSettings'] = <String, dynamic>{
          'host': <String>[sni],
          'path': extras['path'] ?? '/',
        };
      case 'xhttp':
        stream['xhttpSettings'] = <String, dynamic>{
          'path': extras['path'] ?? '/',
          if ((extras['host'] ?? '').isNotEmpty) 'host': extras['host'],
          if ((extras['mode'] ?? '').isNotEmpty) 'mode': extras['mode'],
        };
      default:
        break;
    }

    return stream;
  }

  static List<String> _resolveDnsServers(ServerConfig server) {
    final subscriptionId = server.subscriptionId;
    if (subscriptionId == null) {
      return _fallbackDnsServers;
    }

    for (final subscription in StorageService.getSubscriptions()) {
      if (subscription.id == subscriptionId &&
          subscription.dnsServers.isNotEmpty) {
        return subscription.dnsServers;
      }
    }
    return _fallbackDnsServers;
  }
}
