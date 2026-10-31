import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/http_client/edge_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单个域名下边缘 IP 的健康记录：首选 IP + 当前处于冷却期的封锁 IP。
class _EdgeIpState {
  _EdgeIpState();

  String? good;
  final Map<String, DateTime> blocked = <String, DateTime>{};

  bool get isEmpty => good == null && blocked.isEmpty;

  factory _EdgeIpState.fromJson(dynamic value) {
    final state = _EdgeIpState();
    if (value is! Map) return state;
    final good = value['good'];
    if (good is String && InternetAddress.tryParse(good) != null) state.good = good;
    final blocked = value['blocked'];
    if (blocked is Map) {
      for (final entry in blocked.entries) {
        final address = entry.key.toString();
        if (InternetAddress.tryParse(address) == null) continue;
        final until = DateTime.tryParse(entry.value.toString());
        if (until != null) state.blocked[address] = until;
      }
    }
    return state;
  }

  Map<String, dynamic> toJson() => {
    if (good != null) 'good': good,
    'blocked': {for (final entry in blocked.entries) entry.key: entry.value.toIso8601String()},
  };
}

class ClientAuthEndpoint {
  const ClientAuthEndpoint({
    required this.id,
    required this.url,
    required this.type,
    required this.priority,
    required this.capabilities,
    this.routeId,
  });

  final String id;
  final String url;
  final String type;
  final int priority;
  final List<String> capabilities;
  final String? routeId;

  bool get supportsApi => capabilities.contains('api');
  bool get supportsSubscription => capabilities.contains('subscription');

  factory ClientAuthEndpoint.fromJson(dynamic value) {
    if (value is String) {
      return ClientAuthEndpoint(id: value, url: value, type: 'worker', priority: 100, capabilities: const ['api']);
    }
    if (value is! Map) return const ClientAuthEndpoint.empty();
    final json = Map<String, dynamic>.from(value);
    final normalizedUrl = _normalizeUrl(json['url']?.toString() ?? '');
    final rawCapabilities = json['capabilities'];
    // JSON decoding produces List<dynamic>. Build a typed list explicitly so
    // List<String>.unmodifiable never performs an unsafe runtime cast.
    final List<String> capabilities;
    if (rawCapabilities is Iterable) {
      capabilities = <String>{
        for (final item in rawCapabilities)
          if (item is String && item.trim().isNotEmpty) item.trim().toLowerCase(),
      }.toList(growable: false);
    } else {
      capabilities = const <String>['api'];
    }
    final rawPriority = json['priority'];
    final priority = rawPriority is num ? rawPriority.toInt() : int.tryParse(rawPriority?.toString() ?? '') ?? 100;
    final type = json['type']?.toString().trim().toLowerCase() ?? 'worker';
    final host = Uri.tryParse(normalizedUrl)?.host ?? '';
    final id = json['id']?.toString().trim() ?? '';
    return ClientAuthEndpoint(
      id: id.isEmpty ? host : id,
      url: normalizedUrl,
      type: const {'worker', 'relay', 'panel'}.contains(type) ? type : 'worker',
      priority: priority.clamp(0, 10000),
      capabilities: List<String>.unmodifiable(capabilities),
      routeId: json['route_id']?.toString().trim().isNotEmpty == true ? json['route_id'].toString().trim() : null,
    );
  }

  const ClientAuthEndpoint.empty()
    : id = '',
      url = '',
      type = 'worker',
      priority = 100,
      capabilities = const [],
      routeId = null;

  bool get isUsable {
    final uri = Uri.tryParse(url);
    return id.isNotEmpty && uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && supportsApi;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'type': type,
    'route_id': routeId,
    'priority': priority,
    'enabled': true,
    'capabilities': capabilities,
  };

  static String _normalizeUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) return '';
    return uri
        .replace(scheme: 'https', host: uri.host.toLowerCase(), path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
        .toString();
  }
}

class OriginDnsRevisionCollision implements Exception {
  const OriginDnsRevisionCollision(this.revision);

  final int revision;

  @override
  String toString() => 'Origin DNS revision collision at $revision';
}

class OriginDnsConfig {
  const OriginDnsConfig({
    required this.source,
    required this.revision,
    required this.refreshInterval,
    required this.bootstrapRefreshInterval,
    required this.records,
    required this.authEndpoints,
  });

