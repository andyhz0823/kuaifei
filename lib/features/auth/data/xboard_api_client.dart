import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/auth/data/login_doh_resolver.dart';
import 'package:hiddify/utils/custom_loggers.dart';

class XboardApiClient with InfraLogger {
  static const requestTimeout = Duration(seconds: 10);

  final Dio _dio;
  final Dio _relayDio;
  final Uri _baseUri;
  final LoginDohResolver _resolver;

  XboardApiClient({required String baseUrl})
    : _baseUri = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '')),
      _resolver = LoginDohResolver(),
      _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          headers: {'User-Agent': 'kuaifei', 'Accept': 'application/json'},
        ),
      ),
      _relayDio = Dio(
        BaseOptions(
          baseUrl: Constants.distributionBaseUrl,
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          headers: {
            'User-Agent': 'kuaifei',
            'Accept': 'application/json',
            'X-Kuaifei-Panel-Host': Uri.parse(baseUrl).host.toLowerCase(),
          },
        ),
      ) {
    _configureAdapter(_dio);
    _configureAdapter(_relayDio);
  }

  void _configureAdapter(Dio dio) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: KuaifeiOrigin.securityContext)
          ..connectionTimeout = requestTimeout
          ..findProxy = (uri) => 'DIRECT';
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          return ConnectionTask.fromSocket(_connectForUri(uri), () {});
        };
        return client;
      },
    );
  }

  bool get _canUseRelay {
    final host = _baseUri.host.toLowerCase();
    return host == 'kuaifei.top' || host.endsWith('.kuaifei.top');
  }

  Future<void> prewarm() async {
    if (_canUseRelay) {
      final relayHost = Uri.parse(Constants.distributionBaseUrl).host;
      final addresses = KuaifeiOrigin.connectionAddressesForHost(relayHost);
      loggy.debug('Auth: using DNS-independent login relay at $relayHost: ${addresses.join(', ')}');
      return;
    }

    final cached = KuaifeiOrigin.addressesForHost(_baseUri.host);
    if (cached.isNotEmpty) {
      loggy.debug('Auth: loaded cached origin routing for ${_baseUri.host}: ${cached.join(', ')}');
      return;
    }

    final resolution = await _resolver.resolve(_baseUri.host, includeHttps: true);
    final echStatus = resolution.hasEchConfig ? 'with ECH config' : 'without ECH config';
    loggy.debug(
      'Auth: DoH resolved ${_baseUri.host} to ${resolution.addresses.map((e) => e.address).join(', ')} ($echStatus)',
    );
  }

  Future<Socket> _connectForUri(Uri uri) async {
    final dohFuture = _resolver.resolve(uri.host, includeHttps: true);
    final cached = KuaifeiOrigin.connectionAddressesForHost(uri.host).map(InternetAddress.new).toList(growable: false);
    Object? cachedError;
    if (cached.isNotEmpty) {
      try {
        final socket = await _connectFirstAvailable(cached, uri.port, timeout: const Duration(seconds: 3));
        return _secureIfNeeded(uri, socket);
      } catch (error) {
        cachedError = error;
      }
    }

    try {
      final resolution = await dohFuture;
      final socket = await _connectFirstAvailable(resolution.addresses, uri.port);
      return _secureIfNeeded(uri, socket);
    } catch (error) {
      throw SocketException('Cached and DoH endpoints failed for ${uri.host}: ${cachedError ?? error}');
    }
  }

  Future<Socket> _connectFirstAvailable(
    List<InternetAddress> addresses,
    int port, {
    Duration timeout = requestTimeout,
  }) async {
    Object? lastError;
    for (final address in addresses) {
      try {
        return await Socket.connect(address, port, timeout: timeout);
      } catch (error) {
        lastError = error;
      }
    }
    throw SocketException('Unable to connect to DoH resolved address: $lastError');
  }

  Future<Socket> _secureIfNeeded(Uri uri, Socket socket) {
    if (!uri.isScheme('https')) return Future.value(socket);
    return SecureSocket.secure(socket, host: uri.host, context: KuaifeiOrigin.securityContext);
  }

  void setToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
    _relayDio.options.headers['Authorization'] = 'Bearer $token';
  }

  void clearToken() {
    _dio.options.headers.remove('Authorization');
    _relayDio.options.headers.remove('Authorization');
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
      subscribeUrl: normalizeHttpUrl(data['subscribe_url']?.toString() ?? ''),
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

  static String normalizeHttpUrl(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty || normalized.contains('://')) return normalized;
    return 'https://$normalized';
  }

  Future<Response<dynamic>> _requestWithOriginFallback(Future<Response<dynamic>> Function(Dio dio) request) async {
    if (!_canUseRelay) return request(_dio);

    try {
      return await request(_relayDio);
    } catch (relayError, stackTrace) {
      loggy.warning('Auth: login relay failed; trying the panel directly', relayError, stackTrace);
      return request(_dio);
    }
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

  bool get isUsable {
    final expiration = expireDate;
    if (expiration != null && !expiration.isAfter(DateTime.now())) return false;

    final allowance = total;
    if (allowance != null && (upload ?? 0) + (download ?? 0) >= allowance) return false;

    return true;
  }

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
            subscribeUrl: XboardApiClient.normalizeHttpUrl(item['subscribe_url']?.toString() ?? ''),
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
  final OriginDnsConfig? originDns;

  XboardAppConfig({this.purchaseUrl, this.contactEmail, this.contactText, this.originDns});

  factory XboardAppConfig.fromJson(dynamic value) {
    if (value is! Map) return XboardAppConfig();
    final json = Map<String, dynamic>.from(value);
    return XboardAppConfig(
      purchaseUrl: json['purchase_url']?.toString() ?? json['renew_url']?.toString(),
      contactEmail: json['contact_email']?.toString() ?? json['email']?.toString(),
      contactText: json['contact_text']?.toString(),
      originDns: json['origin_dns'] == null ? null : OriginDnsConfig.fromJson(json['origin_dns']),
    );
  }
}

class XboardApiException implements Exception {
  final String message;
  XboardApiException(this.message);

  @override
  String toString() => message;
}
