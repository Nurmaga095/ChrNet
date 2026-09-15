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

  /// TUN interface address. A /30 inside the IANA benchmark range keeps the
  /// broadcast domain empty and, unlike the former 10.0.0.1/24, neither
  /// overlaps the "private networks go direct" rules nor collides with a home
  /// LAN. That overlap used to turn every Windows NetBIOS broadcast into a
  /// routing loop which drained all 16 384 ephemeral UDP ports of the machine,
  /// leaving no process able to open a UDP socket while the tunnel was up.
  static const String _tunAddress = '198.18.0.1/30';
  static const String _tunSubnet = '198.18.0.0/30';

  /// The address the Windows runner registers as the TUN adapter's DNS
  /// server. Queries sent to it are answered by Xray's DNS module through the
  /// `dns-out` outbound, so name resolution travels through the tunnel instead
  /// of going in the clear to a resolver the ISP can read or tamper with.
  static const String tunnelDnsServer = '198.18.0.2';

  /// Loopback port of Xray's metrics endpoint on Windows. The ChrNet service
  /// reads traffic counters from its /debug/vars instead of starting
  /// `xray api statsquery` once a second.
  static const int windowsMetricsPort = 10813;

  static const String _dnsOutboundTag = 'dns-out';

  /// Local proxy inbounds, exposed in both Windows modes so applications that
  /// have 127.0.0.1:10808/10809 configured by hand keep working with the
  /// tunnel on.
  static const int _socksInboundPort = 10808;
  static const int _httpInboundPort = 10809;

  /// Placeholder `sendThrough` value for direct outbounds. The Windows runner
  /// rewrites it with the physical adapter address before starting the core so
  /// direct traffic cannot be picked up by the TUN default routes again. Left
  /// as-is it means "default interface", which is the old behaviour.
  static const String _physicalInterfacePlaceholder = '0.0.0.0';

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

  /// [metricsPort] exposes Xray's metrics endpoint for the Windows service.
  static String buildSystemProxyConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
    int? metricsPort,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: false,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
        metricsPort: metricsPort,
      );
    }

    final outbound = _buildOutbound(server);
    final dnsServers = _resolveDnsServers(server);
    final inbounds = <Map<String, dynamic>>[
      ..._localProxyInbounds(socksTag: 'socks-in', httpTag: 'http-in'),
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
      'log': <String, dynamic>{'loglevel': 'warning', 'access': 'none'},
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
    _applyStats(config, statsApi: statsApi, metricsPort: metricsPort);
    return jsonEncode(config);
  }

  /// [hijackDns] answers the TUN's DNS server address with Xray's DNS module
  /// (Windows, where the runner points the system resolver at it).
  /// [pinnedHosts] maps server host names to the addresses the runner routes
  /// around the tunnel, so the core always dials exactly those.
  static String buildTunnelConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
    bool localProxy = true,
    bool hijackDns = false,
    Map<String, List<String>> pinnedHosts = const {},
    int? metricsPort,
  }) {
    if (_isJsonServer(server)) {
      return _buildImportedJsonConfig(
        server,
        tunnelMode: true,
        statsApi: statsApi,
        enableRuRouting: enableRuRouting,
        localProxy: localProxy,
        hijackDns: hijackDns,
        pinnedHosts: pinnedHosts,
        metricsPort: metricsPort,
      );
    }

    final outbound = <String, dynamic>{
      ..._buildOutbound(server),
      'sendThrough': _physicalInterfacePlaceholder,
    };
    final dnsServers = _resolveDnsServers(server);
    final isIp =
        RegExp(r'^[\d.]+$').hasMatch(server.host) || server.host.contains(':');
    final config = <String, dynamic>{
      'log': <String, dynamic>{'loglevel': 'warning', 'access': 'none'},
      'dns': _withPinnedHosts(
        <String, dynamic>{
          'servers': dnsServers,
          // The tunnel carries IPv4 only. AAAA answers would send applications
          // to addresses they cannot reach through it.
          if (hijackDns) 'queryStrategy': 'UseIPv4',
        },
        pinnedHosts,
      ),
      'inbounds': <Map<String, dynamic>>[
        _tunInbound(),
        if (localProxy)
          ..._localProxyInbounds(socksTag: 'socks-in', httpTag: 'http-in'),
        if (statsApi) _statsApiInbound(),
      ],
      'outbounds': <Map<String, dynamic>>[
        outbound,
        <String, dynamic>{
          'tag': 'direct',
          'protocol': 'freedom',
          'sendThrough': _physicalInterfacePlaceholder,
        },
        <String, dynamic>{'tag': 'block', 'protocol': 'blackhole'},
        if (hijackDns) _dnsOutbound(),
      ],
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': <Map<String, dynamic>>[
          if (hijackDns) _dnsHijackRule(),
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
          // Local networks bypass the tunnel. Not scoped to the TUN inbound:
          // the local socks/http inbounds need the same treatment.
          <String, dynamic>{
            'type': 'field',
            'ip': <String>[
              '127.0.0.0/8',
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ],
            'outboundTag': 'direct',
          },
          ..._broadcastBlockRules(),
          if (enableRuRouting) ..._buildRuDirectRoutingRules(),
          // All other traffic through proxy
          <String, dynamic>{
            'type': 'field',
            'network': 'tcp,udp',
            'outboundTag': 'proxy',
          },
        ],
      },
    };
    _applyStats(config, statsApi: statsApi, metricsPort: metricsPort);
    return jsonEncode(config);
  }

  /// Every proxy server address the tunnel config can dial, for the Windows
  /// runner to route around the TUN. [ServerConfig.host] names only the first
  /// one, but a balancer template dials all of its outbounds: a server left
  /// out of the bypass has its connections caught by the TUN default routes
  /// and fed back into the core, which picks a server for them again.
  static List<String> tunnelBypassHosts(ServerConfig server) {
    final hosts = <String>{};
    void add(Object? address) {
      final value = address?.toString().trim() ?? '';
      if (value.isNotEmpty) hosts.add(value);
    }

    if (_isJsonServer(server)) {
      final outbounds =
          _normalizeOutbounds(_parseImportedConfig(server)['outbounds']);
      for (final outbound in outbounds.where(_isProxyOutbound)) {
        final settings = _normalizeMap(outbound['settings']);
        if (settings == null) continue;
        for (final key in const ['vnext', 'servers']) {
          final entries = settings[key];
          if (entries is! List) continue;
          for (final entry in entries.whereType<Map>()) {
            add(entry['address']);
          }
        }
        add(settings['address']);
      }
    }
    add(server.host);
    return hosts.toList();
  }

  /// Tags of the outbounds in a built config that carry VPN traffic, the ones
  /// the traffic counters should add up.
  static List<String> proxyOutboundTags(String configJson) {
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map) return const [];
      return _normalizeOutbounds(decoded['outbounds'])
          .where(_isProxyOutbound)
          .map((outbound) => outbound['tag']?.toString() ?? '')
          .where((tag) => tag.isNotEmpty)
          .toList();
    } on FormatException {
      return const [];
    }
  }

  static String buildAndroidVpnConfig(
    ServerConfig server, {
    bool statsApi = false,
    bool enableRuRouting = true,
  }) {
    final decoded = jsonDecode(buildTunnelConfig(
      server,
      statsApi: statsApi,
      enableRuRouting: enableRuRouting,
      localProxy: false,
    ));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Tunnel config must be an object');
    }

    final config = Map<String, dynamic>.from(decoded);
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      for (final inbound in inbounds.whereType<Map>()) {
        if ((inbound['protocol']?.toString() ?? '') != 'tun') continue;
        inbound['tag'] = 'tun';
        inbound['settings'] = <String, dynamic>{
          'name': 'xray0',
          'MTU': 1500,
          'userLevel': 8,
        };
        inbound['sniffing'] = <String, dynamic>{
          'enabled': true,
          'routeOnly': true,
          'destOverride': <String>['http', 'tls', 'quic'],
        };
      }
    }

    _replaceInboundTag(config, from: 'tun-in', to: 'tun');
    _ensureTunUserLevelPolicy(config);
    return jsonEncode(config);
  }

  static Map<String, dynamic> _buildOutbound(ServerConfig server) {
    final protocol = server.protocol.toLowerCase();
    switch (protocol) {
      case 'json':
        throw UnsupportedError('JSON configs are handled at a higher level');
      case 'vless':
        return _buildVless(server);
      default:
        // Servers saved before the app narrowed to VLESS still sit in storage.
        // They reach this point only if the user taps one, and the message is
        // what the UI shows, so name the protocol rather than failing blankly.
        throw UnsupportedError(
          'Протокол ${server.protocol.toUpperCase()} больше не поддерживается',
        );
    }
  }

  static void _replaceInboundTag(
    dynamic value, {
    required String from,
    required String to,
  }) {
    if (value is Map) {
      final inboundTag = value['inboundTag'];
      if (inboundTag == from) {
        value['inboundTag'] = to;
      } else if (inboundTag is List) {
        value['inboundTag'] =
            inboundTag.map((tag) => tag == from ? to : tag).toList();
      }
      for (final child in value.values) {
        _replaceInboundTag(child, from: from, to: to);
      }
    } else if (value is List) {
      for (final child in value) {
        _replaceInboundTag(child, from: from, to: to);
      }
    }
  }

  static void _ensureTunUserLevelPolicy(Map<String, dynamic> config) {
    final policy = _normalizeMap(config['policy']) ?? <String, dynamic>{};
    final levels = _normalizeMap(policy['levels']) ?? <String, dynamic>{};
    levels['8'] = <String, dynamic>{
      'handshake': 4,
      'connIdle': 300,
      'uplinkOnly': 1,
      'downlinkOnly': 1,
    };
    policy['levels'] = levels;
    config['policy'] = policy;
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

  /// Traffic counters for the session. Android reads them through the API
  /// inbound; Windows reads the metrics endpoint on [metricsPort].
  static void _applyStats(
    Map<String, dynamic> config, {
    required bool statsApi,
    required int? metricsPort,
  }) {
    if (!statsApi && metricsPort == null) return;
    config['stats'] = <String, dynamic>{};
    if (statsApi) {
      config['api'] = <String, dynamic>{
        'tag': 'api',
        'services': <String>['StatsService'],
      };
    }
    if (metricsPort != null) {
      config['metrics'] = <String, dynamic>{
        'tag': 'metrics',
        'listen': '127.0.0.1:$metricsPort',
      };
    }
    config['policy'] = <String, dynamic>{
      'system': <String, dynamic>{
        'statsOutboundDownlink': true,
        'statsOutboundUplink': true,
      },
    };
  }

  static Map<String, dynamic> _dnsOutbound() => <String, dynamic>{
        'tag': _dnsOutboundTag,
        'protocol': 'dns',
        // Only A and AAAA reach the DNS module. Refusing the rest (HTTPS,
        // SVCB) answers them at once instead of letting them time out.
        'settings': <String, dynamic>{'nonIPQuery': 'reject'},
      };

  /// Must precede [_broadcastBlockRules], whose TUN subnet block covers
  /// [tunnelDnsServer].
  static Map<String, dynamic> _dnsHijackRule() => <String, dynamic>{
        'type': 'field',
        'inboundTag': <String>['tun-in'],
        'ip': <String>[tunnelDnsServer],
        'port': '53',
        'outboundTag': _dnsOutboundTag,
      };

  /// Readies an imported DNS section for answering the system resolver.
  /// "localhost" means the system resolver, which now points back into the
  /// tunnel: a lookup sent there would come straight back to the same module.
  static Map<String, dynamic> _prepareTunnelDns(Map<String, dynamic> dns) {
    final next = Map<String, dynamic>.from(dns);
    final servers = dns['servers'];
    if (servers is List) {
      final kept = servers.where((server) {
        final address =
            server is Map ? server['address']?.toString() : server?.toString();
        return (address ?? '').trim().toLowerCase() != 'localhost';
      }).toList();
      next['servers'] =
          kept.isEmpty ? List<String>.from(_fallbackDnsServers) : kept;
    }
    next.putIfAbsent('queryStrategy', () => 'UseIPv4');
    return next;
  }

  /// Adds [pinnedHosts] to a DNS section. Entries the section already defines
  /// win: they are a deliberate choice of whoever wrote the config.
  static Map<String, dynamic> _withPinnedHosts(
    Map<String, dynamic> dns,
    Map<String, List<String>> pinnedHosts,
  ) {
    if (pinnedHosts.isEmpty) return dns;
    final existing = _normalizeMap(dns['hosts']) ?? <String, dynamic>{};
    return <String, dynamic>{
      ...dns,
      'hosts': <String, dynamic>{
        for (final entry in pinnedHosts.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
        ...existing,
      },
    };
  }

  static Map<String, dynamic> _tunInbound() => <String, dynamic>{
        'tag': 'tun-in',
        'port': 0,
        'protocol': 'tun',
        'settings': <String, dynamic>{
          'name': 'chrnet0',
          'MTU': 1500,
          'userLevel': 8,
          'address': <String>[_tunAddress],
          'autoRoute': true,
          'strictRoute': false,
        },
        // Packets arrive addressed by IP, so without sniffing every `domain:`
        // routing rule is dead weight in tunnel mode — a site kept direct (or
        // forced through the proxy) by domain would be routed only by its IP,
        // which is how the two Windows modes ended up disagreeing about where
        // a given site goes. routeOnly keeps the original destination and uses
        // the sniffed name for routing alone.
        'sniffing': <String, dynamic>{
          'enabled': true,
          'routeOnly': true,
          'destOverride': <String>['http', 'tls', 'quic'],
        },
      };

  static List<Map<String, dynamic>> _localProxyInbounds({
    required String socksTag,
    required String httpTag,
  }) =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'tag': socksTag,
          'listen': '127.0.0.1',
          'port': _socksInboundPort,
          'protocol': 'socks',
          'settings': <String, dynamic>{'udp': true},
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls'],
          },
        },
        <String, dynamic>{
          'tag': httpTag,
          'listen': '127.0.0.1',
          'port': _httpInboundPort,
          'protocol': 'http',
          'settings': <String, dynamic>{},
        },
      ];

  /// Broadcast, multicast and LAN-discovery noise must never leave the TUN.
  /// Windows keeps NetBIOS over TCP/IP enabled on a freshly created adapter and
  /// announces itself on it the moment it comes up. Sent on rather than
  /// blackholed, such a broadcast is delivered back into the tunnel's own
  /// subnet, which opens another UDP socket for the next copy of it — the loop
  /// that used to eat all 16 384 ephemeral UDP ports within seconds of
  /// connecting. Link-local is in the list because the TUN falls back to an
  /// APIPA address when it fails to get its own.
  static List<Map<String, dynamic>> _broadcastBlockRules() =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'field',
          'ip': <String>[
            '224.0.0.0/4',
            '255.255.255.255/32',
            '169.254.0.0/16',
            _tunSubnet,
          ],
          'outboundTag': 'block',
        },
        <String, dynamic>{
          'type': 'field',
          // NetBIOS, SSDP, WS-Discovery, mDNS, LLMNR.
          'port': '137-139,1900,3702,5353,5355',
          'outboundTag': 'block',
        },
      ];

  static List<Map<String, dynamic>> _buildRuDirectRoutingRules() {
    return [
      <String, dynamic>{
        'type': 'field',
        'domain': _ruDirectDomainRules,
        'outboundTag': 'direct',
      },
      <String, dynamic>{
        'type': 'field',
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
    bool localProxy = true,
    bool hijackDns = false,
    Map<String, List<String>> pinnedHosts = const {},
    int? metricsPort,
  }) {
    final imported = _parseImportedConfig(server);
    final outbounds = _normalizeOutbounds(imported['outbounds']);
    if (outbounds.isEmpty) {
      throw const FormatException('JSON config has no outbounds');
    }

    final importedRouting = _normalizeMap(imported['routing']);
    final importedRules = _normalizeRules(importedRouting?['rules']);
    var dns = _resolveImportedDns(imported, server);
    if (hijackDns) dns = _prepareTunnelDns(dns);
    dns = _withPinnedHosts(dns, pinnedHosts);

    final config = Map<String, dynamic>.from(imported)
      ..remove('remarks')
      ..remove('meta')
      ..remove('inbounds')
      ..remove('outbounds')
      ..remove('routing')
      ..remove('dns');

    final log = _normalizeMap(imported['log']) ??
        <String, dynamic>{'loglevel': 'warning'};
    // Without this Xray writes its access log to stdout, which the Windows
    // runner captures into xray.log — megabytes for a single session.
    log.putIfAbsent('access', () => 'none');
    config['log'] = log;
    config['dns'] = dns;
    config['inbounds'] = <Map<String, dynamic>>[
      if (tunnelMode) _tunInbound(),
      if (localProxy)
        ..._localProxyInbounds(socksTag: 'socks', httpTag: 'http'),
      if (statsApi) _statsApiInbound(),
    ];
    final nextOutbounds = _ensureDirectAndBlockOutbounds(
      outbounds,
      bindPhysicalInterface: tunnelMode,
    );
    if (hijackDns &&
        !nextOutbounds.any((outbound) => outbound['tag'] == _dnsOutboundTag)) {
      nextOutbounds.add(_dnsOutbound());
    }
    config['outbounds'] = nextOutbounds;
    config['routing'] = _buildImportedRouting(
      importedRouting,
      importedRules,
      outbounds,
      tunnelMode: tunnelMode,
      statsApi: statsApi,
      enableRuRouting: enableRuRouting,
      hijackDns: hijackDns,
    );

    _applyStats(config, statsApi: statsApi, metricsPort: metricsPort);

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

  /// Geo categories present in the trimmed datasets we ship.
  ///
  /// Keep in sync with the generation commands in tools/geo/README.md. Anything
  /// outside these sets is unresolvable at runtime and must be stripped before
  /// the config reaches the core.
  static const Set<String> shippedGeoIpCategories = {'ru', 'private'};

  static const Set<String> shippedGeoSiteCategories = {
    'category-ru',
    'category-gov-ru',
    'category-media-ru',
    'category-ecommerce-ru',
    'category-entertainment-ru',
    'category-retail-ru',
    'category-ads-all',
    'category-antivirus',
    'private',
    'yandex',
    'vk',
    'mailru',
    'mailru-group',
    'rutracker',
    'rutube',
    'telegram',
  };

  /// Whether the core can resolve `geoip:x` / `geosite:x` as written.
  static bool _isResolvableGeoToken(String token) {
    String bare(String value) =>
        value.startsWith('!') ? value.substring(1) : value;

    // `geosite:x@attr` narrows a category by attribute; the category still has
    // to be present, and the attribute does not change which file is loaded.
    if (token.startsWith('geosite:')) {
      final category = bare(token.substring('geosite:'.length)).split('@').first;
      return shippedGeoSiteCategories.contains(category);
    }
    if (token.startsWith('geoip:')) {
      // `geoip:!ru` negates a category but still needs it loaded.
      return shippedGeoIpCategories.contains(bare(token.substring('geoip:'.length)));
    }
    return true;
  }

  /// Drops geo references the trimmed datasets cannot resolve.
  ///
  /// Only user-imported raw JSON can contain them — everything this class
  /// generates itself stays within [shippedGeoIpCategories]. Xray refuses to
  /// start when a rule names a missing category, so an untouched import would
  /// mean "cannot connect at all". Dropping the reference instead costs the
  /// user that one rule: the affected traffic falls through to the config's
  /// default route, which for a VPN config means through the tunnel rather
  /// than around it.
  static List<Map<String, dynamic>> _stripUnresolvableGeoRules(
    List<Map<String, dynamic>> rules,
  ) {
    const matcherKeys = ['ip', 'domain'];
    final kept = <Map<String, dynamic>>[];

    for (final rule in rules) {
      final next = Map<String, dynamic>.from(rule);
      var hadMatcher = false;
      var lostEveryMatcher = true;

      for (final key in matcherKeys) {
        final values = next[key];
        if (values is! List) continue;
        hadMatcher = true;

        final survivors = values
            .where((value) => _isResolvableGeoToken(
                  value?.toString().trim().toLowerCase() ?? '',
                ))
            .toList();

        if (survivors.isEmpty) {
          next.remove(key);
        } else {
          next[key] = survivors;
          lostEveryMatcher = false;
        }
      }

      // A rule that only ever matched on geo data now matches everything, which
      // would hijack all traffic. Drop it rather than let it widen.
      if (hadMatcher && lostEveryMatcher) continue;
      kept.add(next);
    }

    return kept;
  }

  /// Strips unresolvable geo references from an imported `dns` block.
  ///
  /// This is a separate walk from [_stripUnresolvableGeoRules] because Xray
  /// builds DNS before routing and fails there first: a config carrying
  /// `geosite:category-ru` under `dns.servers[].domains` dies with
  /// "failed to build DNS configuration", never reaching the routing rules.
  static Map<String, dynamic> _stripUnresolvableGeoDns(
    Map<String, dynamic> dns,
  ) {
    final servers = dns['servers'];
    if (servers is! List) return dns;

    final kept = <dynamic>[];
    for (final server in servers) {
      // Plain string entries ("1.1.1.1") carry no geo references.
      if (server is! Map) {
        kept.add(server);
        continue;
      }

      final next = Map<String, dynamic>.from(server);
      var droppedEveryDomain = false;

      for (final key in const ['domains', 'expectIPs', 'expectIps']) {
        final values = next[key];
        if (values is! List) continue;

        final survivors = values
            .where((value) => _isResolvableGeoToken(
                  value?.toString().trim().toLowerCase() ?? '',
                ))
            .toList();

        if (survivors.length == values.length) continue;
        if (survivors.isEmpty) {
          next.remove(key);
          // A server scoped to a domain list becomes a catch-all once that list
          // is gone, which would silently take over all name resolution.
          if (key == 'domains') droppedEveryDomain = true;
        } else {
          next[key] = survivors;
        }
      }

      if (droppedEveryDomain) continue;
      kept.add(next);
    }

    // Never hand the core an empty server list — it would have no resolver.
    if (kept.isEmpty) {
      return <String, dynamic>{
        ...dns,
        'servers': List<String>.from(_fallbackDnsServers),
      };
    }

    return <String, dynamic>{...dns, 'servers': kept};
  }

  static Map<String, dynamic> _resolveImportedDns(
    Map<String, dynamic> imported,
    ServerConfig server,
  ) {
    final importedDns = _normalizeMap(imported['dns']);
    if (importedDns != null) {
      return _stripUnresolvableGeoDns(importedDns);
    }

    return <String, dynamic>{'servers': _resolveDnsServers(server)};
  }

  static List<Map<String, dynamic>> _ensureDirectAndBlockOutbounds(
    List<Map<String, dynamic>> outbounds, {
    bool bindPhysicalInterface = false,
  }) {
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

    if (bindPhysicalInterface) {
      for (final outbound in next) {
        if (!_dialsPhysicalNetwork(outbound)) continue;
        outbound.putIfAbsent(
          'sendThrough',
          () => _physicalInterfacePlaceholder,
        );
      }
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
    bool hijackDns = false,
  }) {
    final rules = <Map<String, dynamic>>[
      if (hijackDns) _dnsHijackRule(),
      if (statsApi) _statsApiRoutingRule(),
      // The server and LAN rules come first: a server could legitimately sit on
      // one of the ports the noise rules blackhole, and a LAN host has to stay
      // reachable over NetBIOS or mDNS.
      if (tunnelMode) ..._buildJsonTunnelServerDirectRules(outbounds),
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
      if (tunnelMode) ..._broadcastBlockRules(),
      if (enableRuRouting) ..._buildRuDirectRoutingRules(),
      ..._stripUnresolvableGeoRules(importedRules),
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

  /// Outbounds that open their own sockets on the network. One chained through
  /// another outbound (`dialerProxy` / `proxySettings`) leaves the machine
  /// through that outbound instead, so there is nothing to bind.
  static bool _dialsPhysicalNetwork(Map<String, dynamic> outbound) {
    final protocol = outbound['protocol']?.toString().trim().toLowerCase();
    if (protocol != 'freedom' && !_isProxyOutbound(outbound)) return false;
    final proxySettings = _normalizeMap(outbound['proxySettings']);
    if ((proxySettings?['tag']?.toString() ?? '').isNotEmpty) return false;
    final sockopt =
        _normalizeMap(_normalizeMap(outbound['streamSettings'])?['sockopt']);
    return (sockopt?['dialerProxy']?.toString() ?? '').isEmpty;
  }

  static bool _isProxyOutboundWithEndpoint(Map<String, dynamic> outbound) {
    return _isProxyOutbound(outbound) &&
        _extractJsonOutboundTarget(outbound) != null;
  }
}
