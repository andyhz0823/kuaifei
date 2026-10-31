## Tkya 1.1.6 更新内容

- **修复「登录成功但配置文件不同步」**：面板下发的订阅地址域名（`www.tkya.cc.cd`）在部分网络会被 TLS 掐断，而登录用的分发域 `xz.tkya.cc.cd` 是通的。现在订阅下载失败时会自动改写到分发域，带上 `X-Tkya-Panel-Host` 请求头把 `/vip/<token>` 转回面板，路径与参数保持不变。
- 备用端点候选顺序：固定分发域 → 上次登录成功的端点 → 面板下发的其它端点；不再要求「原域名必须属于端点池」才兜底。
- 保留 v1.1.5 全部特性：CF 边缘 IP 自动优选（17 个候选，只认 HTTP 200）、可用 IP 记忆与优先、失败 IP 30 分钟冷却、单 IP 1.2s 预算。
- 保留 v1.1.4 全部特性：订阅地址统一收敛到固定面板域名、无地址输入框、按应用分流、Tkya 全套品牌图标。

### 下载

- Android ARM64：`Tkya-v1.1.6-android-arm64-v8a.apk`
- Android ARMv7：`Tkya-v1.1.6-android-armeabi-v7a.apk`
- Windows 安装包：`tkya-1.1.6.exe`
- Windows 便携版：`tkya-1.1.6.zip`

发布附件的 SHA-256 见 `SHA256SUMS.txt`，Sigstore 验证方法见 `SIGSTORE-VERIFICATION.txt`。
