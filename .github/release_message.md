## Tkya 1.1.5 更新内容

- **修复登录时「网络连接失败」**：面板域名固定为 `https://www.tkya.cc.cd`，客户端写死一组可直接连的 Cloudflare 边缘 IP 绕过 DNS 污染，并把可用地址池从 4 个扩充到 6 个（新增 `104.17.0.1`、`104.18.0.1`，实测均能正常服务该域名）。
- **登录成功后记忆可用 IP**：哪个边缘 IP 完成了 TLS 握手会被持久化，下次启动排到最前面优先使用；失败的 IP 进入 30 分钟冷却并被排到队尾，登录成功时自动清理已过期的封锁记录。
- **每个 IP 独立预算**：单个边缘 IP 最多占用 1.2s，整体轮询预算 9s，避免一个被黑洞的 IP 吃掉全部重试机会。
- 订阅地址继续统一收敛到固定面板域名，历史缓存里的旧域名会被就地纠正。
- 保留 v1.1.4 全部特性：无地址输入框、按应用分流、Cloudflare TLS 失败换 IP、Tkya 全套品牌图标。

### 下载

- Android ARM64：`Tkya-v1.1.5-android-arm64-v8a.apk`
- Android ARMv7：`Tkya-v1.1.5-android-armeabi-v7a.apk`
- Windows 安装包：`tkya-1.1.5.exe`
- Windows 便携版：`tkya-1.1.5.zip`

发布附件的 SHA-256 见 `SHA256SUMS.txt`，Sigstore 验证方法见 `SIGSTORE-VERIFICATION.txt`。
