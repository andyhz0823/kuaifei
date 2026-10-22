import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class Constants {
  static const appName = "Kuaify";
  static const githubUrl = "https://github.com/andyhz0823/Xboard";
  static const licenseUrl = "https://github.com/andyhz0823/Xboard";
  static const githubReleasesApiUrl = "https://api.github.com/repos/andyhz0823/Xboard/releases";
  static const githubLatestReleaseUrl = "https://github.com/andyhz0823/Xboard/releases/latest";
  // 面板地址已对用户隐藏，登录 / 拉取订阅 / 引导端点固定走 kuaify.cc.cd（107 面板）。
  // 该域名由 Cloudflare 代理，客户端通过 KuaifyOrigin 的边缘 IP 探测直连。
  static const panelBaseUrl = "https://www.kuaify.cc.cd";
  static const panelBaseDomain = "kuaify.cc.cd";

  // 🔴 引导 / origin-dns 必须由**本品牌**面板下发。
  // 历史问题：这两个 URL 曾指向 xz.kuaity.top（216 kuaifei 面板的分发域），
  // 客户端拿回的是 216 的 client_auth_endpoints（kuaify.top / kuaifj.top /
  // kuaifei.cc.cd / xz.kuaity.top）以及含 kuaifei.top 的 origin 记录，
  // 于是登录与订阅都被带到 216，节点全是 kuaifei 那一套。
  static const bootstrapUrl = "$panelBaseUrl/api/v1/guest/client/bootstrap";
  static const originDnsUrl = "$panelBaseUrl/api/v1/guest/client/origin-dns";

  // 备用登录入口：同一面板（107）的伪装域名，解析到**另一组** CF 边缘
  // （172.67.147.95 / 104.21.41.132），用于 www.kuaify.cc.cd 整域被墙时保命。
  // 实测：bootstrap 200，payload.source 仍是 www.kuaify.cc.cd，同一套账号数据。
  static const backupPanelBaseUrl = "https://by.tkya.us.ci";
  static const backupBootstrapUrl = "$backupPanelBaseUrl/api/v1/guest/client/bootstrap";

  // 安装包 / 更新清单的公共 CDN。只承载文件，**不参与面板身份判定**。
  static const distributionBaseUrl = "https://xz.kuaity.top";
  static const updateManifestUrl = "$distributionBaseUrl/Downloads/latest.json";
  static const windowsUpdateManifestUrl = "$distributionBaseUrl/Downloads/latest-windows.json";
  static const appCastUrl = "$distributionBaseUrl/Downloads/appcast.xml";

  // 续费 / 购买页必须落回本品牌面板，不能再指向 216。
  static const purchaseUrl = "$panelBaseUrl/";
  static const telegramChannelUrl = "https://t.me/hiddify";
  static const privacyPolicyUrl = "https://hiddify.com/privacy-policy/";
  static const termsAndConditionsUrl = "https://hiddify.com/terms/";
  static const cfWarpPrivacyPolicy = "https://www.cloudflare.com/application/privacypolicy/";
  static const cfWarpTermsOfService = "https://www.cloudflare.com/application/terms/";
}

const kAnimationDuration = Duration(milliseconds: 250);

abstract class AddProfileModalConst {
  static const fixBtnsGap = 16.0;
  static const fixBtnsGapCount = 4;
  static const fixBtnsItemCount = 3;
  static const navBarGap = 16.0;
  static const navBarBottomGap = 4.0;
  //switch default height
  static const navBarcontentHeight = 32.0;
  static const navBarHeight = navBarGap + navBarBottomGap + navBarcontentHeight;
}

abstract class AlertDialogConst {
  static const minWidth = 280.0;
  static const maxWidth = 560.0;
  static const boxConstraints = BoxConstraints(minWidth: minWidth, maxWidth: maxWidth);
}

abstract class BottomSheetConst {
  static const maxWidth = 456.0;
  static const boxConstraints = BoxConstraints(maxWidth: maxWidth);
  static const borderRadius = BorderRadius.vertical(top: Radius.circular(32));
}

abstract class ProfileTileConst {
  static const radius = Radius.circular(16);
  static const cardBorderRadius = BorderRadius.all(radius);
  static const borderRadiusRight = BorderRadius.horizontal(right: radius);
  static const borderRadiusLeft = BorderRadius.horizontal(left: radius);
  static BorderRadius startBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusLeft : borderRadiusRight;
  static BorderRadius endBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusRight : borderRadiusLeft;
}

abstract class IntroConst {
  static const maxwidth = 620;
  static const termsAndConditionsKey = 'terms-and-conditions';
  static const githubKey = 'github';
  static const licenseKey = 'license';
  static const url = <String, String>{
    IntroConst.termsAndConditionsKey: Constants.termsAndConditionsUrl,
    IntroConst.githubKey: Constants.githubUrl,
    IntroConst.licenseKey: Constants.licenseUrl,
  };
}

abstract class WarpConst {
  static const warpAccountId = 'warp-account-id';
  static const warpAccessToken = "warp-access-token";
  static const warpConsentGiven = "warp-consent-given";
  static const warpTermsOfServiceKey = 'warp-terms-of-service';
  static const warpPrivacyPolicyKey = 'warp-privacy-policy';
  static const url = <String, String>{
    WarpConst.warpTermsOfServiceKey: Constants.cfWarpTermsOfService,
    WarpConst.warpPrivacyPolicyKey: Constants.cfWarpPrivacyPolicy,
  };
}

abstract class KeyboardConst {
  static final allArrows = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };
  static final horizontalArrows = {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight};
  static final verticalArrows = {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown};
  static final select = {LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.tab};
}
