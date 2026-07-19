import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:hiddify/features/auth/data/login_doh_resolver.dart';
import 'package:hiddify/utils/custom_loggers.dart';

class XboardApiClient with InfraLogger {
  static const requestTimeout = Duration(seconds: 10);

  final Dio _dio;
  final Dio? _originDio;
  final Uri _baseUri;
  final LoginDohResolver _resolver;
  final String? _originIp;

  XboardApiClient({required String baseUrl})
    : _baseUri = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '')),
      _resolver = LoginDohResolver(),
      _originIp = _originIpForHost(Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '')).host),
      _originDio = _createOriginDio(Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''))),
      _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          headers: {'User-Agent': 'kuaifei', 'Accept': 'application/json'},
        ),
      ) {
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..connectionTimeout = requestTimeout
          ..findProxy = (uri) => HttpClient.findProxyFromEnvironment(uri);
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          if (proxyHost != null && proxyPort != null) {
            return ConnectionTask.fromSocket(Socket.connect(proxyHost, proxyPort, timeout: requestTimeout), () {});
          }

          final resolution = await _resolver.resolve(uri.host, includeHttps: true);
          final addresses = resolution.addresses;
          if (addresses.isEmpty) {
            return ConnectionTask.fromSocket(Socket.connect(uri.host, uri.port, timeout: requestTimeout), () {});
          }

          return ConnectionTask.fromSocket(_connectFirstAvailable(addresses, uri.port), () {});
        };
        return client;
      },
    );
  }

  static Dio? _createOriginDio(Uri baseUri) {
    final originIp = _originIpForHost(baseUri.host);
    if (originIp == null) return null;

    final originBaseUri = baseUri.replace(host: originIp);
    final dio = Dio(
      BaseOptions(
        baseUrl: originBaseUri.toString(),
        connectTimeout: requestTimeout,
        sendTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        headers: {'User-Agent': 'kuaifei', 'Accept': 'application/json', HttpHeaders.hostHeader: baseUri.host},
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..connectionTimeout = requestTimeout
          ..findProxy = (uri) => 'DIRECT';
        client.badCertificateCallback = (certificate, host, port) => host == originIp;
        return client;
      },
    );
    return dio;
  }

  static String? _originIpForHost(String host) {
    return KuaifeiOrigin.ipForHost(host);
  }

  Future<void> prewarm() async {
    final originIp = _originIp;
    if (originIp != null) {
      loggy.debug('Auth: using origin IP fallback for ${_baseUri.host} via $originIp');
      return;
    }

    final resolution = await _resolver.resolve(_baseUri.host, includeHttps: true);
    final echStatus = resolution.hasEchConfig ? 'with ECH config' : 'without ECH config';
    loggy.debug(
      'Auth: DoH resolved ${_baseUri.host} to ${resolution.addresses.map((e) => e.address).join(', ')} ($echStatus)',
    );
  }

  Future<Socket> _connectFirstAvailable(List<InternetAddress> addresses, int port) async {
    Object? lastError;
    for (final address in addresses) {
      try {
        return await Socket.connect(address, port, timeout: requestTimeout);
      } catch (error) {
        lastError = error;
      }
    }
    throw SocketException('Unable to connect to DoH resolved address: $lastError');
  }

  void setToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
    _originDio?.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearToken() {
    _dio.options.headers.remove('Authorization');
    _originDio?.options.headers.remove('Authorization');
  }

  Map<String, dynamic>? _responseBody(Response<dynamic> response) {
    final body = response.data;
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    return null;
  }

  Future<XboardLoginResult> login({required String email, required String password}) async {
    final response = await _requestWithOriginFallback(
      (dio) => dio.post('/api/v1/passport/auth/login', data: {'email': email, 'password': password}),
    );

    final body = _responseBody(response);
    if (body == null || body['status'] != 'success') {
      throw XboardApiException(body?['message']?.toString() ?? '登录失败，请检查账号密码');
    }

    final data = body['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw XboardApiException('登录返回数据异常');
    }

    final subscriptionToken = data['token']?.toString();
    final authData = data['auth_data']?.toString();

    if (subscriptionToken == null || authData == null) {
      throw XboardApiException('登录返回数据不完整');
    }

    final sanctumToken = authData.startsWith('Bearer ') ? authData.substring(7) : authData;

    return XboardLoginResult(
      subscriptionToken: subscriptionToken,
      sanctumToken: sanctumToken,
      isAdmin: data['is_admin'] as bool? ?? false,
    );
  }

  Future<XboardSubscribeResult> getSubscribe() async {
    final response = await _requestWithOriginFallback((dio) => dio.get('/api/v1/user/getSubscribe'));

    final body = _responseBody(response);
    if (body == null || body['status'] != 'success') {
      throw XboardApiException(body?['message']?.toString() ?? '获取订阅信息失败');
    }

    final data = body['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw XboardApiException('订阅数据异常');
    }

    final subscriptions = XboardSubscriptionProfile.fromList(data['subscriptions']);
    final fallbackProfile = XboardSubscriptionProfile(
      subscribeUrl: data['subscribe_url']?.toString() ?? '',
      name: data['plan'] is Map ? (data['plan'] as Map)['name']?.toString() : null,
      planId: intOrNull(data['plan_id']),
      upload: intOrNull(data['u']),
      download: intOrNull(data['d']),
      total: intOrNull(data['transfer_enable']),
      expireAt: intOrNull(data['expired_at']),
    );

    return XboardSubscribeResult(
      subscribeUrl: data['subscribe_url']?.toString() ?? '',
      subscriptions: subscriptions.isNotEmpty
          ? subscriptions
          : [if (fallbackProfile.subscribeUrl.isNotEmpty) fallbackProfile],
      planId: intOrNull(data['plan_id']),
      expiredAt: data['expired_at']?.toString(),
      email: data['email']?.toString(),
      token: data['token']?.toString(),
      appConfig: XboardAppConfig.fromJson(data['client_config'] ?? data['app_config']),
    );
  }

  static int? intOrNull(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Future<Response<dynamic>> _requestWithOriginFallback(Future<Response<dynamic>> Function(Dio dio) request) {
    final originDio = _originDio;
    if (originDio != null) {
      return request(originDio);
    }

    return request(_dio);
  }
}

