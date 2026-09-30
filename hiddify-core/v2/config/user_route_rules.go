package config

import (
	"os"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"google.golang.org/protobuf/proto"
)

// 用户自定义分流规则（由客户端的「路由规则」界面维护）。
//
// 上游背景：hiddify 把分流规则的界面与存储都实现了 —— 客户端会把规则写入
// <BaseDir>/route_rule.proto —— 但 core 侧从未读取该文件，所以规则完全不生效
// （见 builder.go 中被注释掉的 `// for _, rule := range opt.Rules`，
// 以及 setRoutingOptions 无条件覆盖 options.Route 的行为）。
// 这里补上消费端：读出该文件并转换成 sing-box 的 option.Rule 追加到路由规则。
//
// 路径由 hcore 在 Setup 阶段注入（见 SetUserRouteRulesPath）。
var userRouteRulesPath string

// SetUserRouteRulesPath 注入用户规则文件的绝对路径。
func SetUserRouteRulesPath(path string) {
	userRouteRulesPath = path
}

// LoadUserRouteRules 读取并转换用户规则。
//
// 每次调用都重新读盘：规则由用户在界面随时增删，而本函数只在构建配置时调用
// （启动 / 重载），频率很低，不引入缓存复杂度。
// 文件缺失、为空或解析失败时返回 nil，不影响内置规则。
func LoadUserRouteRules() []option.Rule {
	if userRouteRulesPath == "" {
		return nil
	}
	data, err := os.ReadFile(userRouteRulesPath)
	if err != nil || len(data) == 0 {
		return nil
	}
	var parsed RouteRule
	if err := proto.Unmarshal(data, &parsed); err != nil {
		return nil
	}

	rules := make([]option.Rule, 0, len(parsed.Rules))
	for _, r := range parsed.Rules {
		if r == nil || !r.Enabled {
			continue
		}
		if converted := convertUserRule(r); converted != nil {
			rules = append(rules, *converted)
		}
	}
	return rules
}

// convertUserRule 把界面规则模型映射为 sing-box 规则。
//
// 没有任何匹配条件的规则返回 nil —— 否则会命中全部流量，把整条隧道带偏。
func convertUserRule(r *Rule) *option.Rule {
	raw := option.RawDefaultRule{
		Domain:          r.Domains,
		DomainSuffix:    r.DomainSuffixes,
		DomainKeyword:   r.DomainKeywords,
		DomainRegex:     r.DomainRegexes,
		IPCIDR:          r.IpCidrs,
		SourceIPCIDR:    r.SourceIpCidrs,
		PortRange:       r.PortRanges,
		SourcePortRange: r.SourcePortRanges,
		ProcessName:     r.ProcessNames,
		ProcessPath:     r.ProcessPaths,
		PackageName:     r.PackageNames,
		RuleSet:         r.RuleSets,
		Network:         userRuleNetwork(r.Network),
		Protocol:        userRuleProtocols(r.Protocols),
	}
	if !hasUserRuleMatcher(raw) {
		return nil
	}

	action := option.RuleAction{}
	switch r.Outbound {
	case Outbound_block:
		action.Action = C.RuleActionTypeReject
		action.RejectOptions = option.RejectActionOptions{Method: C.RuleActionRejectMethodDefault}
	case Outbound_direct:
		action.Action = C.RuleActionTypeRoute
		action.RouteOptions = option.RouteActionOptions{Outbound: OutboundDirectTag}
	case Outbound_direct_with_fragment:
		action.Action = C.RuleActionTypeRoute
		action.RouteOptions = option.RouteActionOptions{Outbound: OutboundDirectFragmentTag}
	default: // Outbound_proxy
		action.Action = C.RuleActionTypeRoute
		action.RouteOptions = option.RouteActionOptions{Outbound: OutboundMainDetour}
	}

	return &option.Rule{
		Type: C.RuleTypeDefault,
		DefaultOptions: option.DefaultRule{
			RawDefaultRule: raw,
			RuleAction:     action,
		},
	}
}

// hasUserRuleMatcher 判断规则是否至少含一个匹配条件。
func hasUserRuleMatcher(r option.RawDefaultRule) bool {
	return len(r.Domain) > 0 || len(r.DomainSuffix) > 0 || len(r.DomainKeyword) > 0 ||
		len(r.DomainRegex) > 0 || len(r.IPCIDR) > 0 || len(r.SourceIPCIDR) > 0 ||
		len(r.PortRange) > 0 || len(r.SourcePortRange) > 0 || len(r.ProcessName) > 0 ||
		len(r.ProcessPath) > 0 || len(r.PackageName) > 0 || len(r.RuleSet) > 0 ||
		len(r.Network) > 0 || len(r.Protocol) > 0
}

// userRuleNetwork 映射网络类型；all 表示不限制，返回 nil。
func userRuleNetwork(n Network) []string {
	switch n {
	case Network_tcp:
		return []string{"tcp"}
	case Network_udp:
		return []string{"udp"}
	default:
		return nil
	}
}

// userRuleProtocols 映射协议列表。
func userRuleProtocols(protocols []Protocol) []string {
	if len(protocols) == 0 {
		return nil
	}
	out := make([]string, 0, len(protocols))
	for _, p := range protocols {
		switch p {
		case Protocol_tls:
			out = append(out, "tls")
		case Protocol_http:
			out = append(out, "http")
		case Protocol_quic:
			out = append(out, "quic")
		case Protocol_stun:
			out = append(out, "stun")
		case Protocol_dns:
			out = append(out, "dns")
		case Protocol_bittorrent:
			out = append(out, "bittorrent")
		}
	}
	return out
}
