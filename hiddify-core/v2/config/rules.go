package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	sdns "github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/option"
)

// ---------------------------------------------------------------------------
// v2 分流规则引擎
//
// 客户端（Dart 侧 SingboxRule）下发的是「字符串形态」的分流规则，
// 这里负责把它翻译成 sing-box 的 route rule 与 dns rule。
//
// 字段前缀约定（写在 domains 字段里，逗号分隔）：
//
//	full:example.com   精确域名        domain:example.com  域名后缀
//	keyword:ads        域名关键字      regexp:^ads.*        域名正则
//	geosite:category-ads  geosite 集  ruleset:my-set      远程规则集
//	pkg:com.example    Android 包名    proc:example.exe    进程名
//	procpath:C:\a\b.exe  进程全路径
//
// ip 字段：逗号分隔，geoip:cn 走 geoip，其余按 CIDR 处理。
// port 字段：逗号分隔，1000:2000 为区间，其余为单端口。
// ---------------------------------------------------------------------------

// SplitRule 是客户端下发的分流规则。
// 字段名与 Dart 侧 SingboxRule 的序列化结果保持一致（kebab-case）。
type SplitRule struct {
	RuleSetUrl     string `json:"rule-set-url,omitempty"`
	Domains        string `json:"domains,omitempty"`
	Ip             string `json:"ip,omitempty"`
	Port           string `json:"port,omitempty"`
	Network        string `json:"network,omitempty"`
	Protocol       string `json:"protocol,omitempty"`
	Outbound       string `json:"outbound,omitempty"`
	OutboundTarget string `json:"outbound-target,omitempty"`
}

// MakeRouteRule 把一条客户端规则翻译成 sing-box 的 route rule。
// 第二个返回值为 false 表示这条规则没有任何匹配条件，应当被忽略。
func (r *SplitRule) MakeRouteRule() (option.DefaultRule, bool) {
	if r == nil {
		return option.DefaultRule{}, false
	}

	// 这里不预填空切片：DefaultRule.IsValid() 靠 DeepEqual 判断，
	// 空切片与 nil 不相等，会让「没有任何匹配条件」的规则被误判为有效。
	raw := option.RawDefaultRule{}

	applyDomainMatchers(&raw, splitList(r.Domains))

	for _, item := range splitList(r.Ip) {
		if strings.HasPrefix(item, "geoip:") {
			raw.GeoIP = append(raw.GeoIP, strings.TrimPrefix(item, "geoip:"))
			continue
		}
		raw.IPCIDR = append(raw.IPCIDR, item)
	}

	raw.Port, raw.PortRange = makePortRanges(splitList(r.Port))

	if network := strings.ToLower(strings.TrimSpace(r.Network)); network != "" {
		raw.Network = []string{network}
	}
	if protocols := makeProtocols(splitList(r.Protocol)); len(protocols) > 0 {
		raw.Protocol = protocols
	}
	if ruleSet := strings.TrimSpace(r.RuleSetUrl); ruleSet != "" {
		raw.RuleSet = append(raw.RuleSet, ruleSet)
	}

	rule := option.DefaultRule{RawDefaultRule: raw}
	if !rule.IsValid() {
		return option.DefaultRule{}, false
	}

	tag, action := r.outboundTarget()
	switch action {
	case C.RuleActionTypeReject:
		rule.RuleAction = option.RuleAction{Action: C.RuleActionTypeReject}
	case C.RuleActionTypeRoute:
		rule.RuleAction = option.RuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.RouteActionOptions{
				Outbound: tag,
			},
		}
	default:
		return option.DefaultRule{}, false
	}
	return rule, true
}

