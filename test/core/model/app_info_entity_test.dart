import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/app_info_entity.dart';
import 'package:hiddify/core/model/environment.dart';

void main() {
  test('uses one display value for the brand and package version', () {
    const appInfo = AppInfoEntity(
      name: 'tkya',
      version: '4.1.6',
      buildNumber: '40106',
      release: Release.general,
      operatingSystem: 'windows',
      operatingSystemVersion: '11',
      environment: Environment.prod,
    );

    expect(appInfo.displayNameWithVersion, 'Tkya v4.1.6');
  });
}
