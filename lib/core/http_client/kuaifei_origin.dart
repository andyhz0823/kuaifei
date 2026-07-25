import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class OriginDnsConfig {
  const OriginDnsConfig({
    required this.source,
    required this.revision,
    required this.refreshInterval,
    required this.records,
  });

  final String source;
  final int revision;
  final Duration refreshInterval;
  final Map<String, List<String>> records;

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
        if (host != null && addresses.isNotEmpty) records[host] = addresses;
      }
    }

    final revision = switch (json['revision']) {
      int value => value,
      num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 0,
    };
    final refreshSeconds = switch (json['refresh_interval']) {
      int value => value,
      num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 900,
    };

    return OriginDnsConfig(
      source: KuaifeiOrigin.normalizeHost(json['source']?.toString() ?? '') ?? '',
      revision: revision,
      refreshInterval: Duration(seconds: refreshSeconds.clamp(300, 86400)),
      records: Map.unmodifiable(records.map((key, value) => MapEntry(key, List.unmodifiable(value)))),
    );
  }

  const OriginDnsConfig.empty()
    : source = '',
      revision = 0,
      refreshInterval = const Duration(minutes: 15),
      records = const {};

  Map<String, dynamic> toJson() => {
    'source': source,
    'revision': revision,
    'refresh_interval': refreshInterval.inSeconds,
    'records': records,
  };
}

class KuaifeiOrigin {
  const KuaifeiOrigin._();

  static const preferenceKey = 'origin_dns_last_known_good_v1';
  static OriginDnsConfig _config = const OriginDnsConfig.empty();

  static const Map<String, List<String>> githubBootstrapRecords = {
    'github.com': ['20.29.134.23'],
    'api.github.com': ['140.82.116.5'],
    'raw.githubusercontent.com': ['185.199.108.133', '185.199.109.133', '185.199.110.133', '185.199.111.133'],
  };

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
    if (onlyIfNewer && next.revision <= _config.revision) return false;

    final encoded = jsonEncode(next.toJson());
    if (!await preferences.setString(preferenceKey, encoded)) return false;
    _config = next;
    return true;
  }

  static List<String> addressesForHost(String host) => _match(_config.records, host);

  static List<String> connectionAddressesForHost(String host) {
    final configured = addressesForHost(host);
    if (configured.isNotEmpty) return configured;
    return githubBootstrapRecords[normalizeHost(host)] ?? const [];
  }

  static Map<String, List<String>> exportCoreRecords() => _config.records;

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
    final normalized = value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (normalized.isEmpty || normalized.contains('*')) return null;
    if (InternetAddress.tryParse(normalized) != null) return null;
    final labels = normalized.split('.');
    if (labels.length < 2 || labels.any((label) => label.isEmpty || label.length > 63)) return null;
    final validLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$');
    if (labels.any((label) => !validLabel.hasMatch(label))) return null;
    return normalized;
  }

  static List<String> normalizeAddresses(dynamic value) {
    final values = switch (value) {
      String string => string.split(RegExp(r'[\s,]+')),
      List list => list.map((item) => item.toString()),
      _ => const <String>[],
    };
    final addresses = <String>{};
    for (final item in values) {
      final address = item.trim();
      if (InternetAddress.tryParse(address) != null) addresses.add(address);
    }
    return addresses.toList(growable: false);
  }
}
