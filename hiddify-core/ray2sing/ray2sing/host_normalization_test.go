package ray2sing

import "testing"

func TestNormalizeConnectionHost(t *testing.T) {
	tests := map[string]string{
		"*.kuaifei.top":           "kuaifei.top",
		"HTTPS://WK.KUAIFEI.TOP/": "wk.kuaifei.top",
		"wk.kuaifei.top:443":      "wk.kuaifei.top",
		"[2001:db8::1]":           "2001:db8::1",
		"[2001:db8::1]:443":       "2001:db8::1",
		"example.com.":            "example.com",
		"bad*.example.com":        "",
		"192.0.2.1":               "192.0.2.1",
	}

	for input, want := range tests {
		if got := normalizeConnectionHost(input); got != want {
			t.Fatalf("normalizeConnectionHost(%q) = %q, want %q", input, got, want)
		}
	}
}
