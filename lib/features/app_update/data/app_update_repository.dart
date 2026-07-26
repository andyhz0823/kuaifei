import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/utils/utils.dart';

abstract interface class AppUpdateRepository {
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  });
}

class AppUpdateRepositoryImpl with ExceptionHandler, InfraLogger implements AppUpdateRepository {
  AppUpdateRepositoryImpl({required this.httpClient});

  final DioHttpClient httpClient;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    return exceptionHandler(() async {
      if (!release.allowCustomUpdateChecker) {
        throw Exception("custom update checkers are not supported");
      }
      final response = await httpClient.get<Map<String, dynamic>>(Constants.updateManifestUrl);
      if (response.statusCode != 200 || response.data == null) {
        loggy.warning("failed to fetch latest version info");
        return left(const AppUpdateFailure.unexpected());
      }

      final manifest = response.data!;
      final preRelease = manifest['pre_release'] == true || manifest['prerelease'] == true;
      if (preRelease && !includePreReleases) return right(_emptyVersion());

      final version = manifest['version']?.toString();
      if (version == null || version.isEmpty) return left(const AppUpdateFailure.unexpected());
      final downloads = manifest['downloads'] is Map
          ? Map<String, dynamic>.from(manifest['downloads'] as Map)
          : const <String, dynamic>{};
      final platformKey = switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.windows => 'windows',
        TargetPlatform.macOS => 'macos',
        TargetPlatform.linux => 'linux',
        _ => '',
      };
      final updateUrl =
          downloads[platformKey]?.toString() ?? manifest['url']?.toString() ?? Constants.distributionBaseUrl;

      return right(
        RemoteVersionEntity(
          version: version,
          buildNumber: manifest['build_number']?.toString() ?? '',
          releaseTag: manifest['release_tag']?.toString() ?? 'v$version',
          preRelease: preRelease,
          url: updateUrl,
          publishedAt:
              DateTime.tryParse(manifest['published_at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
          flavor: Environment.prod,
        ),
      );
    }, AppUpdateFailure.unexpected);
  }

  RemoteVersionEntity _emptyVersion() => RemoteVersionEntity(
    version: "0.0.0",
    buildNumber: "",
    releaseTag: "",
    preRelease: false,
    url: Constants.distributionBaseUrl,
    publishedAt: DateTime.fromMillisecondsSinceEpoch(0),
    flavor: Environment.prod,
  );
}
