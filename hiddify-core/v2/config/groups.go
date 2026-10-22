package config

import (
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

// SplitGroup 是客户端下发的「用户自定义策略组」。
// 字段名与 Dart 侧序列化结果保持一致（kebab-case）。
//
// 与内置的「节点选择 / 自动选择」不同，用户组让用户把任意节点子集组成一个组，
// 分流规则可通过 outbound-target 指向这个组的 name（= sing-box outbound tag）。
type SplitGroup struct {
	Name      string   `json:"name,omitempty"`
	Type      string   `json:"type,omitempty"` // selector（默认）/ urltest
	Outbounds []string `json:"outbounds,omitempty"`
}

// makeOutbound 把一条用户组定义翻译成 sing-box 的 outbound。
// availableTags 是当前订阅里真实存在的节点 tag，组内不存在的成员会被剔除；
// 第二个返回值为 false 表示组里没有任何可用成员，应当跳过。
func (g *SplitGroup) makeOutbound(availableTags map[string]bool) (option.Outbound, bool) {
	if g == nil || g.Name == "" {
		return option.Outbound{}, false
	}

	var members []string
	seen := map[string]bool{}
	for _, tag := range g.Outbounds {
		if !availableTags[tag] || seen[tag] {
			continue
		}
		seen[tag] = true
		members = append(members, tag)
	}
	if len(members) == 0 {
		return option.Outbound{}, false
	}

	switch g.Type {
	case "urltest":
		return option.Outbound{
			Type: C.TypeURLTest,
			Tag:  g.Name,
			Options: &option.URLTestOutboundOptions{
				Outbounds: members,
			},
		}, true
	default:
		return option.Outbound{
			Type: C.TypeSelector,
			Tag:  g.Name,
			Options: &option.SelectorOutboundOptions{
				Outbounds:                 members,
				Default:                   members[0],
				InterruptExistConnections: true,
			},
		}, true
	}
}
