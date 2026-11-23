import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

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
      final expanded = expandRandTemplate(value);
      return ClientAuthEndpoint(id: expanded, url: expanded, type: 'worker', priority: 100, capabilities: const ['api']);
    }
    if (value is! Map) return const ClientAuthEndpoint.empty();
    final json = Map<String, dynamic>.from(value);
    final rawUrl = json['url']?.toString() ?? '';
    final normalizedUrl = _normalizeUrl(expandRandTemplate(rawUrl));
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

  /// 展开面板下发的 `[randN]` 随机子域模板。
  ///
  /// 面板端 `Helper::replaceByPattern` 会把 `[rand9].kuaify.cc.cd` 展开为
  /// `ab12cd34e.kuaify.cc.cd` 之类的随机子域（抗封锁）。客户端在解析
  /// `auth_endpoints` 时也要能识别并展开同样的模板，否则拿到的是
  /// 字面量 `[rand9].kuaify.cc.cd`——无法解析、无法连接。
  ///
  /// 规则：`[randN]` → N 位小写字母+数字随机串（N 取 1~32）。
  /// 整个 URL 中出现多次时各自独立展开。展开结果不含 `[`/`]`。
  static String expandRandTemplate(String url) {
    if (!url.contains('[rand')) return url;
    final rand = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return url.replaceAllMapped(RegExp(r'\[rand(\d{1,2})\]'), (match) {
      final length = int.tryParse(match.group(1) ?? '') ?? 8;
      final n = length.clamp(1, 32);
      return String.fromCharCodes(
        List.generate(n, (_) => alphabet.codeUnitAt(rand.nextInt(alphabet.length))),
      );
    });
  }

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
        final host = KuaifyOrigin.normalizePattern(entry.key.toString());
        final addresses = KuaifyOrigin.normalizeAddresses(entry.value);
        // 别的品牌的 origin 记录（kuaifei.top / kuaity.top / kuaifei.cc.cd …）一律不收，
        // 否则客户端可能拿它去拨号，把请求送到 216 / 192。
        if (host == null || addresses.isEmpty || KuaifyOrigin.isForeignBrandHost(host)) continue;
        records[host] = addresses;
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
        if (!parsed.isUsable) continue;
        // 只接受本品牌域名的端点。跨品牌端点（216 下发的 kuaify.top / kuaifj.top /
        // kuaifei.cc.cd / xz.kuaity.top）会把登录和订阅带到错误的面板。
        final host = Uri.tryParse(parsed.url)?.host ?? '';
        if (!KuaifyOrigin.isBrandHost(host)) continue;
        authEndpoints.add(parsed);
      }
    }
    authEndpoints.sort((left, right) => left.priority.compareTo(right.priority));

    final frozenRecords = <String, List<String>>{};
    for (final entry in records.entries) {
      frozenRecords[entry.key] = List<String>.unmodifiable(entry.value);
    }

    return OriginDnsConfig(
      source: KuaifyOrigin.normalizeHost(json['source']?.toString() ?? '') ?? '',
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

class KuaifyOrigin {
  const KuaifyOrigin._();

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

  static const preferenceKey = 'origin_dns_last_known_good_v2';
  static const endpointPoolPreferenceKey = 'auth_endpoint_pool_v2';
  static const lastKnownGoodEndpointPreferenceKey = 'auth_last_known_good_endpoint_v2';
  static OriginDnsConfig _config = const OriginDnsConfig.empty();

  /// 属于本品牌的域名后缀。服务端下发的端点只要不在此列一律丢弃。
  ///
  /// 这条白名单是「登录被带到别的品牌面板」的最终兜底：216（kuaifei 线）会把
  /// kuaify.top / kuaifj.top / kuaifei.cc.cd / xz.kuaity.top 当成自己的端点下发，
  /// 只按优先级排序的话客户端就会挑到 216。
  static const List<String> brandDomainSuffixes = ['kuaify.cc.cd', 'tkyayun.cc.cd', 'tkya.us.ci'];

  /// 其它品牌的域名（216 / 192 的站点与分发域），出现在 origin 记录里直接丢弃。
  static const List<String> foreignBrandDomainSuffixes = [
    'kuaifei.top',
    'kuaity.top',
    'kuaifei.cc.cd',
    'tkya.cc.cd',
    'kuaify.top',
    'kuaifj.top',
  ];

  static bool isBrandHost(String host) {
    final value = host.trim().toLowerCase();
    if (value.isEmpty) return false;
    for (final suffix in brandDomainSuffixes) {
      if (value == suffix || value.endsWith('.$suffix')) return true;
    }
    return false;
  }

  static bool isForeignBrandHost(String host) {
    final value = host.trim().toLowerCase();
    if (value.isEmpty) return false;
    for (final suffix in foreignBrandDomainSuffixes) {
      if (value == suffix || value.endsWith('.$suffix')) return true;
    }
    return false;
  }

  static const Map<String, List<String>> githubBootstrapRecords = {
    'github.com': ['20.29.134.23'],
    'api.github.com': ['140.82.116.5'],
    'raw.githubusercontent.com': ['185.199.108.133', '185.199.109.133', '185.199.110.133', '185.199.111.133'],
  };

  static const List<String> cloudflareEdgeFallbackAddresses = ['172.67.163.238', '104.21.50.151'];

  // These are Cloudflare edge addresses, not the origin server. The original URI
  // host remains in use for TLS SNI and the HTTP Host header.
  // 2026-11-24: xz.kuaity.top → xz.kuaify.cc.cd（107 kuaify 线自有分发域）。
  static const Map<String, List<String>> distributionBootstrapRecords = {
    'xz.kuaify.cc.cd': cloudflareEdgeFallbackAddresses,
    '*.kuaify.cc.cd': cloudflareEdgeFallbackAddresses,
  };

  // The primary panel domain must remain reachable even if DNS, Cloudflare,
  // or a cached origin-dns record is unavailable. Keep the original URI host for
  // TLS SNI and HTTP Host while dialing these fixed Cloudflare edge addresses.
  static const Map<String, List<String>> builtinFallbackRecords = {
    'www.kuaify.cc.cd': ['104.21.84.66', '172.67.187.171'],
    'kuaify.cc.cd': ['104.21.84.66', '172.67.187.171'],
    // 订阅链接走服务端随机子域 `https://[rand9].tkyayun.cc.cd/vip/<token>`，
    // 这一条之前没有任何托底记录：DNS 被污染时整条订阅链路直接失败
    // （表现为「订阅下载失败」，只能等系统 DNS 恢复）。
    // 下面是 tkyayun.cc.cd 这个 zone 的 Cloudflare 边缘 IP（2026-10-22 DoH 实测：
    // `dig +short tkyayun.cc.cd @1.1.1.1` → 172.67.179.226 / 104.21.35.212）。
    // 通配符条目由 _match() 匹配任意 `<label>.tkyayun.cc.cd`。
    'tkyayun.cc.cd': ['172.67.179.226', '104.21.35.212'],
    '*.tkyayun.cc.cd': ['172.67.179.226', '104.21.35.212'],
    // 备用登录入口（同一面板的伪装域名），CF 边缘与面板主域名不同，
    // 主域名整域被墙时仍有一条独立通路。
    'by.tkya.us.ci': ['172.67.147.95', '104.21.41.132'],
  };

  static const List<String> protectedPanelBaseDomains = [];
  static const List<String> relayFirstPanelBaseDomains = [];

  static OriginDnsConfig get config => _config;

  static void restore(SharedPreferences preferences) {
    _restoreAuthResolved(preferences);
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final restored = OriginDnsConfig.fromJson(jsonDecode(raw));
      if (restored.isUsable) _config = restored;
    } catch (_) {
      // A malformed cache is ignored and replaced after the next successful sync.
    }
  }

  // ── auth_resolved_endpoints_v1 ──────────────────────────────────────────
  // 登录 / 获取订阅成功后，把「域名 → 实际连接 IP」实录下来。
  // 下次即使 DNS 被污染，也能直接用上次成功的 IP 连接（SNI / Host 头不变）。
  // 30 天过期自动清理。写入前调用方应确认连接已验证（HTTP 200）。

  static const authResolvedPreferenceKey = 'auth_resolved_endpoints_v1';
  static const _authResolvedTtl = Duration(days: 30);
  static Map<String, _AuthResolvedEntry> _authResolved = {};

  static void _restoreAuthResolved(SharedPreferences preferences) {
    final raw = preferences.getString(authResolvedPreferenceKey);
    if (raw == null || raw.isEmpty) {
      _authResolved = {};
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _authResolved = {};
        return;
      }
      final now = DateTime.now();
      final restored = <String, _AuthResolvedEntry>{};
      for (final entry in decoded.entries) {
        final host = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;
        final ip = value['ip']?.toString() ?? '';
        final ts = value['ts'] is num ? (value['ts'] as num).toInt() : 0;
        if (ip.isEmpty || ts <= 0) continue;
        final recordedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        if (now.difference(recordedAt) > _authResolvedTtl) continue;
        restored[host] = _AuthResolvedEntry(ip: ip, recordedAt: recordedAt);
      }
      _authResolved = restored;
    } catch (_) {
      _authResolved = {};
    }
  }

  /// 记录一次成功的「域名 → IP」连接实录。调用时机：登录成功 / getSubscribe 成功。
  /// [ip] 是实际建立 TCP 连接的远端 IP（非 DNS 解析结果，而是 Socket 远端地址）。
  static Future<void> recordAuthResolvedEndpoint(
    SharedPreferences preferences,
    String host,
    String ip,
  ) async {
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null || ip.trim().isEmpty) return;
    final trimmedIp = ip.trim();
    // 只接受合法 IPv4 / IPv6 字面量
    if (InternetAddress.tryParse(trimmedIp) == null) return;
    _authResolved[normalizedHost] = _AuthResolvedEntry(ip: trimmedIp, recordedAt: DateTime.now());
    await _persistAuthResolved(preferences);
  }

  static Future<void> _persistAuthResolved(SharedPreferences preferences) async {
    final map = <String, dynamic>{};
    for (final entry in _authResolved.entries) {
      map[entry.key] = {'ip': entry.value.ip, 'ts': entry.value.recordedAt.millisecondsSinceEpoch};
    }
    await preferences.setString(authResolvedPreferenceKey, jsonEncode(map));
  }

  /// 返回 [host] 上次成功连接的 IP（若有且未过期），否则返回 null。
  static String? authResolvedIpForHost(String host) {
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return null;
    final entry = _authResolved[normalizedHost];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.recordedAt) > _authResolvedTtl) {
      _authResolved.remove(normalizedHost);
      return null;
    }
    return entry.ip;
  }

  static Future<bool> replace(SharedPreferences preferences, OriginDnsConfig next, {bool onlyIfNewer = false}) async {
    if (!next.isUsable) return false;
    if (next.revision < _config.revision) return false;
    if (next.revision == _config.revision) {
      if (_canonicalJson(next.toJson()) == _canonicalJson(_config.toJson())) return false;
      throw OriginDnsRevisionCollision(next.revision);
    }

    final encoded = jsonEncode(next.toJson());
    if (!await preferences.setString(preferenceKey, encoded)) return false;
    // 落盘前再过滤一次：只保留本品牌域名的端点，杜绝跨品牌端点被缓存复用。
    final brandEndpoints = next.authEndpoints
        .where((endpoint) => isBrandHost(Uri.tryParse(endpoint.url)?.host ?? ''))
        .toList(growable: false);
    await preferences.setString(
      endpointPoolPreferenceKey,
      jsonEncode(brandEndpoints.map((endpoint) => endpoint.toJson()).toList(growable: false)),
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

  static List<String> addressesForHost(String host) {
    final normalizedHost = normalizeHost(host);
    // 登录/连接成功实录最优先：这是本机**实际用过且成功**的 IP，
    // 比探测结果更可信，且 DNS 被污染时它是唯一可用线索。
    if (normalizedHost != null) {
      final authResolved = _authResolved[normalizedHost];
      if (authResolved != null && DateTime.now().difference(authResolved.recordedAt) <= _authResolvedTtl) {
        return [authResolved.ip];
      }
    }
    // The fixed primary-origin route intentionally wins over remotely supplied
    // records, preventing a stale cache from routing the panel back to an
    // unreachable Cloudflare edge.
    final builtin = _match(builtinFallbackRecords, host);
    if (builtin.isNotEmpty) return builtin;
    return _match(_config.records, host);
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
    final configured = addressesForHost(host);
    if (configured.isNotEmpty) return configured;
    final normalizedHost = normalizeHost(host);
    if (normalizedHost == null) return const [];
    final distribution = distributionBootstrapRecords[normalizedHost];
    if (distribution != null) return distribution;
    return githubBootstrapRecords[normalizedHost] ?? const [];
  }

  static Map<String, List<String>> exportCoreRecords() {
    final records = <String, List<String>>{};
    for (final entry in _config.records.entries) {
      records[entry.key] = List<String>.unmodifiable(entry.value);
    }
    // Apply built-in records last so hiddify-core follows the same fixed-source
    // precedence as the Dart HTTP clients.
    for (final entry in builtinFallbackRecords.entries) {
      records[entry.key] = List<String>.unmodifiable(entry.value);
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

/// 登录/连接成功实录条目：host → 实际连接 IP + 时间戳。
class _AuthResolvedEntry {
  const _AuthResolvedEntry({required this.ip, required this.recordedAt});
  final String ip;
  final DateTime recordedAt;
}
