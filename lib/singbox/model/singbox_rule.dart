import 'package:freezed_annotation/freezed_annotation.dart';

part 'singbox_rule.freezed.dart';
part 'singbox_rule.g.dart';

@freezed
class SingboxRule with _$SingboxRule {
  const SingboxRule._();

  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxRule({
    String? ruleSetUrl,
    String? domains,
    String? ip,
    String? port,
    String? protocol,
    @Default(RuleNetwork.tcpAndUdp) RuleNetwork network,
    @Default(RuleOutbound.proxy) RuleOutbound outbound,
    /// 指定出站目标：具体节点名或策略组名（sing-box outbound tag）。
    ///
    /// 为空时按 [outbound] 枚举走（proxy / 直连 / 阻断）；
    /// 有值时 core 侧会优先用它作为 sing-box 的 outbound tag，
    /// 即「这条规则走哪个节点 / 策略组」。
    String? outboundTarget,
  }) = _SingboxRule;

  factory SingboxRule.fromJson(Map<String, dynamic> json) => _$SingboxRuleFromJson(json);
}

enum RuleOutbound { proxy, bypass, block }

@JsonEnum(valueField: 'key')
enum RuleNetwork {
  tcpAndUdp(""),
  tcp("tcp"),
  udp("udp");

  const RuleNetwork(this.key);

  final String? key;
}
