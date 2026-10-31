## Tkya 1.1.4 更新内容

- **修复登录后配置列表为空**：面板会从 `subscribe_url` 列表随机挑一个域名下发订阅地址，挑到 `tkya.cc.cd`（apex）时部分网络的 TLS 握手会被中间设备直接打断，订阅永远下载失败。现在订阅地址统一收敛到固定的面板域名 `https://www.tkya.cc.cd`，本地已缓存的旧域名也会被就地纠正。
- 面板侧已同步把 `subscribe_url` 固定为 `www.tkya.cc.cd`，不再随机分流到 apex。
- 保留 v1.1.3 的全部特性：固定面板、无地址输入框、按应用分流、Cloudflare TLS 失败换 IP、4 个 CF 边缘 IP 及重试顺序。
- 应用名称、UI 顶部品牌、启动图、通知图标、桌面图标与安装包元数据保持 Tkya。

### 下载

- Android ARM64：`Tkya-v1.1.4-android-arm64-v8a.apk`
- Android ARMv7：`Tkya-v1.1.4-android-armeabi-v7a.apk`
- Windows 安装包：`tkya-1.1.4.exe`
- Windows 便携版：`tkya-1.1.4.zip`

发布附件的 SHA-256 见 `SHA256SUMS.txt`，Sigstore 验证方法见 `SIGSTORE-VERIFICATION.txt`。