  final String source;
  final int revision;
  final Duration refreshInterval;
  final Duration bootstrapRefreshInterval;
  final Map<String, List<String>> records;
  final List<ClientAuthEndpoint> authEndpoints;

  bool get isUsable => revision > 0 && records.isNotEmpty;

  factory OriginDnsConfig.fromJson(dynamic value) {
    if (value is! Map) return const OriginDnsConfig.empty();
    final json = Map<String, dynamic>.from(value);
    final records = <String, List<String>>{};
    final rawRecords = json['records'];
    if (rawRecords is Map) {
      for (final entry in rawRecords.entries) {
        final host = TkyaOrigin.normalizePattern(entry.key.toString());
        final addresses = TkyaOrigin.normalizeAddresses(entry.value);
        if (host != null && addresses.isNotEmpty) records[host] = addresses;
      }
    }

    final revision = switch (json['revision']) {
      final int value => value,
      final num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 0,
    };
    final refreshSeconds = switch (json['refresh_interval']) {
      final int value => value,
      final num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 900,
    };
    final bootstrapRefreshSeconds = switch (json['bootstrap_refresh_interval']) {
      final int value => value,
      final num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 21600,
    };
    // Do not retain a raw List<dynamic> from JSON. This config is consumed
    // while logging in, so malformed or mixed endpoint metadata must be ignored
    // rather than surfacing as a List<dynamic> -> List<String> cast exception.
    final authEndpoints = <ClientAuthEndpoint>[];
    final rawAuthEndpoints = json['auth_endpoints'];
    if (rawAuthEndpoints is Iterable) {
      for (final endpoint in rawAuthEndpoints) {
        final parsed = ClientAuthEndpoint.fromJson(endpoint);
        if (parsed.isUsable) authEndpoints.add(parsed);
      }
    }
    authEndpoints.sort((left, right) => left.priority.compareTo(right.priority));

    final frozenRecords = <String, List<String>>{};
    for (final entry in records.entries) {
      frozenRecords[entry.key] = List<String>.unmodifiable(entry.value);
    }

    return OriginDnsConfig(
      source: TkyaOrigin.normalizeHost(json['source']?.toString() ?? '') ?? '',
      revision: revision,
      refreshInterval: Duration(seconds: refreshSeconds.clamp(300, 86400)),
      bootstrapRefreshInterval: Duration(seconds: bootstrapRefreshSeconds.clamp(900, 86400)),
      records: Map<String, List<String>>.unmodifiable(frozenRecords),
      authEndpoints: List<ClientAuthEndpoint>.unmodifiable(authEndpoints),
    );
  }

  const OriginDnsConfig.empty()
    : source = '',
      revision = 0,
      refreshInterval = const Duration(minutes: 15),
      bootstrapRefreshInterval = const Duration(hours: 6),
      records = const {},
      authEndpoints = const [];

  Map<String, dynamic> toJson() => {
    'source': source,
    'revision': revision,
    'refresh_interval': refreshInterval.inSeconds,
    'bootstrap_refresh_interval': bootstrapRefreshInterval.inSeconds,
    'records': records,
    'auth_endpoints': authEndpoints.map((endpoint) => endpoint.toJson()).toList(growable: false),
  };
}

class TkyaOrigin {
  const TkyaOrigin._();

