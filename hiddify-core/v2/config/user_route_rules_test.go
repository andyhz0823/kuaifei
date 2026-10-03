package config

import (
	"os"
	"path/filepath"
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"google.golang.org/protobuf/proto"
)

// writeRuleFile 把规则写进临时文件并注入路径，返回清理函数。
func writeRuleFile(t *testing.T, rules []*Rule) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "route_rule.proto")
	data, err := proto.Marshal(&RouteRule{Rules: rules})
	if err != nil {
		t.Fatalf("marshal rules: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write rule file: %v", err)
	}
	SetUserRouteRulesPath(path)
	t.Cleanup(func() { SetUserRouteRulesPath("") })
}

func ruleOutbound(t *testing.T, r option.Rule) string {
	t.Helper()
	if r.Type != C.RuleTypeDefault {
		t.Fatalf("unexpected rule type: %s", r.Type)
	}
	if r.DefaultOptions.RuleAction.Action != C.RuleActionTypeRoute {
		t.Fatalf("expected route action, got %s", r.DefaultOptions.RuleAction.Action)
	}
	return r.DefaultOptions.RuleAction.RouteOptions.Outbound
}

// 1) 绑定存在的节点 tag → 直指该节点
func TestUserRuleCustomOutboundTag(t *testing.T) {
	writeRuleFile(t, []*Rule{{
		ListOrder:      0,
		Enabled:        true,
		Name:           "telegram 走香港",
		OutboundTag:    "香港-01",
		DomainSuffixes: []string{"telegram.org"},
	}})
	known := func(tag string) bool { return tag == "香港-01" || tag == OutboundSelectTag }

	rules := LoadUserRouteRules(known)
	if len(rules) != 1 {
		t.Fatalf("expected 1 rule, got %d", len(rules))
	}
	if got := ruleOutbound(t, rules[0]); got != "香港-01" {
		t.Fatalf("expected outbound 香港-01, got %s", got)
	}
}

// 2) 绑定已消失的节点 tag（订阅重置/换池）→ 回退主出口，配置不失效
func TestUserRuleUnknownOutboundTagFallsBack(t *testing.T) {
	writeRuleFile(t, []*Rule{{
		ListOrder:   0,
		Enabled:     true,
		Name:        "旧节点规则",
		OutboundTag: "已下线节点",
		Domains:     []string{"openai.com"},
	}})
	known := func(tag string) bool { return tag == OutboundSelectTag }

	rules := LoadUserRouteRules(known)
	if len(rules) != 1 {
		t.Fatalf("expected 1 rule, got %d", len(rules))
	}
	if got := ruleOutbound(t, rules[0]); got != OutboundMainDetour {
		t.Fatalf("expected fallback to %s, got %s", OutboundMainDetour, got)
	}
}

// 3) 未设置 tag → 沿用既有枚举语义（含新增字段的向后兼容）
func TestUserRuleEnumOutboundUnchanged(t *testing.T) {
	writeRuleFile(t, []*Rule{
		{ListOrder: 0, Enabled: true, Name: "直连", Outbound: Outbound_direct, Domains: []string{"bilibili.com"}},
		{ListOrder: 1, Enabled: true, Name: "代理", Outbound: Outbound_proxy, Domains: []string{"google.com"}},
		{ListOrder: 2, Enabled: false, Name: "停用", Outbound: Outbound_direct, Domains: []string{"skip.me"}},
	})
	known := func(tag string) bool { return tag == OutboundSelectTag }

	rules := LoadUserRouteRules(known)
	if len(rules) != 2 { // 停用规则应被跳过
		t.Fatalf("expected 2 enabled rules, got %d", len(rules))
	}
	if got := ruleOutbound(t, rules[0]); got != OutboundDirectTag {
		t.Fatalf("expected direct, got %s", got)
	}
	if got := ruleOutbound(t, rules[1]); got != OutboundMainDetour {
		t.Fatalf("expected main detour, got %s", got)
	}
}

// 4) 无任何匹配条件的规则不得生成（否则会命中全部流量）
func TestUserRuleWithoutMatcherIsDropped(t *testing.T) {
	writeRuleFile(t, []*Rule{{
		ListOrder:   0,
		Enabled:     true,
		Name:        "空规则",
		OutboundTag: "香港-01",
	}})
	known := func(tag string) bool { return tag == "香港-01" }

	if rules := LoadUserRouteRules(known); len(rules) != 0 {
		t.Fatalf("expected rule to be dropped, got %d", len(rules))
	}
}

// 5) outbound_tag 的 proto 往返：旧版本（无该字段）数据可正常升级读取
func TestOutboundTagProtoRoundTrip(t *testing.T) {
	in := &RouteRule{Rules: []*Rule{{
		ListOrder:    0,
		Enabled:      true,
		Name:         "tg",
		Outbound:     Outbound_proxy,
		OutboundTag:  "香港-01",
		PackageNames: []string{"org.telegram.messenger"},
	}}}
	data, err := proto.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out RouteRule
	if err := proto.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got := out.Rules[0].GetOutboundTag(); got != "香港-01" {
		t.Fatalf("round trip lost outbound_tag: %q", got)
	}
	if len(out.Rules[0].GetPackageNames()) != 1 {
		t.Fatalf("round trip lost package_names")
	}
}
