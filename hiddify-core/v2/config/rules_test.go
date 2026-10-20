package config

import (
	"encoding/json"
	"testing"

	C "github.com/sagernet/sing-box/constant"
)

func TestSplitRuleMakeRouteRule(t *testing.T) {
	rule := &SplitRule{
		Domains:  "full:ads.example.com,domain:example.com,keyword:tracker,regexp:^ad[0-9]+,pkg:com.example.app,proc:example.exe,procpath:C:\\app\\example.exe,ruleset:my-set",
		Ip:       "geoip:cn,10.0.0.0/8",
		Port:     "443,1000:2000",
		Network:  "tcp",
		Protocol: "tls,quic",
		Outbound: "proxy",
	}

	got, ok := rule.MakeRouteRule()
	if !ok {
		t.Fatal("expected rule to be valid")
	}
	if got.Action != C.RuleActionTypeRoute {
		t.Fatalf("expected route action, got %q", got.Action)
	}
	if got.RouteOptions.Outbound != OutboundMainDetour {
		t.Fatalf("expected outbound %q, got %q", OutboundMainDetour, got.RouteOptions.Outbound)
	}
	if len(got.Domain) != 1 || got.Domain[0] != "ads.example.com" {
		t.Fatalf("unexpected domain: %v", got.Domain)
	}
	if len(got.DomainSuffix) != 1 || got.DomainSuffix[0] != "example.com" {
		t.Fatalf("unexpected domain suffix: %v", got.DomainSuffix)
	}
	if len(got.DomainKeyword) != 1 || got.DomainKeyword[0] != "tracker" {
		t.Fatalf("unexpected domain keyword: %v", got.DomainKeyword)
	}
	if len(got.DomainRegex) != 1 {
		t.Fatalf("unexpected domain regex: %v", got.DomainRegex)
	}
	if len(got.PackageName) != 1 || got.PackageName[0] != "com.example.app" {
		t.Fatalf("unexpected package name: %v", got.PackageName)
	}
	if len(got.ProcessName) != 1 || got.ProcessName[0] != "example.exe" {
		t.Fatalf("unexpected process name: %v", got.ProcessName)
	}
	if len(got.ProcessPath) != 1 {
		t.Fatalf("unexpected process path: %v", got.ProcessPath)
	}
	if len(got.RuleSet) != 1 || got.RuleSet[0] != "my-set" {
		t.Fatalf("unexpected rule set: %v", got.RuleSet)
	}
	if len(got.IPCIDR) != 1 || got.IPCIDR[0] != "10.0.0.0/8" {
		t.Fatalf("unexpected ip cidr: %v", got.IPCIDR)
	}
	if len(got.GeoIP) != 1 || got.GeoIP[0] != "cn" {
		t.Fatalf("unexpected geoip: %v", got.GeoIP)
	}
	if len(got.Port) != 1 || got.Port[0] != 443 {
		t.Fatalf("unexpected port: %v", got.Port)
	}
	if len(got.PortRange) != 1 || got.PortRange[0] != "1000:2000" {
		t.Fatalf("unexpected port range: %v", got.PortRange)
	}
	if len(got.Network) != 1 || got.Network[0] != "tcp" {
		t.Fatalf("unexpected network: %v", got.Network)
	}
	if len(got.Protocol) != 2 {
		t.Fatalf("unexpected protocol: %v", got.Protocol)
	}
}

func TestSplitRuleOutboundTargets(t *testing.T) {
	cases := []struct {
		outbound string
		wantTag  string
		wantAct  string
	}{
		{"proxy", OutboundMainDetour, C.RuleActionTypeRoute},
		{"direct", OutboundDirectTag, C.RuleActionTypeRoute},
		{"bypass", OutboundDirectTag, C.RuleActionTypeRoute},
		{"direct_with_fragment", OutboundDirectFragmentTag, C.RuleActionTypeRoute},
		{"block", "", C.RuleActionTypeReject},
		// 指定具体节点 / 策略组：直接用名字当 outbound tag
		{"HK-01", "HK-01", C.RuleActionTypeRoute},
	}
	for _, c := range cases {
		rule := &SplitRule{Domains: "example.com", Outbound: c.outbound}
		got, ok := rule.MakeRouteRule()
		if !ok {
			t.Fatalf("outbound %q: expected valid rule", c.outbound)
		}
		if got.Action != c.wantAct {
			t.Fatalf("outbound %q: expected action %q, got %q", c.outbound, c.wantAct, got.Action)
		}
		if got.RouteOptions.Outbound != c.wantTag {
			t.Fatalf("outbound %q: expected tag %q, got %q", c.outbound, c.wantTag, got.RouteOptions.Outbound)
		}
	}
}

func TestSplitRuleWithoutMatcherIsIgnored(t *testing.T) {
	rule := &SplitRule{Outbound: "proxy"}
	if _, ok := rule.MakeRouteRule(); ok {
		t.Fatal("rule without any matcher must be ignored")
	}
}

func TestSplitRuleBlockGeneratesDNSRule(t *testing.T) {
	rule := &SplitRule{Domains: "domain:ads.example.com", Outbound: "block"}
	dnsRule, ok := rule.MakeDNSRule()
	if !ok {
		t.Fatal("block rule must produce a dns rule")
	}
	if len(dnsRule.DomainSuffix) != 1 {
		t.Fatalf("unexpected dns domain suffix: %v", dnsRule.DomainSuffix)
	}
	if _, ok := (&SplitRule{Domains: "example.com", Outbound: "proxy"}).MakeDNSRule(); ok {
		t.Fatal("non-block rule must not produce a dns rule")
	}
}

// 模拟客户端下发的 JSON：字段名与 Dart 侧 SingboxRule 的序列化结果一致。
func TestSplitRuleJSONRoundTrip(t *testing.T) {
	payload := `{
		"rules": [
			{
				"rule-set-url": "",
				"domains": "domain:example.com,pkg:com.example.app",
				"ip": "10.0.0.0/8",
				"port": "443",
				"network": "tcp",
				"protocol": "tls",
				"outbound": "bypass"
			}
		]
	}`

	var options HiddifyOptions
	if err := json.Unmarshal([]byte(payload), &options); err != nil {
		t.Fatalf("failed to unmarshal options: %v", err)
	}
	if len(options.Rules) != 1 {
		t.Fatalf("expected 1 rule, got %d", len(options.Rules))
	}
	rule := options.Rules[0]
	if rule.Domains != "domain:example.com,pkg:com.example.app" {
		t.Fatalf("unexpected domains: %q", rule.Domains)
	}
	if rule.Outbound != "bypass" {
		t.Fatalf("unexpected outbound: %q", rule.Outbound)
	}

	got, ok := rule.MakeRouteRule()
	if !ok {
		t.Fatal("expected rule to be valid")
	}
	if got.RouteOptions.Outbound != OutboundDirectTag {
		t.Fatalf("expected outbound %q, got %q", OutboundDirectTag, got.RouteOptions.Outbound)
	}
	if len(got.PackageName) != 1 {
		t.Fatalf("unexpected package name: %v", got.PackageName)
	}
}
