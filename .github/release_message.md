<div align=center>
    
[![Release Downloads](https://img.shields.io/github/downloads/hiddify/hiddify-next/RELEASE_TAG/total?style=flat-square&logo=github)](https://img.shields.io/github/downloads/hiddify/hiddify-next/RELEASE_TAG/)

</div>

## Tkya 1.1.1 更新内容

**分流规则支持绑定具体节点**（Karing 式按应用 / 按域名分流）：

- 规则新增「自定义出站节点」：可指定任意节点，或 `select` / `lowest`（延迟最低）/ `balance`（负载均衡）策略组
- 按应用分流：Telegram、ChatGPT 等可各自走不同节点（Android 按包名，桌面端按进程名）
- 按域名分流：指定域名 / 域名后缀 / 关键词 / 正则，各走各的节点
- 容错：订阅刷新后节点消失时，规则自动回退主出口，不会导致整份配置失效
- 优先级修正：自定义规则优先于「区域 = 中国」等内置大盘规则
- 国内直连改为内核规则集（geosite-cn + geoip-cn，自动定时更新），不再依赖手写域名列表
- 旧规则数据无需迁移，未指定节点的规则行为与之前完全一致

---

**Download based on your OS:**

<div dir="rtl">

**بر اساس سیستم عامل خود دانلود کنید:**

</div>



<div align=left>
<table>
    <thead align=left>
        <tr>
            <th>OS</th>
            <th>Download</th>
        </tr>
    </thead>
    <tbody align=left>
        <tr>
        <td>Android</td><td>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Android-universal.apk"><img src="https://img.shields.io/badge/APK-Universal-044d29.svg?logo=android"></a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Android-arm64.apk"><img src="https://img.shields.io/badge/APK-ARMv8-168039.svg?logo=android"></a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Android-arm7.apk"><img src="https://img.shields.io/badge/APK-ARMv7-45bf55.svg?logo=android"></a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Android-x86_64.apk"><img src="https://img.shields.io/badge/APK-x64-96ed89.svg?logo=android"></a>
        </td>
        </tr>
        <tr>
            <td>Windows</td><td>
                <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Windows-Setup-x64.Msix"><img src="https://img.shields.io/badge/OfficialSetup-x64-0078d7.svg?logo=windows"></a><br>
                <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Windows-Setup-x64.exe"><img src="https://img.shields.io/badge/Setup-x64-2d7d9a.svg?logo=windows"></a><br>
                <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Windows-Portable-x64.zip"><img src="https://img.shields.io/badge/Portable-x64-67b7d1.svg?logo=windows"></a>
        </td>
        </tr>
        <tr>
            <td>macOS (v10.15+)</td>
            <td><a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-MacOS.dmg"><img src="https://img.shields.io/badge/DMG-Universal-ea005e.svg?logo=apple"></a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-MacOS-Installer.pkg"><img src="https://img.shields.io/badge/PKG-Universal-bc544b.svg?logo=apple" /></a></a></td>
        </tr>
        <tr>
            <td>Linux</td>
            <td><a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Linux-x64.AppImage"><img src="https://img.shields.io/badge/AppImage-x64-f84e29.svg?logo=linux"> </a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-Debian-x64.deb"><img src="https://img.shields.io/badge/DebPackage-x64-FF9966.svg?logo=debian"> </a><br>
            <a href="https://github.com/hiddify/hiddify-app/releases/download/RELEASE_TAG/Hiddify-rpm-x64.rpm"><img src="https://img.shields.io/badge/RpmPackage-x64-F1B42F.svg?logo=redhat"> </a></td>
        </tr>
    </tbody>
</table>


</div>

<div dir="ltr">
  
**List of all changes:** [ChangeLog](https://github.com/hiddify/hiddify-app/blob/main/HISTORY.md)

</div>
