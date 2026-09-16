package config

import (
	"reflect"
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func TestMatchOriginDNS(t *testing.T) {
	records := map[string][]string{
		"*.tkya.cc.cd":      {"34.92.219.162"},
		"*.edge.tkya.cc.cd": {"203.0.113.10"},
		"node.tkya.cc.cd":   {"198.51.100.20", "invalid", "198.51.100.20"},
		"*.xz.tkya.cc.cd":   {"198.51.100.30"},
		"*.kuaifj.top":      {"198.51.100.31"},
		"*.kuaify.top":      {"198.51.100.32"},
	}

	tests := []struct {
		name string
		host string
		want []string
	}{
		{name: "exact wins", host: "NODE.TKYA.CC.CD.", want: []string{"198.51.100.20"}},
		{name: "longest wildcard wins", host: "hk.edge.tkya.cc.cd", want: []string{"203.0.113.10"}},
		{name: "wildcard matches one or more labels", host: "a.b.tkya.cc.cd", want: []string{"34.92.219.162"}},
		{name: "wildcard does not match apex", host: "tkya.cc.cd", want: nil},
		{name: "update zone wildcard", host: "dl.xz.tkya.cc.cd", want: []string{"198.51.100.30"}},
		{name: "kuaifj wildcard", host: "panel.kuaifj.top", want: []string{"198.51.100.31"}},
		{name: "kuaify wildcard", host: "panel.kuaify.top", want: []string{"198.51.100.32"}},
		{name: "unmapped domain", host: "example.com", want: nil},
		{name: "ip server is ignored", host: "192.0.2.1", want: nil},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := matchOriginDNS(records, tt.host); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("matchOriginDNS(%q) = %#v, want %#v", tt.host, got, tt.want)
			}
		})
	}
}

func TestOriginDNSResolverUsesOnlySignedRecordsForStaticMapping(t *testing.T) {
	records := map[string][]string{
		"*.origin.example": {"34.92.219.162"},
		"saas.sin.fan":     {"172.67.207.145"},
	}

	preferredServer := option.Outbound{
		Type: C.TypeVLESS,
		Tag:  "preferred-front-door",
		Options: &option.VLESSOutboundOptions{
			ServerOptions: option.ServerOptions{Server: "saas.sin.fan", ServerPort: 443},
			OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{TLS: &option.OutboundTLSOptions{
				Enabled:    true,
				ServerName: "node.origin.example",
			}},
		},
	}
	staticIPs := map[string][]string{}
	patchOriginDomainResolver(&preferredServer, records, &staticIPs)
	preferredOpts := preferredServer.Options.(*option.VLESSOutboundOptions)
	if preferredOpts.DialerOptions.DomainResolver == nil || preferredOpts.DialerOptions.DomainResolver.Server != DNSDirectTag {
		t.Fatalf("front-door server should stay on direct DNS even when origin_dns has a record: %#v", preferredOpts.DialerOptions.DomainResolver)
	}
	if len(staticIPs) != 0 {
		t.Fatalf("CF preferred server domain leaked into static IP map: %#v", staticIPs)
	}

	protectedServer := option.Outbound{
		Type: C.TypeVLESS,
		Tag:  "protected-origin",
		Options: &option.VLESSOutboundOptions{
			ServerOptions: option.ServerOptions{Server: "node.origin.example", ServerPort: 443},
			OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{TLS: &option.OutboundTLSOptions{
				Enabled:    true,
				ServerName: "node.origin.example",
			}},
		},
	}
	patchOriginDomainResolver(&protectedServer, records, &staticIPs)
	protectedOpts := protectedServer.Options.(*option.VLESSOutboundOptions)
	if protectedOpts.DialerOptions.DomainResolver == nil || protectedOpts.DialerOptions.DomainResolver.Server != DNSStaticTag {
		t.Fatalf("protected server domain was not pinned to dns-static: %#v", protectedOpts.DialerOptions.DomainResolver)
	}
	if !reflect.DeepEqual(staticIPs["node.origin.example"], []string{"34.92.219.162"}) {
		t.Fatalf("protected server domain static IPs = %#v", staticIPs)
	}
}

func TestPatchOutboundECHRemovesDemoConfigForProtectedSNI(t *testing.T) {
	out := option.Outbound{
		Type: C.TypeVLESS,
		Tag:  "bad-ech-protected-sni",
		Options: &option.VLESSOutboundOptions{
			ServerOptions: option.ServerOptions{Server: "saas.sin.fan", ServerPort: 443},
			OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{TLS: &option.OutboundTLSOptions{
				Enabled:    true,
				ServerName: "node.origin.example",
				ECH: &option.OutboundECHOptions{
					Enabled: true,
					Config:  badoption.Listable[string]{"-----BEGIN ECH CONFIGS-----\nZXhhbXBsZS5jb20=\n-----END ECH CONFIGS-----"},
				},
			}},
		},
	}

	patchOutboundECH(&out)
	tls := out.Options.(*option.VLESSOutboundOptions).TLS
	if tls.ECH == nil || !tls.ECH.Enabled {
		t.Fatalf("demo ECH config should be converted to dynamic query mode, got: %#v", tls.ECH)
	}
	if tls.ECH.QueryServerName != "node.origin.example" {
		t.Fatalf("dynamic ECH should query the subscription SNI, got %#v", tls.ECH.QueryServerName)
	}
	if len(tls.ECH.Config) != 0 || tls.ECH.ConfigPath != "" {
		t.Fatalf("demo ECH config should be cleared before dynamic fetch, got %#v %#v", tls.ECH.Config, tls.ECH.ConfigPath)
	}
}

func TestPatchOutboundECHDisablesDemoConfigForUnprotectedSNI(t *testing.T) {
	out := option.Outbound{
		Type: C.TypeVLESS,
		Tag:  "bad-ech-unprotected-sni",
		Options: &option.VLESSOutboundOptions{
			ServerOptions: option.ServerOptions{Server: "www.visa.cn", ServerPort: 443},
			OutboundTLSOptionsContainer: option.OutboundTLSOptionsContainer{TLS: &option.OutboundTLSOptions{
				Enabled:    true,
				ServerName: "ut.kuaify.dpdns.org",
				ECH: &option.OutboundECHOptions{
					Enabled: true,
					Config:  badoption.Listable[string]{"-----BEGIN ECH CONFIGS-----\nZXhhbXBsZS5jb20=\n-----END ECH CONFIGS-----"},
				},
			}},
		},
	}

	patchOutboundECH(&out)
	tls := out.Options.(*option.VLESSOutboundOptions).TLS
	if tls.ECH == nil || !tls.ECH.Enabled {
		t.Fatalf("demo ECH config should stay enabled for dynamic fetch, got: %#v", tls.ECH)
	}
	if tls.ECH.QueryServerName != "ut.kuaify.dpdns.org" {
		t.Fatalf("dynamic ECH should query the node SNI, got %#v", tls.ECH.QueryServerName)
	}
}
