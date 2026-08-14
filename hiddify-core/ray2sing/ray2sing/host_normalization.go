package ray2sing

import (
	"net"
	"net/url"
	"strings"
)

func normalizeConnectionHost(host string) string {
	normalized := strings.TrimSpace(strings.ToLower(host))
	if normalized == "" {
		return ""
	}
	if strings.Contains(normalized, "://") {
		if parsed, err := url.Parse(normalized); err == nil && parsed.Hostname() != "" {
			normalized = parsed.Hostname()
		}
	} else if splitHost, _, err := net.SplitHostPort(normalized); err == nil && splitHost != "" {
		normalized = splitHost
	}

	normalized = strings.Trim(normalized, "[]")
	normalized = strings.TrimSuffix(normalized, ".")
	for strings.HasPrefix(normalized, "*.") {
		normalized = strings.TrimPrefix(normalized, "*.")
	}
	if normalized == "" || strings.Contains(normalized, "*") {
		return ""
	}
	if ip := net.ParseIP(normalized); ip != nil {
		return ip.String()
	}
	return normalized
}

func normalizeHostHeaderList(value string) []string {
	parts := strings.Split(value, ",")
	hosts := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		host := normalizeConnectionHost(part)
		if host == "" {
			continue
		}
		if _, ok := seen[host]; ok {
			continue
		}
		seen[host] = struct{}{}
		hosts = append(hosts, host)
	}
	return hosts
}
