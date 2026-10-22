import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/front_door/model/front_door_candidate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 优选结果缓存。
///
/// 目的：订阅每 15 分钟就可能更新一次，若每次都重新测速，用户会在不知情的情况下
/// 反复消耗流量；缓存有效期内直接用上次结果建节点，后台再异步刷新。
///
/// 失效条件（任一）：
/// - 超过 [ttl]（6 小时，与 `EdgeProbe` 对齐）
/// - 网络指纹变化（换 Wi-Fi / 切蜂窝 / 换 IP）—— 换网后旧结果没有参考价值
class FrontDoorCache {
  const FrontDoorCache._();

  static const preferenceKey = 'front_door_cache_v1';
  static const ttl = Duration(hours: 6);

  /// 读缓存；无有效缓存返回空列表。
  static List<FrontDoorCandidate> read(SharedPreferences preferences, String cacheKey, {String? fingerprint}) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final targets = decoded['targets'];
      if (targets is! Map) return const [];
      final entry = targets[cacheKey];
      if (entry is! Map) return const [];
      final at = entry['at'];
      if (at is! num) return const [];
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      if (DateTime.now().difference(cachedAt) > ttl) return const [];
      if (fingerprint != null && entry['net'] is String && entry['net'] != fingerprint) return const [];
      final list = entry['cdns'];
      if (list is! List) return const [];
      final result = <FrontDoorCandidate>[];
      for (final item in list) {
        if (item is! Map) continue;
        final host = item['host']?.toString() ?? '';
        if (host.isEmpty) continue;
        final port = item['port'] is num ? (item['port'] as num).toInt() : 443;
        result.add(FrontDoorCandidate(host: host, port: port, remark: 'cache'));
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// 写入缓存（只保留最近 [maxTargets] 个目标，避免 prefs 无限膨胀）。
  static Future<void> write(
    SharedPreferences preferences,
    String cacheKey,
    List<ProbeResult> best, {
    String? fingerprint,
    int maxTargets = 4,
  }) async {
    if (best.isEmpty) return;
    try {
      final raw = preferences.getString(preferenceKey);
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      final targets = <String, dynamic>{};
      if (decoded is Map && decoded['targets'] is Map) {
        final existing = Map<String, dynamic>.from(decoded['targets'] as Map);
        final keys = existing.keys.toList()..sort((a, b) {
          final aAt = existing[a] is Map && (existing[a] as Map)['at'] is num ? (existing[a] as Map)['at'] as num : 0;
          final bAt = existing[b] is Map && (existing[b] as Map)['at'] is num ? (existing[b] as Map)['at'] as num : 0;
          return bAt.compareTo(aAt);
        });
        for (final key in keys.take(maxTargets)) {
          targets[key] = existing[key];
        }
      }
      targets[cacheKey] = {
        'at': DateTime.now().millisecondsSinceEpoch,
        'net': fingerprint ?? '',
        'cdns': best
            .map((r) => {'host': r.candidate.host, 'port': r.candidate.port, 'mbps': r.mbps, 'rtt': r.rttMs})
            .toList(growable: false),
      };
      await preferences.setString(preferenceKey, jsonEncode({'targets': targets}));
    } catch (_) {
      // 缓存写失败不影响主流程
    }
  }

  static Future<void> clear(SharedPreferences preferences) => preferences.remove(preferenceKey);

  /// 网络指纹：按网卡名 + IPv4 生成。
  ///
  /// 不引三方插件（拿不到 SSID），但换 Wi-Fi / 切蜂窝 / 换网段都会让本机地址变化，
  /// 足以让旧测速结果失效。
  static Future<String> networkFingerprint() async {
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      final parts = <String>[];
      for (final interface in interfaces) {
        final addresses = interface.addresses.where((a) => !a.isLoopback).map((a) => a.address).toList()..sort();
        if (addresses.isEmpty) continue;
        parts.add('${interface.name}=${addresses.first}');
      }
      parts.sort();
      return parts.join(',');
    } catch (_) {
      return '';
    }
  }
}
