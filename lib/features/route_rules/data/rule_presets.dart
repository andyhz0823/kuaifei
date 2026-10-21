import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

/// 内置分流场景预设。用户在「路由规则」页一键导入。
///
/// 预设使用 proto 的结构化字段（domains/domainSuffixes/ipCidrs 等），
/// 由 split_rule_encoder 统一编码成 core 侧的字符串形态。
class RulePresets {
  const RulePresets._();

  static final presets = <RulePreset>[
    RulePreset(
      title: '国内直连',
      description: '中国大陆域名与 IP 走直连',
      rules: [
        Rule(
          name: '国内域名直连',
          outbound: Outbound.direct,
          domainSuffixes: ['cn', 'com.cn', 'org.cn', 'gov.cn', 'edu.cn', 'net.cn'],
          ipCidrs: ['geoip:cn'],
          network: Network.all,
        ),
      ],
    ),
    RulePreset(
      title: '广告拦截',
      description: '常见广告与跟踪域名走拦截',
      rules: [
        Rule(
          name: '广告拦截',
          outbound: Outbound.block,
          domainKeywords: ['ads', 'advert', 'tracker', 'analytics', 'doubleclick', 'adservice'],
          network: Network.all,
        ),
      ],
    ),
    RulePreset(
      title: 'AI 服务走代理',
      description: '常见 AI / 海外服务域名走代理',
      rules: [
        Rule(
          name: 'AI 服务代理',
          outbound: Outbound.proxy,
          domainSuffixes: [
            'openai.com',
            'anthropic.com',
            'claude.ai',
            'google.com',
            'github.com',
            'gemini.google.com',
          ],
          network: Network.all,
        ),
      ],
    ),
    RulePreset(
      title: '流媒体走代理',
      description: '常见流媒体域名走代理',
      rules: [
        Rule(
          name: '流媒体代理',
          outbound: Outbound.proxy,
          domainSuffixes: ['netflix.com', 'youtube.com', 'youtu.be', 'spotify.com', 'disneyplus.com', 'hulu.com'],
          network: Network.all,
        ),
      ],
    ),
  ];
}

class RulePreset {
  const RulePreset({required this.title, required this.description, required this.rules});

  final String title;
  final String description;
  final List<Rule> rules;
}