  static const _cloudflareOriginCaRsa = '''
-----BEGIN CERTIFICATE-----
MIIEADCCAuigAwIBAgIID+rOSdTGfGcwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNV
BAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91
ZEZsYXJlIE9yaWdpbiBTU0wgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQH
Ew1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlhMB4XDTE5MDgyMzIx
MDgwMFoXDTI5MDgxNTE3MDAwMFowgYsxCzAJBgNVBAYTAlVTMRkwFwYDVQQKExBD
bG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91ZEZsYXJlIE9yaWdpbiBTU0wg
Q2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQHEw1TYW4gRnJhbmNpc2NvMRMw
EQYDVQQIEwpDYWxpZm9ybmlhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
AQEAwEiVZ/UoQpHmFsHvk5isBxRehukP8DG9JhFev3WZtG76WoTthvLJFRKFCHXm
V6Z5/66Z4S09mgsUuFwvJzMnE6Ej6yIsYNCb9r9QORa8BdhrkNn6kdTly3mdnykb
OomnwbUfLlExVgNdlP0XoRoeMwbQ4598foiHblO2B/LKuNfJzAMfS7oZe34b+vLB
yrP/1bgCSLdc1AxQc1AC0EsQQhgcyTJNgnG4va1c7ogPlwKyhbDyZ4e59N5lbYPJ
SmXI/cAe3jXj1FBLJZkwnoDKe0v13xeF+nF32smSH0qB7aJX2tBMW4TWtFPmzs5I
lwrFSySWAdwYdgxw180yKU0dvwIDAQABo2YwZDAOBgNVHQ8BAf8EBAMCAQYwEgYD
VR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUJOhTV118NECHqeuU27rhFnj8KaQw
HwYDVR0jBBgwFoAUJOhTV118NECHqeuU27rhFnj8KaQwDQYJKoZIhvcNAQELBQAD
ggEBAHwOf9Ur1l0Ar5vFE6PNrZWrDfQIMyEfdgSKofCdTckbqXNTiXdgbHs+TWoQ
wAB0pfJDAHJDXOTCWRyTeXOseeOi5Btj5CnEuw3P0oXqdqevM1/+uWp0CM35zgZ8
VD4aITxity0djzE6Qnx3Syzz+ZkoBgTnNum7d9A66/V636x4vTeqbZFBr9erJzgz
hhurjcoacvRNhnjtDRM0dPeiCJ50CP3wEYuvUzDHUaowOsnLCjQIkWbR7Ni6KEIk
MOz2U0OBSif3FTkhCgZWQKOOLo1P42jHC3ssUZAtVNXrCk3fw9/E15k8NPkBazZ6
0iykLhH1trywrKRMVw67F44IE8Y=
-----END CERTIFICATE-----
''';

  static final SecurityContext securityContext = _createSecurityContext();

  static SecurityContext _createSecurityContext() {
    final context = SecurityContext(withTrustedRoots: true);
    context.setTrustedCertificatesBytes(utf8.encode(_cloudflareOriginCaRsa));
    return context;
  }

  static const preferenceKey = 'origin_dns_last_known_good_v1';
  static const endpointPoolPreferenceKey = 'auth_endpoint_pool_v1';
  static const lastKnownGoodEndpointPreferenceKey = 'auth_last_known_good_endpoint_v1';
  // Per-host edge IP health: which address completed TLS last time, and which
  // ones were terminated. Persisted so the winning IP is tried first next boot.
  static const edgeIpStatePreferenceKey = 'origin_edge_ip_state_v1';
  static const edgeIpBlockCooldown = Duration(minutes: 30);
  static OriginDnsConfig _config = const OriginDnsConfig.empty();
  static SharedPreferences? _preferences;
  static final Map<String, _EdgeIpState> _edgeIpState = <String, _EdgeIpState>{};
  // 探测得到的「当前网络真正可用」的边缘 IP（按耗时升序），优先于写死列表。
  static Map<String, List<String>> _probedAddresses = const {};

  static const Map<String, List<String>> githubBootstrapRecords = {
    'github.com': ['20.29.134.23'],
    'api.github.com': ['140.82.116.5'],
    'raw.githubusercontent.com': ['185.199.108.133', '185.199.109.133', '185.199.110.133', '185.199.111.133'],
  };

  // Order is the retry order, so it encodes reachability from mainland
  // China. Measured on 2026-10-17: the 104.21.0.0/16 pair completed TLS 3/3
  // (~0.45s), 172.67.163.238 completed 1/3 (the other two were terminated
  // during the handshake), and 172.67.163.144 was black-holed. The blocked
  // addresses stay at the end so a future re-route can still reach them.
  //
  // 104.17.0.1 / 104.18.0.1 are extra anycast edges that also serve this zone
  // (verified 2026-10-31 with SNI www.tkya.cc.cd, HTTP 200). They exist because
  // the zone's own pair can be dropped wholesale by an ISP while a different
  // Cloudflare range still answers. Runtime success/failure is persisted per
  // host in [_edgeIpState], so the working address is tried first next time.
  static const List<String> cloudflareEdgeFallbackAddresses = [
    '104.21.50.151',
    '104.21.34.178',
    '104.17.0.1',
    '104.18.0.1',
    '172.67.163.238',
    '172.67.163.144',
  ];

  // These are Cloudflare edge addresses, not the origin server. The original URI
  // host remains in use for TLS SNI and the HTTP Host header.
  static const Map<String, List<String>> distributionBootstrapRecords = {
    'xz.tkya.cc.cd': cloudflareEdgeFallbackAddresses,
  };

