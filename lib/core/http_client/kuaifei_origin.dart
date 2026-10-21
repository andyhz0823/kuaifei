import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/http_client/edge_probe.dart';
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
        final host = KuaifeiOrigin.normalizePattern(entry.key.toString());
        final addresses = KuaifeiOrigin.normalizeAddresses(entry.value);
        // 别的品牌的 origin 记录（kuaifei.top / kuaity.top / kuaifei.cc.cd …）一律不收，
        // 否则客户端可能拿它去拨号，把请求送到 216 / 192。
        if (host == null || addresses.isEmpty || KuaifeiOrigin.isForeignBrandHost(host)) continue;
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
        if (!KuaifeiOrigin.isBrandHost(host)) continue;
        authEndpoints.add(parsed);
      }
    }
    authEndpoints.sort((left, right) => left.priority.compareTo(right.priority));

    final frozenRecords = <String, List<String>>{};
    for (final entry in records.entries) {
      frozenRecords[entry.key] = List<String>.unmodifiable(entry.value);
    }

    return OriginDnsConfig(
      source: KuaifeiOrigin.normalizeHost(json['source']?.toString() ?? '') ?? '',
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

class KuaifeiOrigin {
  const KuaifeiOrigin._();

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

  /// 自动优选出来的 CF 边缘 IP（按当前网络握手延迟排序）。
  /// 非空时优先于写死的 [builtinFallbackRecords]。
  static List<String> _probedEdgeAddresses = const [];

  /// 属于本品牌的域名后缀。服务端下发的端点只要不在此列一律丢弃。
  ///
  /// 这条白名单是「登录被带到别的品牌面板」的最终兜底：216（kuaifei 线）会把
  /// kuaify.top / kuaifj.top / kuaifei.cc.cd / xz.kuaity.top 当成自己的端点下发，
  /// 只按优先级排序的话客户端就会挑到 216。
  static const List<String> brandDomainSuffixes = ['kuaify.cc.cd', 'tkyayun.cc.cd'];

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
  static const Map<String, List<String>> distributionBootstrapRecords = {
    'xz.kuaity.top': cloudflareEdgeFallbackAddresses,
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
  };

  static const List<String> protectedPanelBaseDomains = [];
  static const List<String> relayFirstPanelBaseDomains = [];

  static OriginDnsConfig get config => _config;

  static void restore(SharedPreferences preferences) {
    // 先恢复自动优选的边缘 IP：它比写死的两个更贴合当前网络。
    _probedEdgeAddresses = EdgeProbe.readCache(preferences);
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final restored = OriginDnsConfig.fromJson(jsonDecode(raw));
      if (restored.isUsable) _config = restored;
    } catch (_) {
      // A malformed cache is ignored and replaced after the next successful sync.
    }
  }

  /// 探测一批 CF 边缘 IP，挑当前网络最快的几个缓存起来（6 小时有效）。
  ///
  /// [sniHost] 用面板域名即可：CF 是 anycast + 按 SNI 路由，任意边缘 IP 都能
  /// 服务我们的 zone，所以同一组结果对订阅域名同样适用。
  static Future<void> refreshEdgeCache(SharedPreferences preferences, {required String sniHost}) async {
    try {
      final best = await EdgeProbe.probe(sniHost);
      if (best.isEmpty) return;
      _probedEdgeAddresses = best;
      await EdgeProbe.writeCache(preferences, best);
    } catch (_) {
      // 探测失败就继续用写死的兜底地址。
    }
  }

  static bool get hasProbedEdgeAddresses => _probedEdgeAddresses.isNotEmpty;

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
    // The fixed primary-origin route intentionally wins over remotely supplied
    // records, preventing a stale cache from routing the panel back to an
    // unreachable Cloudflare edge.
    final builtin = _match(builtinFallbackRecords, host);
    if (builtin.isNotEmpty) {
      // 自动优选结果优先：写死的两个边缘 IP 在某些网络下会被墙/绕路，
      // 探测出来的这组是当前网络握手最快的。
      if (_probedEdgeAddresses.isNotEmpty) return _probedEdgeAddresses;
      return builtin;
    }
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