// MakeDNSRule 生成配套的 dns rule。
// 目前只有「阻断」需要配套 dns 规则（把解析一起拒掉）；
// 其余场景保持既有 dns 行为不变，避免悄悄改变用户的解析策略。
func (r *SplitRule) MakeDNSRule() (option.DefaultDNSRule, bool) {
	if r == nil {
		return option.DefaultDNSRule{}, false
	}
	_, action := r.outboundTarget()
	if action != C.RuleActionTypeReject {
		return option.DefaultDNSRule{}, false
	}

	raw := option.RawDefaultDNSRule{}
	applyDomainMatchersDNS(&raw, splitList(r.Domains))

	rule := option.DefaultDNSRule{RawDefaultDNSRule: raw}
	if !rule.IsValid() {
		return option.DefaultDNSRule{}, false
	}

	rejectRCode := option.DNSRCode(sdns.RcodeRefused)
	rule.DNSRuleAction = option.DNSRuleAction{
		Action: C.RuleActionTypePredefined,
		PredefinedOptions: option.DNSRouteActionPredefined{
			Rcode: &rejectRCode,
		},
	}
	return rule, true
}

// outboundTarget 解析出站目标。
// 返回 (outbound tag, action)；action 为空表示这条规则的 outbound 无法识别。
// 优先级：outbound_target（具体节点/策略组名）> outbound 枚举。
// 除了固定的 proxy/direct/block，也可直接写节点名（指向具体节点或策略组）。
func (r *SplitRule) outboundTarget() (string, string) {
	// 指定节点 / 策略组优先：直接作为 sing-box 的 outbound tag。
	if target := strings.TrimSpace(r.OutboundTarget); target != "" {
		return target, C.RuleActionTypeRoute
	}
	switch strings.ToLower(strings.TrimSpace(r.Outbound)) {
	case "proxy":
		return OutboundMainDetour, C.RuleActionTypeRoute
	case "direct", "bypass":
		// 注意：hiddify 并未创建名为 bypass 的 outbound（只有常量），
		// 指向不存在的 tag 会让 sing-box 找不到出口，所以统一走 direct。
		return OutboundDirectTag, C.RuleActionTypeRoute
	case "direct_with_fragment", "direct-with-fragment":
		return OutboundDirectFragmentTag, C.RuleActionTypeRoute
	case "block", "reject":
		return "", C.RuleActionTypeReject
	}
	// 其它值当作具体节点名 / 策略组名
	if name := strings.TrimSpace(r.Outbound); name != "" {
		return name, C.RuleActionTypeRoute
	}
	return "", ""
}

// makeSelfBypassRule 生成「客户端自身进程 -> 直连」规则。
//
// 为什么要这条：Windows 端开启了 find_process 后，sing-box 能查到连接所属进程，
// 如果用户规则里写了某个进程名恰好命中客户端自身，客户端与面板之间的通信就会
// 被分流进代理，形成死循环（面板请求走代理 -> 代理又依赖面板 -> 无限递归）。
// 这条规则必须排在所有用户规则之前。
//
// 只在 Windows 生效：Android 端 sing-box 拿不到同进程的包名，自身流量不会被
// package_name 规则命中；而且各品牌包名不同，放到 core 里会引入品牌耦合。
func makeSelfBypassRule() (option.DefaultRule, bool) {
	if runtime.GOOS != "windows" {
		return option.DefaultRule{}, false
	}
	exePath, err := os.Executable()
	if err != nil {
		return option.DefaultRule{}, false
	}
	name := filepath.Base(exePath)
	if name == "" || name == "." || name == string(filepath.Separator) {
		return option.DefaultRule{}, false
	}
	names := []string{name}
	if extension := filepath.Ext(name); extension != "" {
		names = append(names, strings.TrimSuffix(name, extension))
	}
	return option.DefaultRule{
		RawDefaultRule: option.RawDefaultRule{
			ProcessName: names,
		},
		RuleAction: option.RuleAction{
			Action: C.RuleActionTypeRoute,
			RouteOptions: option.RouteActionOptions{
				Outbound: OutboundDirectTag,
			},
		},
	}, true
}