class XboardLoginResult {
  final String subscriptionToken;
  final String sanctumToken;
  final bool isAdmin;

  XboardLoginResult({required this.subscriptionToken, required this.sanctumToken, required this.isAdmin});
}

class XboardSubscribeResult {
  final String subscribeUrl;
  final List<XboardSubscriptionProfile> subscriptions;
  final int? planId;
  final String? expiredAt;
  final String? email;
  final String? token;
  final XboardAppConfig appConfig;

  XboardSubscribeResult({
    required this.subscribeUrl,
    required this.subscriptions,
    this.planId,
    this.expiredAt,
    this.email,
    this.token,
    required this.appConfig,
  });
}

class XboardSubscriptionProfile {
  final String subscribeUrl;
  final String? name;
  final int? planId;
  final int? subscriptionId;
  final int? upload;
  final int? download;
  final int? total;
  final int? expireAt;

  XboardSubscriptionProfile({
    required this.subscribeUrl,
    this.name,
    this.planId,
    this.subscriptionId,
    this.upload,
    this.download,
    this.total,
    this.expireAt,
  });

  bool get hasSubscriptionInfo => total != null && expireAt != null;

  DateTime? get expireDate {
    final value = expireAt;
    if (value == null || value <= 0) return null;
    final milliseconds = value > 9999999999 ? value : value * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  Map<String, dynamic> toJson() => {
    'subscribe_url': subscribeUrl,
    'name': name,
    'plan_id': planId,
    'subscription_id': subscriptionId,
    'upload': upload,
    'download': download,
    'total': total,
    'expire_at': expireAt,
  };

  static List<XboardSubscriptionProfile> fromList(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .map(
          (item) => XboardSubscriptionProfile(
            subscribeUrl: item['subscribe_url']?.toString() ?? '',
            name: item['plan_name']?.toString(),
            planId: XboardApiClient.intOrNull(item['plan_id']),
            subscriptionId: XboardApiClient.intOrNull(item['id']),
            upload: XboardApiClient.intOrNull(item['u'] ?? item['upload']),
            download: XboardApiClient.intOrNull(item['d'] ?? item['download']),
            total: XboardApiClient.intOrNull(item['transfer_enable'] ?? item['total']),
            expireAt: XboardApiClient.intOrNull(item['expired_at'] ?? item['expire_at'] ?? item['expire']),
          ),
        )
        .where((item) => item.subscribeUrl.isNotEmpty)
        .toList(growable: false);
  }

  factory XboardSubscriptionProfile.fromJson(Map<String, dynamic> json) {
    return XboardSubscriptionProfile(
      subscribeUrl: json['subscribe_url']?.toString() ?? '',
      name: json['name']?.toString(),
      planId: XboardApiClient.intOrNull(json['plan_id']),
      subscriptionId: XboardApiClient.intOrNull(json['subscription_id']),
      upload: XboardApiClient.intOrNull(json['upload']),
      download: XboardApiClient.intOrNull(json['download']),
      total: XboardApiClient.intOrNull(json['total']),
      expireAt: XboardApiClient.intOrNull(json['expire_at']),
    );
  }
}

class XboardAppConfig {
  final String? purchaseUrl;
  final String? contactEmail;
  final String? contactText;

  XboardAppConfig({this.purchaseUrl, this.contactEmail, this.contactText});

  factory XboardAppConfig.fromJson(dynamic value) {
    if (value is! Map) return XboardAppConfig();
    final json = Map<String, dynamic>.from(value);
    return XboardAppConfig(
      purchaseUrl: json['purchase_url']?.toString() ?? json['renew_url']?.toString(),
      contactEmail: json['contact_email']?.toString() ?? json['email']?.toString(),
      contactText: json['contact_text']?.toString(),
    );
  }
}

class XboardApiException implements Exception {
  final String message;
  XboardApiException(this.message);

  @override
  String toString() => message;
}
