import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/singbox/model/singbox_rule.dart';

/// 把客户端的「结构化」分流规则编码成下发给 core 的字符串形态。
///
/// core 侧 (hiddify-core/v2/config/rules.go) 按前缀解析这些字段：
///   `full:`      精确域名      `domain:`  域名后缀
///   `keyword:`   域名关键字    `regexp:`   域名正则
///   `geosite:`   geosite 集    `ruleset:`  远程规则集
///   `pkg:`       Android 包名  `proc:`     进程名（Windows）
///   `procpath:`  进程全路径
///
/// 之所以走字符串编码而不是直接下发结构化字段：core 侧的 HiddifyOptions 是手写
/// struct，其 rules 字段用的就是这套字符串形态（与 Dart 侧 SingboxRule 对齐），
/// 改 proto 需要 protoc 重新生成，成本高且容易与生成物脱节。
SingboxRule encodeSplitRule(Rule rule) {
  final domains = <String>[
    for (final item in rule.domains) 'full:$item',
    for (final item in rule.domainSuffixes) 'domain:$item',
    for (final item in rule.domainKeywords) 'keyword:$item',
    for (final item in rule.domainRegexes) 'regexp:$item',
    for (final item in rule.packageNames) 'pkg:$item',
    for (final item in rule.processNames) 'proc:$item',
    for (final item in rule.processPaths) 'procpath:$item',
    for (final item in rule.ruleSets) 'ruleset:$item',
  ];

  return SingboxRule(
    domains: domains.isEmpty ? null : domains.join(','),
    ip: rule.ipCidrs.isEmpty ? null : rule.ipCidrs.join(','),
    port: rule.portRanges.isEmpty ? null : rule.portRanges.join(','),
    protocol: rule.protocols.isEmpty ? null : rule.protocols.map((e) => e.name).join(','),
    network: splitNetworkOf(rule.network),
    outbound: splitOutboundOf(rule.outbound),
  );
}

/// 把结构化规则列表整体编码（自动过滤未启用的规则）。
List<SingboxRule> encodeSplitRules(List<Rule> rules) =>
    rules.where((rule) => rule.enabled).map(encodeSplitRule).toList();

/// 网络类型映射。all 表示不限。
RuleNetwork splitNetworkOf(Network network) {
  switch (network) {
    case Network.tcp:
      return RuleNetwork.tcp;
    case Network.udp:
      return RuleNetwork.udp;
    default:
      return RuleNetwork.tcpAndUdp;
  }
}

/// 出站类型映射。
///
/// `direct` / `direct_with_fragment` 统一映射到 bypass —— core 侧会把 bypass
/// 视作直连（hiddify 并没有创建名为 bypass 的 outbound，指向不存在的 tag 会
/// 让 sing-box 找不到出口）。
RuleOutbound splitOutboundOf(Outbound outbound) {
  switch (outbound) {
    case Outbound.direct:
      return RuleOutbound.bypass;
    case Outbound.direct_with_fragment:
      return RuleOutbound.bypass;
    case Outbound.block:
      return RuleOutbound.block;
    default:
      return RuleOutbound.proxy;
  }
}
