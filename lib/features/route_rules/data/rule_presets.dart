import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

/// 内置分流规则预设。
///
/// 设计约束：
/// - 只用**内联**匹配条件（域名/域名后缀/域名关键词/IP 段），不引用 rule_set 远程资源，
///   这样点一下即可生效，不依赖网络下载，也不会因为远程规则集失效而静默失效。
/// - 预设只提供「规则内容」，落库仍走 RulesNotifier.addRule，与手动创建的规则完全同构，
///   用户添加后可以照常编辑/排序/删除。
/// - 名称走 i18n（`routeRule.presets.items[<id>]`），与其他路由文案保持一致。
class RulePreset {
  const RulePreset({
    required this.id,
    required this.name,
    required this.outbound,
    this.domains = const [],
    this.domainSuffixes = const [],
    this.domainKeywords = const [],
    this.ipCidrs = const [],
  });

  /// 稳定标识，不参与展示。
  final String id;

  /// 展示名。用内置常量而非 i18n：新增 i18n key 需要重新生成 slang 产物
  /// （lib/gen/translations_*.g.dart 共 12 个文件），对测试分支是不必要的耦合。
  final String name;

  final Outbound outbound;
  final List<String> domains;
  final List<String> domainSuffixes;
  final List<String> domainKeywords;
  final List<String> ipCidrs;

  /// 构造一条规则实体。
  Rule toRule(int listOrder) => Rule(
    listOrder: listOrder,
    enabled: true,
    name: name,
    outbound: outbound,
    network: Network.all,
    domains: domains,
    domainSuffixes: domainSuffixes,
    domainKeywords: domainKeywords,
    ipCidrs: ipCidrs,
  );
}

/// 预设清单。顺序即列表展示顺序。
const kRouteRulePresets = <RulePreset>[
  // ── 局域网直连：RFC1918 私有段 + 回环 + 链路本地，IPv4/IPv6 都覆盖 ──
  RulePreset(
    id: 'lanDirect',
    name: '局域网直连',
    outbound: Outbound.direct,
    ipCidrs: [
      '10.0.0.0/8',
      '172.16.0.0/12',
      '192.168.0.0/16',
      '127.0.0.0/8',
      '169.254.0.0/16',
      'fc00::/7',
      'fe80::/10',
      '::1/128',
    ],
  ),

  // 注意：这里不再提供「国内站点直连」预设。
  // 国内站点有数万个域名，手写域名后缀列表既不完整也不会更新。
  // 正确做法由内核承担：设置 → 路由 → 区域 选择「中国」后，core 会自动加载
  // geosite-cn（全量国内域名库）+ geoip-cn（国内 IP 段）两个远程规则集并直连，
  // 规则集由 sing-box 按 update_interval 自动更新，无需手工维护。
  // 见 rule_presets 面板里的「国内流量直连」引导项（rules_page.dart）。

  // ── 广告拦截：常见广告/追踪域名，指向 block ──
  RulePreset(
    id: 'blockAds',
    name: '广告拦截',
    outbound: Outbound.block,
    domainSuffixes: [
      'doubleclick.net',
      'googleadservices.com',
      'googlesyndication.com',
      'google-analytics.com',
      'adservice.google.com',
      'adsrvr.org',
      'adnxs.com',
      'criteo.com',
      'criteo.net',
      'taboola.com',
      'outbrain.com',
      'scorecardresearch.com',
      'quantserve.com',
      'umeng.com',
      'umengcloud.com',
      'cnzz.com',
      'talkingdata.com',
      'adjust.com',
      'appsflyer.com',
      'branch.io',
      'moengage.com',
      'clevertap.com',
      'ads-twitter.com',
      'adcolony.com',
      'applovin.com',
      'unityads.unity3d.com',
      'vungle.com',
      'chartboost.com',
      'inmobi.com',
      'mopub.com',
      'flurry.com',
    ],
  ),

  // ── 苹果服务直连：避免 iCloud/推送/App Store 走代理 ──
  RulePreset(
    id: 'appleDirect',
    name: '苹果服务直连',
    outbound: Outbound.direct,
    domainSuffixes: [
      'apple.com',
      'icloud.com',
      'icloud-content.com',
      'mzstatic.com',
      'cdn-apple.com',
      'apple-cloudkit.com',
      'push.apple.com',
      'aaplimg.com',
    ],
  ),

  // ── 微软服务直连：Windows 更新/激活/Office 走代理会失败或极慢 ──
  RulePreset(
    id: 'microsoftDirect',
    name: '微软服务直连',
    outbound: Outbound.direct,
    domainSuffixes: [
      'microsoft.com',
      'windowsupdate.com',
      'windows.com',
      'live.com',
      'msn.com',
      'office.com',
      'office.net',
      'outlook.com',
      'sharepoint.com',
      'onedrive.com',
      'visualstudio.com',
      'azureedge.net',
      'xboxlive.com',
    ],
  ),

  // ── 局域网/内网域名直连 ──
  RulePreset(
    id: 'localDomains',
    name: '内网域名直连',
    outbound: Outbound.direct,
    domainSuffixes: ['local', 'localhost', 'lan', 'internal', 'home.arpa'],
  ),
];