// applyDomainMatchers 按前缀把域名类条件分派到对应的匹配字段（route 侧）。
func applyDomainMatchers(raw *option.RawDefaultRule, items []string) {
	for _, item := range items {
		switch {
		case strings.HasPrefix(item, "full:"):
			raw.Domain = append(raw.Domain, strings.ToLower(strings.TrimPrefix(item, "full:")))
		case strings.HasPrefix(item, "domain:"):
			raw.DomainSuffix = append(raw.DomainSuffix, strings.ToLower(strings.TrimPrefix(item, "domain:")))
		case strings.HasPrefix(item, "keyword:"):
			raw.DomainKeyword = append(raw.DomainKeyword, strings.ToLower(strings.TrimPrefix(item, "keyword:")))
		case strings.HasPrefix(item, "regexp:"):
			raw.DomainRegex = append(raw.DomainRegex, strings.TrimPrefix(item, "regexp:"))
		case strings.HasPrefix(item, "geosite:"):
			raw.Geosite = append(raw.Geosite, strings.TrimPrefix(item, "geosite:"))
		case strings.HasPrefix(item, "ruleset:"):
			raw.RuleSet = append(raw.RuleSet, strings.TrimPrefix(item, "ruleset:"))
		case strings.HasPrefix(item, "pkg:"):
			raw.PackageName = append(raw.PackageName, strings.TrimPrefix(item, "pkg:"))
		case strings.HasPrefix(item, "procpath:"):
			raw.ProcessPath = append(raw.ProcessPath, strings.TrimPrefix(item, "procpath:"))
		case strings.HasPrefix(item, "proc:"):
			raw.ProcessName = append(raw.ProcessName, strings.TrimPrefix(item, "proc:"))
		default:
			// 无前缀按精确域名处理
			raw.Domain = append(raw.Domain, strings.ToLower(item))
		}
	}
}

// applyDomainMatchersDNS 同上，但写入 dns rule 的匹配字段。
func applyDomainMatchersDNS(raw *option.RawDefaultDNSRule, items []string) {
	for _, item := range items {
		switch {
		case strings.HasPrefix(item, "full:"):
			raw.Domain = append(raw.Domain, strings.ToLower(strings.TrimPrefix(item, "full:")))
		case strings.HasPrefix(item, "domain:"):
			raw.DomainSuffix = append(raw.DomainSuffix, strings.ToLower(strings.TrimPrefix(item, "domain:")))
		case strings.HasPrefix(item, "keyword:"):
			raw.DomainKeyword = append(raw.DomainKeyword, strings.ToLower(strings.TrimPrefix(item, "keyword:")))
		case strings.HasPrefix(item, "regexp:"):
			raw.DomainRegex = append(raw.DomainRegex, strings.TrimPrefix(item, "regexp:"))
		case strings.HasPrefix(item, "geosite:"):
			raw.Geosite = append(raw.Geosite, strings.TrimPrefix(item, "geosite:"))
		case strings.HasPrefix(item, "ruleset:"):
			raw.RuleSet = append(raw.RuleSet, strings.TrimPrefix(item, "ruleset:"))
		default:
			raw.Domain = append(raw.Domain, strings.ToLower(item))
		}
	}
}

// splitList 按逗号切分并去掉空白项。
func splitList(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		result = append(result, part)
	}
	return result
}

// makePortRanges 把 "443" / "1000:2000" 形式的端口列表拆成单端口与端口区间。
func makePortRanges(list []string) ([]uint16, []string) {
	var ports []uint16
	var ranges []string
	for _, item := range list {
		if strings.Contains(item, ":") {
			ranges = append(ranges, item)
			continue
		}
		if value, err := strconv.ParseUint(item, 10, 16); err == nil {
			ports = append(ports, uint16(value))
		}
	}
	return ports, ranges
}

// makeProtocols 把协议名列表翻译成 sing-box 的协议名。
func makeProtocols(list []string) []string {
	known := map[string]string{
		"tls":        C.ProtocolTLS,
		"http":       C.ProtocolHTTP,
		"quic":       C.ProtocolQUIC,
		"stun":       C.ProtocolSTUN,
		"dns":        C.ProtocolDNS,
		"bittorrent": C.ProtocolBitTorrent,
	}
	var result []string
	for _, item := range list {
		if protocol, ok := known[strings.ToLower(item)]; ok {
			result = append(result, protocol)
		}
	}
	return result
}
