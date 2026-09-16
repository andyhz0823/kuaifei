import 'dart:convert';
import 'dart:io';

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
  static OriginDnsConfig _config = const OriginDnsConfig.empty();

  static const Map<String, List<String>> githubBootstrapRecords = {
    'github.com': ['20.29.134.23'],
    'api.github.com': ['140.82.116.5'],
    'raw.githubusercontent.com': ['185.199.108.133', '185.199.109.133', '185.199.110.133', '185.199.111.133'],
  };

  static const List<String> cloudflareEdgeFallbackAddresses = ['172.67.163.238', '104.21.50.151'];

  // These are Cloudflare edge addresses, not the origin server. The original URI
  // host remains in use for TLS SNI and the HTTP Host header.
  static const Map<String, List<String>> distributionBootstrapRecords = {
    'xz.tkya.cc.cd': cloudflareEdgeFallbackAddresses,
  };

  // Every panel host under the primary domain must stay reachable even if DNS
  // or a cached origin-dns record is unavailable. These are Cloudflare edge
  // addresses, not the origin server: the original URI host is still used for
  // TLS SNI and the HTTP Host header so Cloudflare routes back to the origin.
  static const Map<String, List<String>> builtinFallbackRecords = {
    '*.tkya.cc.cd': cloudflareEdgeFallbackAddresses,
  };

  static const List<String> protectedPanelBaseDomains = [];
  static const List<String> relayFirstPanelBaseDomains = [];

  static OriginDnsConfig get config => _config;

  static void restore(SharedPreferences preferences) {
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

  static List<String> addressesForHost(String host) {
    // The pinned primary-domain route intentionally wins over remotely supplied
    // records, so a stale cache can never route panel hosts somewhere unreachable.
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