  // Every panel host under the primary domain must stay reachable even if DNS
  // or a cached origin-dns record is unavailable. These are Cloudflare edge
  // addresses, not the origin server: the original URI host is still used for
  // TLS SNI and the HTTP Host header so Cloudflare routes back to the origin.
  // The apex and www are listed explicitly because a `*.tkya.cc.cd` wildcard
  // never matches the apex host itself, and the apex is what users type in.
  static const Map<String, List<String>> builtinFallbackRecords = {
    'tkya.cc.cd': cloudflareEdgeFallbackAddresses,
    'www.tkya.cc.cd': cloudflareEdgeFallbackAddresses,
    '*.tkya.cc.cd': cloudflareEdgeFallbackAddresses,
  };

  static const List<String> protectedPanelBaseDomains = [];
  static const List<String> relayFirstPanelBaseDomains = [];

  static OriginDnsConfig get config => _config;

  static void restore(SharedPreferences preferences) {
    _preferences = preferences;
    restoreEdgeIpState(preferences);
    _probedAddresses = EdgeProbe.readCache(preferences);
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final restored = OriginDnsConfig.fromJson(jsonDecode(raw));
      if (restored.isUsable) _config = restored;
    } catch (_) {
      // A malformed cache is ignored and replaced after the next successful sync.
    }
  }

  static Future<bool> replace(SharedPreferences preferences, OriginDnsConfig next, {bool onlyIfNewer = false}) async {
    _preferences = preferences;
    if (!next.isUsable) return false;
    if (next.revision < _config.revision) return false;
    if (next.revision == _config.revision) {
      if (_canonicalJson(next.toJson()) == _canonicalJson(_config.toJson())) return false;
      throw OriginDnsRevisionCollision(next.revision);
    }

    final encoded = jsonEncode(next.toJson());
    if (!await preferences.setString(preferenceKey, encoded)) return false;
    await preferences.setString(
      endpointPoolPreferenceKey,
      jsonEncode(next.authEndpoints.map((endpoint) => endpoint.toJson()).toList(growable: false)),
    );
    _config = next;
    return true;
  }

  static String _canonicalJson(dynamic value) {
    dynamic normalize(dynamic item) {
      if (item is Map) {
        final keys = item.keys.map((key) => key.toString()).toList()..sort();
        return <String, dynamic>{for (final key in keys) key: normalize(item[key])};
      }
      if (item is List) return item.map(normalize).toList(growable: false);
      return item;
    }

    return jsonEncode(normalize(value));
  }

  /// 恢复上次运行记录下来的边缘 IP 健康状态。
  ///
  /// 目的很具体：DNS 被污染时客户端只能靠写死的 CF 边缘 IP 登录，而哪些 IP 当
  /// 前可达会随封锁变化。登录成功后把「能完成 TLS 的那个 IP」记下来，下次启动
  /// 排到最前面，就不必每次从被墙的 IP 开始重试。
  static void restoreEdgeIpState(SharedPreferences preferences) {
    _preferences = preferences;
    _edgeIpState.clear();
    final raw = preferences.getString(edgeIpStatePreferenceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final host = normalizeHost(entry.key.toString());
        if (host == null) continue;
        final state = _EdgeIpState.fromJson(entry.value);
        if (!state.isEmpty) _edgeIpState[host] = state;
      }
    } catch (_) {
      // 缓存损坏就丢弃，下一次登录会重新学习。
    }
  }

  static String? lastGoodEdgeIpForHost(String host) {
    final key = normalizeHost(host);
    if (key == null) return null;
    return _edgeIpState[key]?.good;
  }

  static bool isEdgeIpBlocked(String host, String address) {
    final key = normalizeHost(host);
    if (key == null) return false;
    final state = _edgeIpState[key];
    final until = state?.blocked[address];
    if (until == null) return false;
    if (until.isAfter(DateTime.now())) return true;
    state!.blocked.remove(address);
    return false;
  }

  /// 某个边缘 IP 完成了 TLS：记录为首选，并解除它的封锁标记。
  static void recordEdgeIpSuccess(String host, String address) {
    final key = normalizeHost(host);
    if (key == null || address.isEmpty) return;
    final state = _edgeIpState.putIfAbsent(key, _EdgeIpState.new);
    final changed = state.good != address || state.blocked.remove(address) != null;
    state.good = address;
    if (changed) _persistEdgeIpState();
  }

  /// 某个边缘 IP 的 TCP/TLS 失败：若它正是首选则撤销，并按冷却期排到队尾。
  static void recordEdgeIpFailure(String host, String address) {
    final key = normalizeHost(host);
    if (key == null || address.isEmpty) return;
    final state = _edgeIpState.putIfAbsent(key, _EdgeIpState.new);
    if (state.good == address) state.good = null;
    state.blocked[address] = DateTime.now().add(edgeIpBlockCooldown);
    _persistEdgeIpState();
  }

  /// 登录成功后调用：清掉冷却已过期的封锁记录，只留下仍然有效的偏好。
  static void pruneEdgeIpState() {
    final now = DateTime.now();
    var changed = false;
    for (final state in _edgeIpState.values) {
      final expired = state.blocked.entries.where((entry) => !entry.value.isAfter(now)).map((entry) => entry.key).toList();
      for (final address in expired) {
        state.blocked.remove(address);
        changed = true;
      }
    }
    if (changed) _persistEdgeIpState();
  }

  /// 记录本轮探测结果：写缓存，并作为当前会话的首选地址。
  static Future<void> applyProbedAddresses(Map<String, List<String>> hosts) async {
    if (hosts.isEmpty) return;
    _probedAddresses = Map<String, List<String>>.unmodifiable(<String, List<String>>{..._probedAddresses, ...hosts});
    final preferences = _preferences;
    if (preferences != null) await EdgeProbe.writeCache(preferences, _probedAddresses);
  }

  static void _persistEdgeIpState() {
    final preferences = _preferences;
    if (preferences == null) return;
    final payload = <String, dynamic>{for (final entry in _edgeIpState.entries) entry.key: entry.value.toJson()};
    unawaited(preferences.setString(edgeIpStatePreferenceKey, jsonEncode(payload)));
  }

  /// 首选 IP → 未封锁 IP → 已封锁 IP，保持各自原有顺序。
  static List<String> _prioritizeEdgeAddresses(String host, List<String> addresses) {
    if (addresses.isEmpty) return addresses;
    final key = normalizeHost(host);
    if (key == null) return addresses;
    final state = _edgeIpState[key];
    if (state == null) return addresses;
    final good = state.good;
    final ordered = <String>[
      // 上次完成过 TLS 的地址永远排第一，即使它来自 DoH 而不在写死列表里。
      if (good != null) good,
      ...addresses.where((address) => address != good && !isEdgeIpBlocked(key, address)),
      ...addresses.where((address) => address != good && isEdgeIpBlocked(key, address)),
    ];
    return List<String>.unmodifiable(ordered);
  }

  static List<String> addressesForHost(String host) {
    // The pinned primary-domain route still wins over remotely supplied
    // records, so a stale cache can never route panel hosts somewhere
    // unreachable. It is no longer the only candidate, though: a single
    // blocked Cloudflare edge IP used to eliminate the whole host, so the
    // configured records are appended and raced as well.
    final builtin = _match(builtinFallbackRecords, host);
    if (builtin.isEmpty) return _match(_config.records, host);
    final configured = _match(_config.records, host);
    if (configured.isEmpty) return builtin;
    final merged = <String>[...builtin];
    for (final address in configured) {
      if (!merged.contains(address)) merged.add(address);
    }
    return merged;
  }

  static bool isProtectedPanelHost(String host) {
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return false;
    return protectedPanelBaseDomains.any((baseDomain) => _isHostAtOrBelow(normalizedHost, baseDomain));
  }

  static bool prefersRelayForPanelHost(String host) {
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return false;
    return relayFirstPanelBaseDomains.any((baseDomain) => _isHostAtOrBelow(normalizedHost, baseDomain));
  }

  static bool _isHostAtOrBelow(String host, String baseDomain) {
    return host == baseDomain || host.endsWith('.$baseDomain');
  }

  static List<String> connectionAddressesForHost(String host) {
    final normalizedHost = normalizeHost(host);
    final base = <String>[];
    final configured = addressesForHost(host);
    if (configured.isNotEmpty) {
      base.addAll(configured);
    } else if (normalizedHost != null) {
      final distribution = distributionBootstrapRecords[normalizedHost];
      final github = githubBootstrapRecords[normalizedHost];
      if (distribution != null) {
        base.addAll(distribution);
      } else if (github != null) {
        base.addAll(github);
      }
    }
    if (base.isEmpty) return List<String>.unmodifiable(_probedFor(normalizedHost));

    // 探测结果最优先：那是当前网络实测返回 200 且最快的地址；写死列表兜底。
    final merged = <String>[];
    for (final address in <String>[..._probedFor(normalizedHost), ...base]) {
      if (!merged.contains(address)) merged.add(address);
    }
    return _prioritizeEdgeAddresses(normalizedHost ?? host, merged);
  }

  static List<String> _probedFor(String? host) {
    if (host == null) return const [];
    return _probedAddresses[host] ?? const [];
  }

  static Map<String, List<String>> exportCoreRecords() {
    final records = <String, List<String>>{};
    for (final entry in _config.records.entries) {
      records[entry.key] = List<String>.unmodifiable(entry.value);
    }
    // Apply built-in records last so hiddify-core follows the same fixed-source
    // precedence as the Dart HTTP clients.
    for (final entry in builtinFallbackRecords.entries) {
      final probed = _probedFor(entry.key);
      final merged = <String>[...probed];
      for (final address in entry.value) {
        if (!merged.contains(address)) merged.add(address);
      }
      records[entry.key] = List<String>.unmodifiable(_prioritizeEdgeAddresses(entry.key, merged));
    }
    return Map<String, List<String>>.unmodifiable(records);
  }

  static List<String> _match(Map<String, List<String>> records, String host) {
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return const [];

    final exact = records[normalizedHost];
    if (exact != null) return exact;

    MapEntry<String, List<String>>? best;
    for (final entry in records.entries) {
      final pattern = entry.key;
      if (!pattern.startsWith('*.')) continue;
      final suffix = pattern.substring(1);
      if (!normalizedHost.endsWith(suffix) || normalizedHost.length <= suffix.length) continue;
      if (best == null || pattern.length > best.key.length) best = entry;
    }
    return best?.value ?? const [];
  }

  static String? normalizePattern(String value) {
    final normalized = value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (normalized.startsWith('*.')) {
      final domain = normalizeHost(normalized.substring(2));
      return domain == null ? null : '*.$domain';
    }
    if (normalized.contains('*')) return null;
    return normalizeHost(normalized);
  }

  static String? normalizeHost(String value) {
    var normalized = value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) return null;

    if (normalized.contains('://')) {
      final parsed = Uri.tryParse(normalized);
      if (parsed?.host.isNotEmpty == true) {
        normalized = parsed!.host.toLowerCase();
      }
    }

    if (normalized.startsWith('*.')) {
      return normalizeHost(normalized.substring(2));
    }

    if (normalized.startsWith('[') && normalized.contains(']')) {
      final closing = normalized.indexOf(']');
      if (closing > 0) {
        normalized = normalized.substring(1, closing);
      }
    }

    if (normalized.contains('*')) return null;

    if (InternetAddress.tryParse(normalized) != null) return null;

    if (normalized.contains('/')) {
      final parsed = Uri.tryParse(normalized.contains('://') ? normalized : 'https://$normalized');
      if (parsed?.host.isNotEmpty == true) {
        normalized = parsed!.host.toLowerCase();
      }
    }

    if (normalized.contains(':')) {
      final parsed = Uri.tryParse('https://$normalized');
      if (parsed?.host.isNotEmpty == true) {
        normalized = parsed!.host.toLowerCase();
      }
    }

    normalized = normalized.replaceFirst(RegExp(r'\.$'), '');
    if (normalized.isEmpty || normalized.contains('*')) return null;
    if (InternetAddress.tryParse(normalized) != null) return null;

    final labels = normalized.split('.');
    if (labels.length < 2 || labels.any((label) => label.isEmpty || label.length > 63)) return null;
    final validLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$');
    if (labels.any((label) => !validLabel.hasMatch(label))) return null;
    return normalized;
  }

  static List<String> normalizeAddresses(dynamic value) {
    final List<String> values;
    if (value is String) {
      values = value.split(RegExp(r'[\s,]+'));
    } else if (value is Iterable) {
      values = value.map((item) => item.toString()).toList(growable: false);
    } else {
      values = const <String>[];
    }

    final addresses = <String>{};
    for (final item in values) {
      final address = item.trim();
      if (InternetAddress.tryParse(address) != null) addresses.add(address);
    }
    return addresses.toList(growable: false);
  }
}
