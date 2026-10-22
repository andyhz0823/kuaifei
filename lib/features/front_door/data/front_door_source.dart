import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/http_client/edge_probe.dart';
import 'package:hiddify/features/front_door/model/front_door_candidate.dart';

/// 候选池来源。任何一路失败都不抛错 —— 优选是增强功能，不能影响主流程。
abstract interface class FrontDoorSource {
  String get label;

  Future<List<FrontDoorCandidate>> fetch();
}

/// 自建 cfst-ddns 优选源（决策：仅当**候选粗筛**用，速度值一律本机重测）
///
/// 兼容三种常见输出格式：
/// - 纯 IP 列表：`1.2.3.4`
/// - 带端口：`1.2.3.4:8443` 或 `1.2.3.4,8443`
/// - CloudflareST `result.csv`：`1.2.3.4,4,4,0.00,38.12,42.50`
///   （第二列是已发送包数，**不能**当端口，4 列及以上一律按无端口处理）
/// - 表头 / 注释 / 空行自动跳过
final class CfstDdnsSource implements FrontDoorSource {
  CfstDdnsSource(this.urls, {this.maxCandidates = 12, this.timeout = const Duration(seconds: 8)});

  final List<String> urls;
  final int maxCandidates;
  final Duration timeout;

  @override
  String get label => 'cfst-ddns';

  @override
  Future<List<FrontDoorCandidate>> fetch() async {
    for (final raw in urls) {
      final url = raw.trim();
      if (url.isEmpty || !url.startsWith('http')) continue;
      try {
        final body = await _get(url);
        final parsed = parseBody(body, max: maxCandidates);
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {
        // 换下一个源
      }
    }
    return const [];
  }

  Future<String> _get(String url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  /// 纯解析（可单测）。
  static List<FrontDoorCandidate> parseBody(String body, {int max = 12}) {
    final seen = <String>{};
    final result = <FrontDoorCandidate>[];
    for (final rawLine in const LineSplitter().convert(body)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
      final candidate = parseLine(line);
      if (candidate == null) continue;
      if (!seen.add(candidate.key)) continue;
      result.add(candidate);
      if (result.length >= max) break;
    }
    return result;
  }

  /// 解析单行，非合法候选返回 null。
  static FrontDoorCandidate? parseLine(String line) {
    var text = line.trim();
    if (text.isEmpty) return null;
    // 去掉可能的行内注释
    final hash = text.indexOf('#');
    if (hash > 0) text = text.substring(0, hash).trim();
    if (text.isEmpty) return null;

    var host = text;
    var port = 443;

    final parts = text.split(RegExp(r'[,\t;|]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length >= 4) {
      // CloudflareST `result.csv`：IP,已发送,已接收,丢包率,平均延迟,下载速度
      // 第二列是「已发送包数」不是端口，硬当端口会把 4 解析成 port 4。
      host = parts[0];
    } else if (parts.length >= 2) {
      // `ip,port` 或 `ip,port,delay`
      host = parts[0];
      final parsed = int.tryParse(parts[1]);
      if (parsed != null && parsed > 0 && parsed <= 65535) port = parsed;
    } else if (text.contains(':')) {
      final idx = text.lastIndexOf(':');
      host = text.substring(0, idx).trim();
      final parsed = int.tryParse(text.substring(idx + 1).trim());
      if (parsed != null && parsed > 0 && parsed <= 65535) port = parsed;
    }

    if (!_isValidHost(host)) return null;
    return FrontDoorCandidate(host: host, port: port, remark: 'cfst-ddns');
  }

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
  static final RegExp _domain = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$');

  static bool _isValidHost(String host) {
    if (_ipv4.hasMatch(host)) {
      return host.split('.').every((part) {
        final value = int.tryParse(part);
        return value != null && value >= 0 && value <= 255;
      });
    }
    return _domain.hasMatch(host);
  }
}

/// 内置 CF 边缘 IP 兜底（复用 v5.0.4 起 `EdgeProbe` 维护的 15 个候选）
final class BuiltinEdgeSource implements FrontDoorSource {
  const BuiltinEdgeSource({this.maxCandidates = 12});

  final int maxCandidates;

  @override
  String get label => '内置边缘 IP';

  @override
  Future<List<FrontDoorCandidate>> fetch() async {
    return EdgeProbe.candidateAddresses
        .take(maxCandidates)
        .map((ip) => FrontDoorCandidate(host: ip, remark: 'builtin'))
        .toList(growable: false);
  }
}

/// 节点域名自身 A 记录（最后一道兜底）
final class DomainARecordSource implements FrontDoorSource {
  const DomainARecordSource(this.host, {this.maxCandidates = 12});

  final String host;
  final int maxCandidates;

  @override
  String get label => '域名 A 记录';

  @override
  Future<List<FrontDoorCandidate>> fetch() async {
    if (host.isEmpty) return const [];
    try {
      final records = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
      return records
          .where((r) => r.type == InternetAddressType.IPv4)
          .take(maxCandidates)
          .map((r) => FrontDoorCandidate(host: r.address, remark: 'dns'))
          .toList(growable: false);
    } catch (_) {
      // 解析失败就交给下一级兜底
      return const [];
    }
  }
}

/// 三级降级组装候选池：cfst-ddns → 内置边缘 IP → 域名 A 记录。
Future<List<FrontDoorCandidate>> resolveCandidates({
  required List<String> sourceUrls,
  required String targetHost,
  int maxCandidates = 12,
}) async {
  final sources = <FrontDoorSource>[
    if (sourceUrls.isNotEmpty) CfstDdnsSource(sourceUrls, maxCandidates: maxCandidates),
    BuiltinEdgeSource(maxCandidates: maxCandidates),
    if (targetHost.isNotEmpty) DomainARecordSource(targetHost, maxCandidates: maxCandidates),
  ];

  final merged = <String, FrontDoorCandidate>{};
  for (final source in sources) {
    if (merged.length >= maxCandidates) break;
    final batch = await source.fetch();
    for (final candidate in batch) {
      if (merged.length >= maxCandidates) break;
      merged.putIfAbsent(candidate.key, () => candidate);
    }
  }
  return merged.values.toList(growable: false);
}
