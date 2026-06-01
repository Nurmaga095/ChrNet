import 'dart:convert';

import '../models/server_config.dart';
import 'storage_service.dart';

class XrayConfigBuilder {
  const XrayConfigBuilder._();
  static const List<String> _fallbackDnsServers = ['1.1.1.1', '8.8.8.8'];
  static const List<String> _ruDirectDomainRules = [
    r'regexp:(^|.*\.)ru$',
    r'regexp:(^|.*\.)su$',
    r'regexp:(^|.*\.)xn--p1ai$',
  ];
  static const List<String> _ruDirectIpRules = ['geoip:ru'];

  static String buildProxyConfig(ServerConfig server) {
    return buildSystemProxyConfig(server);
  }

  static String buildHttpPingProxyConfig(
    ServerConfig server, {
    required int httpPort,
  }) {
    final sourceOutbound = _isJsonServer(server)
        ? _normalizeOutbounds(_parseImportedConfig(server)['outbounds'])
            .firstWhere(
            _isProxyOutboundWithEndpoint,
            orElse: () => throw const FormatException(
              'JSON config has no proxy outbound',
            ),
          )
        : _buildOutbound(server);
    final outbound = Map<String, dynamic>.from(sourceOutbound);
    outbound['tag'] = 'proxy';

    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': _resolveDnsServers(server)},
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'http-ping-in',
          'listen': '127.0.0.1',
          'port': httpPort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
        },
      ],
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{'tag': 'direct', 'protocol': 'freedom'},
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[
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
        ],
      },
    };

    return jsonEncode(config);
  }

  static String buildSystemProxyConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: false,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
      );
    }

    final outbound = _buildOutbound(server);
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
      if (enableRuRouting) ..._buildRuDirectRoutingRules(),
    ];
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': dnsServers},
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

  static String buildTunnelConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: true,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
      );
    }

    final outbound = _buildOutbound(server);
    final dnsServers = _resolveDnsServers(server);
    final isIp =
        RegExp(r'^[\d.]+$').hasMatch(server.host) || server.host.contains(':');
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning'},
      'dns': <String, dynamic>{'servers': dnsServers},
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': 'tun-in',
          'port': 0,
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': 'chrnet0',
            'MTU': 1500,
            'userLevel': 8,
            'address': <String>['10.0.0.1/24'],
            'autoRoute': true,
            'strictRoute': false,
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
          if (enableRuRouting)
            ..._buildRuDirectRoutingRules(inboundTag: 'tun-in'),
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
      case 'json':
        throw UnsupportedError('JSON configs are handled at a higher level');
      case 'vless':
        return _buildVless(server);
      case 'vmess':
        return _buildVmess(server);
      case 'trojan':
        return _buildTrojan(server);
      case 'ss':
        return _buildShadowsocks(server);
      case 'hysteria':
      case 'hysteria2':
      case 'hy2':
        return _buildHysteria2(server);
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

  static Map<String, dynamic> _buildHysteria2(ServerConfig server) {
    final extras = server.extras;
    final sni = _firstNonEmpty(
          extras['sni'],
          extras['peer'],
          extras['serverName'],
        ) ??
        server.host;
    final hysteriaSettings = <String, dynamic>{
      'version': 2,
      'auth': server.uuid,
    };
    final udpIdleTimeout = _parseIntExtra(
      extras,
      const ['udpIdleTimeout', 'idleTimeout'],
    );
    if (udpIdleTimeout != null) {
      hysteriaSettings['udpIdleTimeout'] = udpIdleTimeout;
    }

    final tlsSettings = <String, dynamic>{
      'serverName': sni,
      'allowInsecure': _isTruthy(extras['insecure']),
      if ((extras['alpn'] ?? '').isNotEmpty)
        'alpn': extras['alpn']!.split(',').map((v) => v.trim()).toList(),
    };

    final streamSettings = <String, dynamic>{
      'network': 'hysteria',
      'security': 'tls',
      'hysteriaSettings': hysteriaSettings,
      'tlsSettings': tlsSettings,
    };

    final finalMask = _buildHysteriaFinalMask(extras);
    if (finalMask.isNotEmpty) {
      streamSettings['finalmask'] = finalMask;
    }

    return <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'hysteria',
      'settings': <String, dynamic>{
        'version': 2,
        'address': server.host,
        'port': server.port,
      },
      'streamSettings': streamSettings,
    };
  }

  static Map<String, dynamic> _buildHysteriaFinalMask(
    Map<String, String> extras,
  ) {
    final finalMask = <String, dynamic>{};
    final obfs = extras['obfs']?.trim().toLowerCase();
    final obfsPassword = _firstNonEmpty(
      extras['obfs-password'],
      extras['obfsPassword'],
    );
    if (obfs == 'salamander' && obfsPassword != null) {
      finalMask['udp'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'salamander',
          'settings': <String, dynamic>{'password': obfsPassword},
        },
      ];
    }

    final hopPorts = _firstNonEmpty(
      extras['mport'],
      extras['ports'],
      extras['portHopping'],
    );
    if (hopPorts != null) {
      final quicParams = <String, dynamic>{
        'udpHop': <String, dynamic>{
          'ports': hopPorts,
          if (_firstNonEmpty(extras['hopInterval'], extras['hop-interval'])
              case final interval?)
            'interval': interval,
        },
      };
      finalMask['quicParams'] = quicParams;
    }

    return finalMask;
  }

  static String? _firstNonEmpty(String? first,
      [String? second, String? third]) {
    for (final value in [first, second, third]) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  static int? _parseIntExtra(Map<String, String> extras, List<String> keys) {
    for (final key in keys) {
      final value = extras[key]?.trim();
      if (value == null || value.isEmpty) continue;
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static bool _isTruthy(String? value) {
    switch (value?.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
        return true;
      default:
        return false;
    }
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

  static List<Map<String, dynamic>> _buildRuDirectRoutingRules({
    String? inboundTag,
  }) {
    return [
      <String, dynamic>{
        'type': 'field',
        if (inboundTag != null) 'inboundTag': <String>[inboundTag],
        'domain': _ruDirectDomainRules,
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
        if (inboundTag != null) 'inboundTag': <String>[inboundTag],
        'ip': _ruDirectIpRules,
        'outboundTag': 'direct',
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

  static bool _isJsonServer(ServerConfig server) =>
      server.protocol.toLowerCase() == 'json' &&
      (server.extras['configJson'] ?? '').isNotEmpty;

  static String _buildImportedJsonConfig(
    ServerConfig server, {
    required bool tunnelMode,
    required bool statsApi,
    required bool enableRuRouting,
  }) {
    final imported = _parseImportedConfig(server);
    final outbounds = _normalizeOutbounds(imported['outbounds']);
    if (outbounds.isEmpty) {
      throw const FormatException('JSON config has no outbounds');
    }

    final importedRouting = _normalizeMap(imported['routing']);
    final importedRules = _normalizeRules(importedRouting?['rules']);
    final dns = _resolveImportedDns(imported, server);

    final config = Map<String, dynamic>.from(imported)
      ..remove('remarks')
      ..remove('meta')
      ..remove('inbounds')
      ..remove('outbounds')
      ..remove('routing')
      ..remove('dns');

    config['log'] = _normalizeMap(imported['log']) ??
        <String, dynamic>{'loglevel': 'warning'};
    config['dns'] = dns;
    config['inbounds'] = tunnelMode
        ? <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'tun-in',
              'port': 0,
              'protocol': 'tun',
              'settings': <String, dynamic>{
                'name': 'chrnet0',
                'MTU': 1500,
                'userLevel': 8,
                'address': <String>['10.0.0.1/24'],
                'autoRoute': true,
                'strictRoute': false,
              },
            },
            if (statsApi) _statsApiInbound(),
          ]
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'tag': 'socks',
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
              'tag': 'http',
              'listen': '127.0.0.1',
              'port': 10809,
              'protocol': 'http',
              'settings': <String, dynamic>{},
            },
            if (statsApi) _statsApiInbound(),
          ];
    config['outbounds'] = _ensureDirectAndBlockOutbounds(outbounds);
    config['routing'] = _buildImportedRouting(
      importedRouting,
      importedRules,
      outbounds,
      tunnelMode: tunnelMode,
      statsApi: statsApi,
      enableRuRouting: enableRuRouting,
    );

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

  static Map<String, dynamic> _parseImportedConfig(ServerConfig server) {
    final raw = server.extras['configJson'];
    if (raw == null || raw.trim().isEmpty) {
      throw const FormatException('Missing configJson');
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON config must be an object');
    }
    return decoded;
  }

  static Map<String, dynamic>? _normalizeMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  static List<Map<String, dynamic>> _normalizeOutbounds(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  static List<Map<String, dynamic>> _normalizeRules(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  static Map<String, dynamic> _resolveImportedDns(
    Map<String, dynamic> imported,
    ServerConfig server,
  ) {
    final importedDns = _normalizeMap(imported['dns']);
    if (importedDns != null) {
      return importedDns;
    }

    return <String, dynamic>{'servers': _resolveDnsServers(server)};
  }

  static List<Map<String, dynamic>> _ensureDirectAndBlockOutbounds(
    List<Map<String, dynamic>> outbounds,
  ) {
    final next = outbounds
        .map((outbound) => Map<String, dynamic>.from(outbound))
        .toList();

    final hasDirect = next.any(
      (outbound) =>
          (outbound['tag']?.toString() ?? '') == 'direct' ||
          (outbound['protocol']?.toString() ?? '') == 'freedom',
    );
    final hasBlock = next.any(
      (outbound) =>
          (outbound['tag']?.toString() ?? '') == 'block' ||
          (outbound['protocol']?.toString() ?? '') == 'blackhole',
    );

    if (!hasDirect) {
      next.add(<String, dynamic>{'tag': 'direct', 'protocol': 'freedom'});
    }
    if (!hasBlock) {
      next.add(<String, dynamic>{'tag': 'block', 'protocol': 'blackhole'});
    }

    return next;
  }

  static Map<String, dynamic> _buildImportedRouting(
    Map<String, dynamic>? importedRouting,
    List<Map<String, dynamic>> importedRules,
    List<Map<String, dynamic>> outbounds, {
    required bool tunnelMode,
    required bool statsApi,
    required bool enableRuRouting,
  }) {
    final rules = <Map<String, dynamic>>[
      if (statsApi) _statsApiRoutingRule(),
      if (tunnelMode) ..._buildJsonTunnelServerDirectRules(outbounds),
      if (tunnelMode)
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
        }
      else
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
      if (enableRuRouting)
        ..._buildRuDirectRoutingRules(inboundTag: tunnelMode ? 'tun-in' : null),
      ...importedRules,
    ];

    return <String, dynamic>{
      ...?importedRouting,
      'domainStrategy': importedRouting?['domainStrategy'] ?? 'IPIfNonMatch',
      'rules': rules,
    };
  }

  static List<Map<String, dynamic>> _buildJsonTunnelServerDirectRules(
    List<Map<String, dynamic>> outbounds,
  ) {
    final rules = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final outbound in outbounds) {
      final target = _extractJsonOutboundTarget(outbound);
      if (target == null || !seen.add('${target.type}:${target.value}')) {
        continue;
      }

      rules.add(<String, dynamic>{
        'type': 'field',
        'inboundTag': <String>['tun-in'],
        'outboundTag': 'direct',
        if (target.type == 'ip')
          'ip': <String>[target.value]
        else
          'domain': <String>[target.value],
      });
    }

    return rules;
  }

  static ({String type, String value})? _extractJsonOutboundTarget(
    Map<String, dynamic> outbound,
  ) {
    final settings = _normalizeMap(outbound['settings']);
    if (settings == null) return null;

    final vnext = settings['vnext'];
    if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
      final address = (vnext.first as Map)['address']?.toString().trim() ?? '';
      if (address.isNotEmpty) {
        return (
          type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
          value: address,
        );
      }
    }

    final servers = settings['servers'];
    if (servers is List && servers.isNotEmpty && servers.first is Map) {
      final address =
          (servers.first as Map)['address']?.toString().trim() ?? '';
      if (address.isNotEmpty) {
        return (
          type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
          value: address,
        );
      }
    }

    final address = settings['address']?.toString().trim() ?? '';
    if (address.isNotEmpty) {
      return (
        type: _looksLikeIpAddress(address) ? 'ip' : 'domain',
        value: address,
      );
    }

    return null;
  }

  static bool _looksLikeIpAddress(String host) {
    return RegExp(r'^[\d.]+$').hasMatch(host) || host.contains(':');
  }

  static bool _isProxyOutbound(Map<String, dynamic> outbound) {
    final protocol = outbound['protocol']?.toString().trim().toLowerCase();
    if (protocol == null || protocol.isEmpty) return false;
    return protocol != 'freedom' &&
        protocol != 'blackhole' &&
        protocol != 'dns' &&
        protocol != 'socks' &&
        protocol != 'http' &&
        protocol != 'loopback';
  }

  static bool _isProxyOutboundWithEndpoint(Map<String, dynamic> outbound) {
    return _isProxyOutbound(outbound) &&
        _extractJsonOutboundTarget(outbound) != null;
  }
}
