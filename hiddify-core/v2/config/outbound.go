package config

import (
	"bytes"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

type outboundMap map[string]interface{}

func patchOutboundMux(base option.Outbound, configOpt HiddifyOptions, obj outboundMap) outboundMap {
	if configOpt.Mux.Enable {
		multiplex := option.OutboundMultiplexOptions{
			Enabled:    true,
			Padding:    configOpt.Mux.Padding,
			MaxStreams: configOpt.Mux.MaxStreams,
			Protocol:   configOpt.Mux.Protocol,
		}
		obj["multiplex"] = multiplex
		// } else {
		// 	delete(obj, "multiplex")
	}
	return obj
}

func patchOutboundTLSTricks(base option.Outbound, configOpt HiddifyOptions) option.Outbound {
	if base.Type == C.TypeSelector || base.Type == C.TypeURLTest || base.Type == C.TypeBlock || base.Type == C.TypeDNS {
		return base
	}
	if isOutboundReality(base) {
		return base
	}

	var tls *option.OutboundTLSOptions
	if tlsopt, ok := base.Options.(option.OutboundTLSOptionsWrapper); ok {
		tls = tlsopt.TakeOutboundTLSOptions()
	}

	var transport *option.V2RayTransportOptions
	if opts, ok := base.Options.(option.VLESSOutboundOptions); ok {
		transport = opts.Transport
	} else if opts, ok := base.Options.(option.TrojanOutboundOptions); ok {
		transport = opts.Transport
	} else if opts, ok := base.Options.(option.VMessOutboundOptions); ok {
		transport = opts.Transport
	}

	if base.Type == C.TypeDirect {
		return patchOutboundFragment(base, configOpt)
	}

	if tls == nil || !tls.Enabled || transport == nil {
		return base
	}

	if transport.Type != C.V2RayTransportTypeWebsocket && transport.Type != C.V2RayTransportTypeGRPC && transport.Type != C.V2RayTransportTypeHTTPUpgrade {
		return base
	}

	base = patchOutboundFragment(base, configOpt)

	if tls.TLSTricks == nil {
		tls.TLSTricks = &option.TLSTricksOptions{}
	}
	tls.TLSTricks.MixedCaseSNI = tls.TLSTricks.MixedCaseSNI || configOpt.TLSTricks.MixedSNICase

	if false && configOpt.TLSTricks.EnablePadding {
		tls.TLSTricks.PaddingMode = "random"
		tls.TLSTricks.PaddingSize = configOpt.TLSTricks.PaddingSize
		tls.UTLS = &option.OutboundUTLSOptions{
			Enabled:     true,
			Fingerprint: "custom",
		}
		// fmt.Printf("--------------------%+v----%+v", tlsTricks.PaddingSize, configOpt)

	}

	// if tlsTricks.MixedCaseSNI || tlsTricks.PaddingMode != "" {
	// 	// } else {
	// 	// 	tls["tls_tricks"] = nil
	// }
	// fmt.Printf("-------%+v------------- ", tlsTricks)

	return base
}

func patchOutboundFragment(base option.Outbound, configOpt HiddifyOptions) option.Outbound {
	if configOpt.TLSTricks.EnableFragment {
		if opts, ok := base.Options.(option.DialerOptionsWrapper); ok {
			dialer := opts.TakeDialerOptions()
			dialer.TCPFastOpen = false
			dialer.TLSFragment = option.TLSFragmentOptions{
				Enabled: configOpt.TLSTricks.EnableFragment,
				Size:    configOpt.TLSTricks.FragmentSize,
				Sleep:   configOpt.TLSTricks.FragmentSleep,
			}
			opts.ReplaceDialerOptions(dialer)
		}

	}

	return base
}

func isOutboundReality(base option.Outbound) bool {
	// this function checks reality status ONLY FOR VLESS.
	// Some other protocols can also use reality, but it's discouraged as stated in the reality document
	if base.Type != C.TypeVLESS {
		return false
	}
	var tls *option.OutboundTLSOptions
	if tlsopt, ok := base.Options.(option.OutboundTLSOptionsWrapper); ok {
		tls = tlsopt.TakeOutboundTLSOptions()
	}

	if tls == nil || !tls.Enabled {
		return false
	}
	if tls.Reality == nil {
		return false
	}

	return tls.Reality.Enabled
}

func patchEndpoint(base *option.Endpoint, configOpt HiddifyOptions, staticIPs *map[string][]string) (*option.Endpoint, error) {
	formatErr := func(err error) error {
		return fmt.Errorf("error patching outbound[%s][%s]: %w", base.Tag, base.Type, err)
	}
	err := patchWarp(base, &configOpt, true, *staticIPs)
	if err != nil {
		return nil, formatErr(err)
	}
	return base, nil
}
func patchOutbound(base option.Outbound, configOpt HiddifyOptions, staticIPs *map[string][]string) (*option.Outbound, error) {

	patchOriginDomainResolver(&base, configOpt.OriginDNS, staticIPs)
	patchOutboundECH(&base)
	base = patchOutboundTLSTricks(base, configOpt)

	// switch base.Type {
	// case C.TypeVMess, C.TypeVLESS, C.TypeTrojan, C.TypeShadowsocks:
	// 	obj = patchOutboundMux(base, configOpt, obj)
	// }
	// base = patchOutboundXray(base, configOpt, *staticIPs)

	return &base, nil
}

func patchOriginDomainResolver(base *option.Outbound, records map[string][]string, staticIPs *map[string][]string) {
	opts, ok := base.Options.(option.ServerOptionsWrapper)
	if !ok {
		return
	}

	serverDomain := normalizeOriginHost(opts.TakeServerOptions().Server)
	if serverDomain == "" {
		return
	}

	// If the TCP connection server differs from TLS SNI or the WS/HTTP Host, the
	// server is acting as a CDN/preferred front door. Keep that address dynamic so
	// Cloudflare (or another CDN) can still return the best edge for the user's
	// current network even if Xboard included the front-door in origin_dns.
	if isFrontDoorOutbound(base, serverDomain) {
		setOutboundDomainResolver(base, DNSDirectTag)
		return
	}

	if addresses := matchOriginDNS(records, serverDomain); len(addresses) > 0 {
		(*staticIPs)[serverDomain] = addresses
		setOutboundDomainResolver(base, DNSStaticTag)
		return
	}

	// Explicitly use direct DNS for ordinary proxy-server domains so they are not
	// resolved through the selected proxy itself.
	setOutboundDomainResolver(base, DNSDirectTag)
}

func setOutboundDomainResolver(base *option.Outbound, server string) {
	if dialerOpts, ok := base.Options.(option.DialerOptionsWrapper); ok {
		dialer := dialerOpts.TakeDialerOptions()
		if dialer.DomainResolver != nil && dialer.DomainResolver.Server != "" {
			return
		}
		dialer.DomainResolver = &option.DomainResolveOptions{
			Server:   server,
			Strategy: option.DomainStrategy(C.DomainStrategyPreferIPv4),
		}
		dialerOpts.ReplaceDialerOptions(dialer)
	}
}

func isFrontDoorOutbound(base *option.Outbound, serverDomain string) bool {
	if serverDomain == "" {
		return false
	}
	if tlsopt, ok := base.Options.(option.OutboundTLSOptionsWrapper); ok {
		if tls := tlsopt.TakeOutboundTLSOptions(); tls != nil {
			if sni := normalizeOriginHost(tls.ServerName); sni != "" && sni != serverDomain {
				return true
			}
		}
	}
	for _, host := range outboundTransportHosts(base) {
		if normalized := normalizeOriginHost(host); normalized != "" && normalized != serverDomain {
			return true
		}
	}
	return false
}

func outboundTransportHosts(base *option.Outbound) []string {
	var transport *option.V2RayTransportOptions
	switch opts := base.Options.(type) {
	case *option.VLESSOutboundOptions:
		transport = opts.Transport
	case *option.TrojanOutboundOptions:
		transport = opts.Transport
	case *option.VMessOutboundOptions:
		transport = opts.Transport
	}
	if transport == nil {
		return nil
	}

	hosts := make([]string, 0, 2)
	switch transport.Type {
	case C.V2RayTransportTypeHTTP:
		for _, host := range transport.HTTPOptions.Host {
			hosts = append(hosts, host)
		}
		hosts = appendHTTPHeaderHosts(hosts, transport.HTTPOptions.Headers)
	case C.V2RayTransportTypeWebsocket:
		hosts = appendHTTPHeaderHosts(hosts, transport.WebsocketOptions.Headers)
	case C.V2RayTransportTypeHTTPUpgrade:
		hosts = append(hosts, transport.HTTPUpgradeOptions.Host)
		hosts = appendHTTPHeaderHosts(hosts, transport.HTTPUpgradeOptions.Headers)
	case C.V2RayTransportTypeXHTTP:
		hosts = append(hosts, strings.Split(transport.XHTTPOptions.Host, ",")...)
		for key, value := range transport.XHTTPOptions.Headers {
			if strings.EqualFold(key, "host") {
				hosts = append(hosts, value)
			}
		}
	}
	return hosts
}

func appendHTTPHeaderHosts(hosts []string, headers badoption.HTTPHeader) []string {
	for key, values := range headers {
		if !strings.EqualFold(key, "host") {
			continue
		}
		for _, value := range values {
			hosts = append(hosts, value)
		}
	}
	return hosts
}

func patchOutboundECH(base *option.Outbound) {
	if base.Type == C.TypeSelector || base.Type == C.TypeURLTest || base.Type == C.TypeBlock || base.Type == C.TypeDNS {
		return
	}
	if isOutboundReality(*base) {
		return
	}

	tlsOpt, ok := base.Options.(option.OutboundTLSOptionsWrapper)
	if !ok {
		return
	}
	tls := tlsOpt.TakeOutboundTLSOptions()
	if tls == nil || !tls.Enabled {
		return
	}

	// Xboard/Hiddify subscriptions may include a placeholder-looking ECH config
	// whose public name is ech.example.com. Do not disable ECH in that case: keep
	// the user's node compatible by asking sing-box to fetch the real HTTPS/SVCB
	// ECHConfigList for the subscription-provided SNI.
	if tls.ECH != nil && tls.ECH.Enabled {
		if hasDemoECHConfig(tls.ECH) && tls.ServerName != "" {
			tls.ECH.Config = nil
			tls.ECH.ConfigPath = ""
			tls.ECH.QueryServerName = tls.ServerName
			tlsOpt.ReplaceOutboundTLSOptions(tls)
			return
		}
		if len(tls.ECH.Config) == 0 && tls.ECH.ConfigPath == "" && tls.ECH.QueryServerName == "" && tls.ServerName != "" {
			tls.ECH.QueryServerName = tls.ServerName
			tlsOpt.ReplaceOutboundTLSOptions(tls)
		}
	}
}

func dynamicECHOptions(serverName string) *option.OutboundECHOptions {
	return &option.OutboundECHOptions{
		Enabled:         true,
		QueryServerName: serverName,
	}
}

func hasDemoECHConfig(ech *option.OutboundECHOptions) bool {
	if ech == nil || len(ech.Config) == 0 {
		return false
	}
	joined := strings.Join([]string(ech.Config), "\n")
	if strings.Contains(strings.ToLower(joined), "example.com") {
		return true
	}
	if block, rest := pem.Decode([]byte(joined)); block != nil && strings.EqualFold(block.Type, "ECH CONFIGS") && len(bytes.TrimSpace(rest)) == 0 {
		return bytes.Contains(bytes.ToLower(block.Bytes), []byte("example.com"))
	}
	compact := strings.Map(func(r rune) rune {
		switch r {
		case '\r', '\n', '\t', ' ':
			return -1
		default:
			return r
		}
	}, joined)
	if decoded, err := base64.StdEncoding.DecodeString(compact); err == nil {
		return bytes.Contains(bytes.ToLower(decoded), []byte("example.com"))
	}
	return false
}

func normalizeOriginHost(host string) string {
	domain := strings.TrimSpace(strings.ToLower(host))
	if domain == "" {
		return ""
	}
	if strings.Contains(domain, "://") {
		if parsedHost, err := getHostnameIfNotIP(domain); err == nil {
			domain = parsedHost
		}
	} else if splitHost, _, err := net.SplitHostPort(domain); err == nil && splitHost != "" {
		domain = splitHost
	}
	domain = strings.Trim(domain, "[]")
	domain = strings.TrimSuffix(domain, ".")
	for strings.HasPrefix(domain, "*.") {
		domain = strings.TrimPrefix(domain, "*.")
	}
	if domain == "" || strings.Contains(domain, "*") {
		return ""
	}
	if net.ParseIP(domain) != nil {
		return ""
	}
	return domain
}

func matchOriginDNS(records map[string][]string, host string) []string {
	host = normalizeOriginHost(host)
	if host == "" || len(records) == 0 {
		return nil
	}

	var bestPattern string
	var bestAddresses []string
	for rawPattern, rawAddresses := range records {
		pattern := strings.TrimSpace(strings.ToLower(rawPattern))
		pattern = strings.TrimSuffix(pattern, ".")
		addresses := validOriginAddresses(rawAddresses)
		if len(addresses) == 0 {
			continue
		}

		if pattern == host {
			return addresses
		}
		if !strings.HasPrefix(pattern, "*.") {
			continue
		}
		suffix := pattern[1:]
		if len(host) <= len(suffix) || !strings.HasSuffix(host, suffix) {
			continue
		}
		if len(pattern) > len(bestPattern) {
			bestPattern = pattern
			bestAddresses = addresses
		}
	}
	return bestAddresses
}

func validOriginAddresses(addresses []string) []string {
	valid := make([]string, 0, len(addresses))
	seen := make(map[string]struct{}, len(addresses))
	for _, address := range addresses {
		address = strings.TrimSpace(address)
		if net.ParseIP(address) == nil {
			continue
		}
		if _, exists := seen[address]; exists {
			continue
		}
		seen[address] = struct{}{}
		valid = append(valid, address)
	}
	return valid
}

// func patchOutboundXray(base option.Outbound, configOpt HiddifyOptions, staticIpsDns map[string][]string) outboundMap {
// 	if base.Type == C.TypeXray {
// 		if opts, ok := base.Options.(option.XrayOutboundOptions); ok {
// 			if opts.DeprecatedXrayOutboundJson != nil {
// 				opts.XConfig = opts.DeprecatedXrayOutboundJson
// 				opts.DeprecatedXrayOutboundJson = nil
// 			}
// 			if xconfig := *(opts.XConfig); xconfig != nil {
// 				if _, exists := xconfig["outbounds"]; !exists {
// 					xconfig = map[string]any{"outbounds": []any{xconfig}}
// 					opts.XConfig = &xconfig
// 				}

// 				xconfig = map[string]any{"outbounds": []any{xconfig}}
// 			}
// 		}

// 		// Ensure "outbounds" key exists within "xconfig"

// 		if configOpt.TLSTricks.EnableFragment {
// 			// TODO
// 			// if obj["xray_fragment"] == nil || obj["xray_fragment"].(map[string]any)["packets"] == "" {
// 			// 	obj["xray_fragment"] = map[string]any{
// 			// 		"packets":  "tlshello",
// 			// 		"length":   configOpt.TLSTricks.FragmentSize,
// 			// 		"interval": configOpt.TLSTricks.FragmentSleep,
// 			// 	}
// 			// }
// 		}

// 		dnsConfig, ok := xconfig["dns"].(map[string]any)
// 		if !ok {
// 			dnsConfig = map[string]any{}
// 		}
// 		if dnsConfig["tag"] == nil {
// 			dnsConfig["tag"] = "hiddify-dns-out"
// 		}
// 		// Ensure "servers" key exists and is a slice
// 		servers, ok := dnsConfig["servers"].([]any)
// 		if !ok {
// 			servers = []any{}
// 		}

// 		// Ensure "hosts" key exists and is a slice
// 		// hosts, ok := dnsConfig["hosts"].(map[string]any)
// 		// if !ok {
// 		// 	hosts = map[string]any{}
// 		// }
// 		// // for host, ip := range staticIpsDns {
// 		// // hosts[host] = ip
// 		// // }
// 		// dnsConfig["hosts"] = hosts

// 		// // Ensure "servers" key exists and is a slice
// 		// hosts, ok := dnsConfig["hosts"].([]any)
// 		// if !ok {
// 		// 	hosts = []any{}
// 		// }
// 		// for _, host := range base.DNSOptions. {
// 		// 	hosts = append(hosts, host)
// 		// }
// 		addDnsServer := func(dnsAdd string) []any {
// 			if dnsAdd == "local" {
// 				dnsAdd = "localhost"
// 			} else {
// 				dnsAdd = strings.Replace(dnsAdd, "udp://", "", 1)
// 				dnsAdd = strings.Replace(dnsAdd, "://", "+local://", 1)
// 			}
// 			for _, server := range servers {
// 				if server == dnsAdd {
// 					return servers
// 				}
// 			}
// 			return append(servers, dnsAdd)
// 		}
// 		// Append remote DNS address
// 		servers = addDnsServer(configOpt.DNSOptions.RemoteDnsAddress)
// 		servers = addDnsServer(configOpt.DNSOptions.DirectDnsAddress)
// 		servers = addDnsServer("1.1.1.1")

// 		// if outbounds, ok := xconfig["outbounds"].([]any); ok {
// 		// 	hasDns := false
// 		// 	for _, out := range outbounds {
// 		// 		if outbound, ok := out.(map[string]any); ok {
// 		// 			if outbound["tag"] == dnsConfig["tag"] {
// 		// 				hasDns = true
// 		// 			}
// 		// 		}
// 		// 	}
// 		// 	if !hasDns {
// 		// 		outbounds = append(outbounds, map[string]any{
// 		// 			"tag":      dnsConfig["tag"],
// 		// 			"protocol": "dns",
// 		// 		})
// 		// 	}
// 		// 	xconfig["outbounds"] = outbounds
// 		// }

// 		// Ensure "routing" is a map
// 		// routing, ok := xconfig["routing"].(map[string]any)
// 		// if !ok {
// 		// 	routing = map[string]any{}
// 		// }

// 		// // Ensure "rules" is a slice of maps
// 		// rules, ok := routing["rules"].([]map[string]any)
// 		// if !ok {
// 		// 	rules = []map[string]any{}
// 		// }

// 		// // Append the DNS rule
// 		// // rules = append([]map[string]any{{
// 		// // 	"type":        "field",
// 		// // 	"port":        53,
// 		// // 	"outboundTag": dnsConfig["tag"],
// 		// // }}, rules...)

// 		// routing["rules"] = rules
// 		// xconfig["routing"] = routing
// 		// Update "servers" key in "dns"
// 		dnsConfig["servers"] = servers
// 		dnsConfig["disableFallback"] = false
// 		xconfig["dns"] = dnsConfig
// 		obj["xconfig"] = xconfig
// 		obj["xdebug"] = configOpt.LogLevel == "debug" || configOpt.LogLevel == "trace"
// 	}

// 	return obj
// }

// func (o outboundMap) transportType() string {
// 	if transport, ok := o["transport"].(map[string]interface{}); ok {
// 		if transportType, ok := transport["type"].(string); ok {
// 			return transportType
// 		}
// 	}
// 	return ""
// }
