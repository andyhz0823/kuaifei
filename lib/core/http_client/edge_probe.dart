import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Cloudflare 边缘 IP 自动优选。
///
/// 背景：面板域名（`www.kuaify.cc.cd`）与订阅域名（`*.tkyayun.cc.cd`）都走 CF 代理，
/// DNS 被污染时客户端只能靠写死的边缘 IP 兜底。CF 是 anycast + 按 SNI 路由，
/// **任意** CF 边缘 IP 都能服务任意 zone，所以可以探测一批已知边缘 IP，
/// 挑当前网络下 TLS 握手最快的几个缓存起来，DNS 挂掉时直接拨这些 IP。
///
/// 说明：探测阶段 `onBadCertificate` 放行只是为了测「这个边缘能不能完成握手」，
/// 用来排序；真正收发数据仍然走正常的 TLS 校验（dio / HttpClient 默认行为）。
class EdgeProbe {
  const EdgeProbe._();

  static const preferenceKey = 'origin_edge_ip_cache_v1';
  static const cacheTtl = Duration(hours: 6);
  static const keepCount = 3;

  static const _timeout = Duration(seconds: 2);

  /// 候选边缘 IP：覆盖 104.16~104.22 / 172.66~172.67 / 188.114 / 162.159 网段，
  /// 前两个是我们两个 zone 当前解析到的地址（作为基准）。
  static const candidateAddresses = <String>[
    '104.21.84.66',
    '172.67.187.171',
    '104.21.35.212',
    '172.67.179.226',
    '104.16.132.229',
    '104.17.26.41',
    '104.18.32.115',
    '104.19.192.29',
    '104.20.28.5',
    '104.22.4.10',
    '172.66.0.96',
    '188.114.96.1',
    '188.114.97.1',
    '162.159.36.1',
    '162.159.46.1',
  ];

  /// 对 [sniHost] 逐个候选 IP 做 TLS 握手计时，返回最快的 [keepCount] 个地址。
  static Future<List<String>> probe(String sniHost, {int keep = keepCount}) async {
    final host = sniHost.trim().toLowerCase();
    if (host.isEmpty) return const [];

    final results = await Future.wait(
      candidateAddresses.map((address) async => MapEntry(address, await _handshakeMs(address, host))),
    );

    final reachable = results.where((entry) => entry.value > 0).toList()
      ..sort((left, right) => left.value.compareTo(right.value));

    if (reachable.isEmpty) return const [];
    return reachable.take(keep).map((entry) => entry.key).toList(growable: false);
  }

  /// 返回握手毫秒数；失败返回 -1。
  static Future<int> _handshakeMs(String address, String sniHost) async {
    Socket? raw;
    SecureSocket? secure;
    try {
      final stopwatch = Stopwatch()..start();
      raw = await Socket.connect(address, 443, timeout: _timeout);
      secure = await SecureSocket.secure(raw, host: sniHost, onBadCertificate: (_) => true, timeout: _timeout);
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      try {
        await secure?.close();
      } catch (_) {}
      raw?.destroy();
    }
  }

  /// 读取缓存：`{"ips": [...], "at": <epoch ms>}`，过期返回空。
  static List<String> readCache(SharedPreferences preferences) {
    final raw = preferences.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final ips = decoded['ips'];
      final at = decoded['at'];
      if (ips is! List || at is! num) return const [];
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      if (DateTime.now().difference(cachedAt) > cacheTtl) return const [];
      return ips.whereType<String>().where((ip) => InternetAddress.tryParse(ip) != null).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> writeCache(SharedPreferences preferences, List<String> ips) async {
    if (ips.isEmpty) return;
    await preferences.setString(preferenceKey, jsonEncode({'ips': ips, 'at': DateTime.now().millisecondsSinceEpoch}));
  }
}
