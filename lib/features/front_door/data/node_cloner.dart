/// vless+ws+tls 节点克隆器（纯函数，无副作用，便于单测）
///
/// 需求：登录后把订阅里命中关键词、协议为 vless+ws+tls 的节点**复制**成 N 份，
/// 名称追加「-优选1…-优选N」，依次用优选出的地址替换 `address`；
/// `host` / `sni` / `path` / 端口 / 其余 query 参数**逐字保留**。
///
/// 原节点永远保留（优选地址全挂时用户仍有可用节点）。
///
/// 幂等保证：每次应用前先剔除所有「-优选N」行再重建 —— 否则订阅每更新一次
/// 节点数就乘 6，最终把客户端列表撑爆。
abstract final class NodeCloner {
  /// 克隆节点备注后缀标记。
  static const remarkMarker = '-优选';

  /// `vless://uuid@address:port?<query>#<fragment>`
  static final RegExp _vlessAuthority = RegExp(r'^(vless://[^@/?#]+@)([^:/?#]+)(:\d+)?(.*)$');

  static final RegExp _ipv4Pattern = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

  static final RegExp _cloneRemark = RegExp('-优选\\d+\$');

  /// 域名（非 IPv4、非含冒号的 IPv6 字面量）判定。
  static bool isDomain(String value) => value.isNotEmpty && !_ipv4Pattern.hasMatch(value) && !value.contains(':');

  /// 解析一行订阅内容，非 vless+ws+tls 节点返回 null。
  static FrontDoorNodeInfo? parseNode(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('vless://')) return null;
    final match = _vlessAuthority.firstMatch(trimmed);
    if (match == null) return null;
    final address = match.group(2)!;
    if (address.isEmpty) return null;
    final portStr = match.group(3);
    final port = portStr == null ? 443 : int.tryParse(portStr.substring(1));
    if (port == null || port <= 0 || port > 65535) return null;
    final rest = match.group(4) ?? '';

    final hashIndex = rest.indexOf('#');
    final queryPart = hashIndex == -1 ? rest : rest.substring(0, hashIndex);
    final queryStart = queryPart.indexOf('?');
    if (queryStart == -1) return null;
    final query = Uri.splitQueryString(queryPart.substring(queryStart + 1));
    final type = (query['type'] ?? '').toLowerCase();
    final security = (query['security'] ?? '').toLowerCase();
    if (type != 'ws' || security != 'tls') return null;

    final sni = (query['sni'] ?? query['peer'] ?? query['host'] ?? '').trim();
    if (sni.isEmpty) return null;
    final wsHost = (query['host'] ?? '').trim();
    return FrontDoorNodeInfo(address: address, port: port, sni: sni, wsHost: wsHost);
  }

  /// 行文本（地址/host/SNI/备注任意处）包含任一关键词即命中，大小写不敏感。
  static bool matchesKeywords(String line, List<String> keywords) {
    if (keywords.isEmpty) return false;
    final lower = line.toLowerCase();
    return keywords.any((k) => k.toLowerCase().isNotEmpty && lower.contains(k.toLowerCase()));
  }

  /// 逗号/空格/分号分隔的关键词串拆成列表。
  static List<String> splitKeywords(String raw) {
    return raw
        .split(RegExp(r'[,，;；\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// 只替换 authority 中的连接地址，端口、query（host/sni/path 等）与备注原样保留。
  static String replaceAddress(String line, String newAddress) {
    return line.replaceFirstMapped(_vlessAuthority, (m) {
      final portPart = m.group(3) ?? '';
      final rest = m.group(4) ?? '';
      return '${m.group(1)}$newAddress$portPart$rest';
    });
  }

  /// 把 `#` 之后的备注整体替换（备注缺失时追加）。
  static String replaceRemark(String line, String remark) {
    final hashIndex = line.indexOf('#');
    final base = hashIndex == -1 ? line : line.substring(0, hashIndex);
    return '$base#${Uri.encodeComponent(remark)}';
  }

  /// 取原始备注（无则回退为 address）。
  static String remarkOf(String line) {
    final info = parseNode(line);
    final hashIndex = line.indexOf('#');
    if (hashIndex != -1 && hashIndex < line.length - 1) {
      final raw = line.substring(hashIndex + 1);
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }
    return info?.address ?? 'node';
  }

  /// 是否是本功能生成（或残留）的克隆节点。
  static bool isClone(String line) {
    if (parseNode(line) == null) return false;
    return _cloneRemark.hasMatch(remarkOf(line));
  }

  /// 剔除所有「-优选N」克隆行，其余原样返回。
  static List<String> stripClones(List<String> lines) {
    return lines.where((line) => !isClone(line)).toList(growable: false);
  }

  /// 应用克隆：
  /// 1. 先剔除历史克隆（幂等）；
  /// 2. 对命中关键词的 vless+ws+tls 原节点，按 [addresses] 顺序生成最多 [copies] 份克隆，
  ///    紧跟在该节点之后；
  /// 3. 原节点不动。
  ///
  /// [addresses] 为空时等价于「只清理克隆」。
  static List<String> apply(
    List<String> lines, {
    required List<String> addresses,
    required List<String> keywords,
    int copies = 5,
  }) {
    final cleaned = stripClones(lines);
    if (addresses.isEmpty || copies <= 0) return cleaned;

    final limit = copies < addresses.length ? copies : addresses.length;
    final result = <String>[];
    for (final line in cleaned) {
      result.add(line);
      final info = parseNode(line);
      if (info == null) continue;
      if (!matchesKeywords(line, keywords)) continue;
      final baseRemark = remarkOf(line);
      for (var i = 0; i < limit; i++) {
        final clone = replaceAddress(line, addresses[i]);
        result.add(replaceRemark(clone, '$baseRemark$remarkMarker${i + 1}'));
      }
    }
    return result;
  }
}

/// 解析出来的节点关键信息。
class FrontDoorNodeInfo {
  const FrontDoorNodeInfo({
    required this.address,
    required this.port,
    required this.sni,
    required this.wsHost,
  });

  /// URI authority 中的连接地址（域名或 IP）
  final String address;
  final int port;

  /// TLS SNI（sni/peer 参数，缺失时回退 ws host 参数）
  final String sni;

  /// WebSocket Host 头（host 参数）
  final String wsHost;

  /// 目标域名：用于缓存键与候选补充。优先连接地址，其次 ws Host，最后 SNI。
  String get targetHost {
    if (NodeCloner.isDomain(address)) return address;
    if (NodeCloner.isDomain(wsHost)) return wsHost;
    if (NodeCloner.isDomain(sni)) return sni;
    return address;
  }
}
