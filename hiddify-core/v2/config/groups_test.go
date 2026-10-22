package config

import (
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func TestSplitGroupMakeOutbound(t *testing.T) {
	available := map[string]bool{
		"HK-01": true,
		"HK-02": true,
		"US-01": true,
	}

	// selector 组：过滤掉不存在的节点
	group := &SplitGroup{Name: "香港组", Type: "selector", Outbounds: []string{"HK-01", "HK-02", "NOT-EXIST"}}
	out, ok := group.makeOutbound(available)
	if !ok {
		t.Fatal("expected group to be valid")
	}
	if out.Tag != "香港组" || out.Type != C.TypeSelector {
		t.Fatalf("unexpected outbound: type=%s tag=%s", out.Type, out.Tag)
	}
	opts, ok := out.Options.(*option.SelectorOutboundOptions)
	if !ok {
		t.Fatalf("expected selector options, got %T", out.Options)
	}
	if len(opts.Outbounds) != 2 {
		t.Fatalf("expected 2 members, got %v", opts.Outbounds)
	}

	// urltest 组
	urltest := &SplitGroup{Name: "自动", Type: "urltest", Outbounds: []string{"US-01"}}
	out2, ok := urltest.makeOutbound(available)
	if !ok || out2.Type != C.TypeURLTest {
		t.Fatalf("expected urltest, got type=%s ok=%v", out2.Type, ok)
	}

	// 全部成员不存在 → 跳过
	empty := &SplitGroup{Name: "空组", Type: "selector", Outbounds: []string{"NOPE"}}
	if _, ok := empty.makeOutbound(available); ok {
		t.Fatal("group with no available members must be skipped")
	}

	// 空名称 → 跳过
	noname := &SplitGroup{Name: "", Type: "selector", Outbounds: []string{"HK-01"}}
	if _, ok := noname.makeOutbound(available); ok {
		t.Fatal("group with empty name must be skipped")
	}
}
