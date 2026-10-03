import 'dart:convert';

/// 一个可选的出站目标（节点或策略组）。
///
/// tag 就是 sing-box 配置里的 outbound tag，也是写进规则 `outbound_tag` 的值 ——
/// 规则不做任何 ID 映射，直接与配置对齐，避免订阅更新后对不上号。
class OutboundOption {
  const OutboundOption({required this.tag, this.displayName});

  final String tag;

  /// 展示名；为空时使用 tag。
  final String? displayName;

  String get name => displayName ?? tag;
}

/// 解析结果：策略组（手动选择/最低延迟/负载均衡）与真实节点分开，方便 UI 分组展示。
class OutboundOptions {
  const OutboundOptions({this.groups = const [], this.nodes = const []});

  final List<OutboundOption> groups;
  final List<OutboundOption> nodes;

  bool get isEmpty => groups.isEmpty && nodes.isEmpty;

  static const empty = OutboundOptions();
}

/// 从 sing-box 完整配置 JSON 里提取可绑定的出站。
///
/// 过滤规则：
/// - 去掉 hiddify 的内部隐藏 outbound（tag 带 `§hide§`，如 `direct §hide§`、`dns-out §hide§`）；
/// - 去掉 DNS 相关的内部 outbound（tag 以 `dns-` 开头），它们不是流量出口；
/// - 剩下按 type 分成策略组（selector/urltest/loadbalance）与真实节点。
///
/// 配置解析失败时返回空集合：节点列表只是选择器的候选项，取不到应降级为
/// 「暂无可选节点」而不是让规则编辑页崩掉。
OutboundOptions parseOutboundOptions(String configJson) {
  Object? decoded;
  try {
    decoded = jsonDecode(configJson);
  } on FormatException {
    return OutboundOptions.empty;
  }
  if (decoded is! Map<String, dynamic>) return OutboundOptions.empty;

  final outbounds = decoded['outbounds'];
  if (outbounds is! List) return OutboundOptions.empty;

  final groups = <OutboundOption>[];
  final nodes = <OutboundOption>[];

  for (final item in outbounds) {
    if (item is! Map<String, dynamic>) continue;
    final tag = item['tag'];
    if (tag is! String || tag.isEmpty) continue;
    if (tag.contains('§hide§') || tag.startsWith('dns-')) continue;

    final type = item['type'] as String?;
    final groupName = switch (type) {
      'selector' => '手动选择（select）',
      'urltest' => '最低延迟（lowest）',
      'loadbalance' || 'balancer' => '负载均衡（balance）',
      _ => null,
    };
    if (groupName != null) {
      groups.add(OutboundOption(tag: tag, displayName: groupName));
    } else {
      nodes.add(OutboundOption(tag: tag));
    }
  }

  // 节点按名称排序，订阅里节点顺序不稳定，排序后用户每次打开看到的位置一致。
  nodes.sort((a, b) => a.name.compareTo(b.name));
  return OutboundOptions(groups: groups, nodes: nodes);
}
