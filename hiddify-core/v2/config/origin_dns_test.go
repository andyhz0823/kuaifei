package config

import (
	"reflect"
	"testing"
)

func TestMatchOriginDNS(t *testing.T) {
	records := map[string][]string{
		"*.kuaifei.top":      {"34.92.219.162"},
		"*.edge.kuaifei.top": {"203.0.113.10"},
		"node.kuaifei.top":   {"198.51.100.20", "invalid", "198.51.100.20"},
	}

	tests := []struct {
		name string
		host string
		want []string
	}{
		{name: "exact wins", host: "NODE.KUAIFEI.TOP.", want: []string{"198.51.100.20"}},
		{name: "longest wildcard wins", host: "hk.edge.kuaifei.top", want: []string{"203.0.113.10"}},
		{name: "wildcard matches one or more labels", host: "a.b.kuaifei.top", want: []string{"34.92.219.162"}},
		{name: "wildcard does not match apex", host: "kuaifei.top", want: nil},
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
