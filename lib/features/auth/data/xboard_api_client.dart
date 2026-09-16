import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:hiddify/core/http_client/tkya_origin.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/auth/data/login_doh_resolver.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class XboardApiClient with InfraLogger {
  static const subscriptionFlag = 'hiddify';
  static const defaultUserAgent = 'hiddify/4.1.0';
  static const requestTimeout = Duration(seconds: 8);
  static const mappedConnectTimeout = Duration(seconds: 3);
  static const prewarmTimeout = Duration(seconds: 2);
  static const preferredEndpointTimeout = Duration(seconds: 3);
  static const _directTransportId = 'panel-direct';
  static const _fixedRelayTransportId = 'relay-xz';

  final Dio _dio;
  final Dio _relayDio;
  final Uri _baseUri;
  final LoginDohResolver _resolver;
  final SharedPreferences? _preferences;
  final Map<String, Dio> _transportDios = <String, Dio>{};
  final Map<String, String> _transportUrls = <String, String>{};

  XboardApiClient({required String baseUrl, String userAgent = defaultUserAgent, SharedPreferences? preferences})
    : _baseUri = Uri.parse(normalizeHttpUrl(baseUrl).replaceAll(RegExp(r'/+$'), '')),
      _resolver = LoginDohResolver(preferences: preferences, timeout: const Duration(seconds: 2)),
      _preferences = preferences,
      _dio = Dio(
        BaseOptions(
          baseUrl: normalizeHttpUrl(baseUrl).replaceAll(RegExp(r'/+$'), ''),
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          responseType: ResponseType.bytes,
          headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
        ),
      ),
      _relayDio = Dio(
        BaseOptions(
          baseUrl: Constants.distributionBaseUrl,
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent': userAgent,
            'Accept': 'application/json',
            'X-Tkya-Panel-Host': Uri.parse(normalizeHttpUrl(baseUrl)).host.toLowerCase(),
          },
        ),
      ) {
    _configureAdapter(_dio);
    _configureAdapter(_relayDio);
    _transportDios[_directTransportId] = _dio;
    _transportUrls[_directTransportId] = _baseUri.toString();
    _transportDios[_fixedRelayTransportId] = _relayDio;
    _transportUrls[_fixedRelayTransportId] = Constants.distributionBaseUrl;
    _configureDynamicEndpoints(userAgent);
    _restorePreferredEndpoint();
  }

  void _configureDynamicEndpoints(String userAgent) {
    final endpoints = <ClientAuthEndpoint>[...TkyaOrigin.config.authEndpoints];
    if (endpoints.isEmpty) {
      final cached = _preferences?.getString(TkyaOrigin.endpointPoolPreferenceKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          final decoded = jsonDecode(cached);
          if (decoded is List) {
            endpoints.addAll(decoded.map(ClientAuthEndpoint.fromJson).where((endpoint) => endpoint.isUsable));
          }
        } catch (_) {
          // A malformed endpoint cache is ignored; direct and fixed relay remain available.
        }
      }
    }
    endpoints.sort((left, right) => left.priority.compareTo(right.priority));

    for (final endpoint in endpoints.take(8)) {
      final normalizedUrl = normalizeHttpUrl(endpoint.url).replaceAll(RegExp(r'/+$'), '');
      if (normalizedUrl.isEmpty || _transportUrls.containsValue(normalizedUrl)) continue;
      final headers = <String, dynamic>{
        'User-Agent': userAgent,
        'Accept': 'application/json',
        'X-Tkya-Panel-Host': _baseUri.host.toLowerCase(),
      };
      if (endpoint.routeId != null) headers['X-Tkya-Route-Id'] = endpoint.routeId;
      final dio = Dio(
        BaseOptions(
          baseUrl: normalizedUrl,
          connectTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          receiveTimeout: requestTimeout,
          responseType: ResponseType.bytes,
          headers: headers,
        ),
      );
      _configureAdapter(dio);
      final transportId = endpoint.id.isEmpty ? 'endpoint-${_transportDios.length}' : endpoint.id;
      _transportDios[transportId] = dio;
      _transportUrls[transportId] = normalizedUrl;
    }
  }

  void _restorePreferredEndpoint() {
    final cached = _preferences?.getString(TkyaOrigin.lastKnownGoodEndpointPreferenceKey);
    if (cached == null || cached.isEmpty) return;
    try {
      final decoded = jsonDecode(cached);
      final cachedUrl = decoded is Map ? decoded['url']?.toString() : decoded.toString();
      if (cachedUrl == null || cachedUrl.isEmpty) return;
      final normalized = normalizeHttpUrl(cachedUrl).replaceAll(RegExp(r'/+$'), '');
      for (final entry in _transportUrls.entries) {
        if (entry.value == normalized) {
          _preferredTransport = entry.key;
          break;
        }
      }
    } catch (_) {
      // Ignore malformed last-known-good endpoint state.
    }
  }

  void _rememberSuccessfulEndpoint(String transport) {
    final endpointUrl = _transportUrls[transport];
    if (endpointUrl == null || _preferences == null) return;
    unawaited(
      _preferences.setString(
        TkyaOrigin.lastKnownGoodEndpointPreferenceKey,
        jsonEncode({'id': transport, 'url': endpointUrl, 'saved_at': DateTime.now().millisecondsSinceEpoch}),
      ),
    );
  }

  void _configureAdapter(Dio dio) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: TkyaOrigin.securityContext)
          ..connectionTimeout = requestTimeout
          ..findProxy = (uri) => 'DIRECT';
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          return ConnectionTask.fromSocket(_connectForUri(uri), () {});
        };
        return client;
      },
    );
  }

  String? _preferredTransport;

  Future<void> prewarm() async {
    final cached = TkyaOrigin.addressesForHost(_baseUri.host);
    if (cached.isNotEmpty) {
      loggy.debug('Auth: loaded cached origin routing for ${_baseUri.host}: ${cached.join(', ')}');
      return;
    }

    // DoH prewarm is deliberately best-effort. Login itself races the direct
    // path and the relay path, so prewarm must never add seconds of spinner time.
    unawaited(
      _resolver
          .resolve(_baseUri.host, includeIpv6: false)
          .timeout(prewarmTimeout)
          .then((resolution) {
            loggy.debug(
              'Auth: DoH prewarmed ${_baseUri.host} to ${resolution.addresses.map((e) => e.address).join(', ')}',
            );
          })
          .catchError((Object error) {
            loggy.debug('Auth: DoH prewarm skipped for ${_baseUri.host}: $error');
          }),
    );
  }

  Future<Socket> _connectForUri(Uri uri) async {
    final cached = TkyaOrigin.connectionAddressesForHost(uri.host).map(InternetAddress.new).toList(growable: false);
    Object? lastError;
    if (cached.isNotEmpty) {
      try {
        final socket = await _connectFirstAvailable(cached, uri.port, timeout: mappedConnectTimeout);
        return _secureIfNeeded(uri, socket);
      } catch (error) {
        lastError = error;
      }
    }

    try {
      final resolution = await _resolver.resolve(uri.host).timeout(requestTimeout);
      if (resolution.addresses.isNotEmpty) {
        final socket = await _connectFirstAvailable(resolution.addresses, uri.port, timeout: mappedConnectTimeout);
        return _secureIfNeeded(uri, socket);
      }
    } catch (error) {
      lastError = error;
    }

    // Last local fallback: let the platform resolver try. If DNS is polluted,
    // hostname verification should fail after TLS and the relay race can still win.
    try {
      final socket = await Socket.connect(uri.host, uri.port, timeout: mappedConnectTimeout);
      return _secureIfNeeded(uri, socket);
    } catch (error) {
      throw SocketException('Cached, DoH and system endpoints failed for ${uri.host}: ${lastError ?? error}');
    }
  }

  Future<Socket> _connectFirstAvailable(
    List<InternetAddress> addresses,
    int port, {
    Duration timeout = requestTimeout,
  }) async {
    if (addresses.isEmpty) throw const SocketException('No resolved addresses available');
    Object? lastError;
    for (final address in addresses) {
      try {
        return await Socket.connect(address, port, timeout: timeout);
      } catch (error) {
        lastError = error;
      }
    }
    throw SocketException('Unable to connect to resolved address: $lastError');
  }

  Future<Socket> _secureIfNeeded(Uri uri, Socket socket) {
    if (!uri.isScheme('https')) return Future.value(socket);
    return SecureSocket.secure(socket, host: uri.host, context: TkyaOrigin.securityContext);
  }

  void setToken(String token) {
    for (final dio in _transportDios.values.toSet()) {
      dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  void clearToken() {
    for (final dio in _transportDios.values.toSet()) {
      dio.options.headers.remove('Authorization');
    }
  }

  Map<String, dynamic>? _responseBody(Response<dynamic> response) {
    final body = response.data;
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    if (body is List<int>) {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    if (body is String) {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<XboardLoginResult> login({required String email, required String password}) async {
    final response = await _requestWithOriginFallback(
      (dio, cancelToken) => dio.post(
        '/api/v1/passport/auth/login',
        data: {'email': email, 'password': password},
        cancelToken: cancelToken,
      ),
    );

    final body = _responseBody(response);
    if (body == null || body['status'] != 'success') {
      throw XboardApiException(body?['message']?.toString() ?? 'Login failed, please check account and password');
    }

    final data = body['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw XboardApiException('Login response data is invalid');
    }

    final subscriptionToken = data['token']?.toString();
    final authData = data['auth_data']?.toString();

    if (subscriptionToken == null || authData == null) {
      throw XboardApiException('Login response is incomplete');
    }

    final sanctumToken = authData.startsWith('Bearer ') ? authData.substring(7) : authData;

    return XboardLoginResult(
      subscriptionToken: subscriptionToken,
      sanctumToken: sanctumToken,
      isAdmin: data['is_admin'] as bool? ?? false,
    );
  }

  Future<XboardSubscribeResult> getSubscribe() async {
    final response = await _requestWithOriginFallback(
      (dio, cancelToken) => dio.get('/api/v1/user/getSubscribe', cancelToken: cancelToken),
    );

    final body = _responseBody(response);
    if (body == null || body['status'] != 'success') {
      throw XboardApiException(body?['message']?.toString() ?? 'Login failed, please check account and password');
    }

    final data = body['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw XboardApiException('Subscription response data is invalid');
    }

    var subscriptions = XboardSubscriptionProfile.fromList(data['subscriptions']);
    if (subscriptions.isEmpty) subscriptions = XboardSubscriptionProfile.fromList(data['plans']);
    if (subscriptions.isEmpty) subscriptions = XboardSubscriptionProfile.fromList(data['profiles']);

    final subscribeUrl = firstString(data, const ['subscribe_url', 'subscription_url', 'subscribeUrl', 'url', 'link']);
    final fallbackName = data['plan'] is Map
        ? firstString(Map<String, dynamic>.from(data['plan'] as Map), const ['name', 'plan_name', 'title'])
        : firstString(data, const ['plan_name', 'name', 'title']);
    final fallbackProfile = XboardSubscriptionProfile(
      subscribeUrl: normalizeSubscriptionUrl(subscribeUrl),
      name: fallbackName.isEmpty ? null : fallbackName,
      planId: intOrNull(data['plan_id']),
      upload: intOrNull(data['u'] ?? data['upload']),
      download: intOrNull(data['d'] ?? data['download']),
      total: intOrNull(data['transfer_enable'] ?? data['total']),
      expireAt: intOrNull(data['expired_at'] ?? data['expire_at'] ?? data['expire']),
    );

      return XboardSubscribeResult(
        subscribeUrl: fallbackProfile.subscribeUrl,
        subscriptions: subscriptions.isNotEmpty
            ? subscriptions
            : [if (fallbackProfile.subscribeUrl.isNotEmpty) fallbackProfile],
        planId: intOrNull(data['plan_id']),
        expiredAt: data['expired_at']?.toString() ?? data['expire_at']?.toString(),
        email: data['email']?.toString(),
        token: data['token']?.toString(),
        appConfig: XboardAppConfig.fromJson(data['client_config'] ?? data['app_config']),
        entitlement: XboardEntitlement.fromJson(data['entitlement']),
      );
  }

  /// 上报设备指纹与本机累计用量。
  ///
  /// 面板据此统计「同时在线设备数」（去重）并累加该套餐的已用流量。
  /// 累计值幂等：只计增量，重复上报同一累计值不会重复扣费。
  /// 返回面板最新的授权判定（可能因刚登记导致设备数超限）。
  Future<XboardEntitlement?> clientReport({
    required String deviceId,
    String? deviceName,
    String? platform,
    String? appVersion,
    int upload = 0,
    int download = 0,
  }) async {
    try {
      final response = await _requestWithOriginFallback(
        (dio, cancelToken) => dio.post(
          '/api/v1/user/clientReport',
          cancelToken: cancelToken,
          data: {
            'device_id': deviceId,
            if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
            if (platform != null && platform.isNotEmpty) 'platform': platform,
            if (appVersion != null && appVersion.isNotEmpty) 'app_version': appVersion,
            'upload': upload,
            'download': download,
          },
        ),
      );

      final body = _responseBody(response);
      if (body == null || body['status'] != 'success') return null;
      final data = body['data'] as Map<String, dynamic>?;
      return XboardEntitlement.fromJson(data?['entitlement'] ?? data);
    } catch (error) {
      loggy.debug('clientReport failed: $error');
      return null;
    }
  }

  static int? intOrNull(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String firstString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String normalizeSubscriptionUrl(String url) {
    final normalized = normalizeHttpUrl(url);
    if (normalized.isEmpty) return normalized;
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return normalized;
    final query = Map<String, String>.from(uri.queryParameters);
    query['flag'] = subscriptionFlag;
    return uri.replace(queryParameters: query).toString();
  }

  static String normalizeHttpUrl(String url) {
    final normalized = url.trim();
    if (normalized.isEmpty) return normalized;
    final withScheme = normalized.contains('://') ? normalized : 'https://$normalized';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return withScheme;
    final canonicalHost = TkyaOrigin.normalizeHost(uri.host);
    if (canonicalHost == null || canonicalHost == uri.host) return withScheme;
    return uri.replace(host: canonicalHost).toString();
  }

  Future<Response<dynamic>> _requestWithOriginFallback(
    Future<Response<dynamic>> Function(Dio dio, CancelToken cancelToken) request,
  ) async {
    final preferred = _preferredTransport;
    if (preferred != null && _transportDios.containsKey(preferred)) {
      try {
        return await _sendVia(preferred, request).timeout(preferredEndpointTimeout);
      } catch (error, stackTrace) {
        loggy.warning('Auth: preferred $preferred path failed; racing all paths', error, stackTrace);
        _preferredTransport = null;
      }
    }

    return _raceTransports(request);
  }

  Future<Response<dynamic>> _sendVia(
    String transport,
    Future<Response<dynamic>> Function(Dio dio, CancelToken cancelToken) request,
  ) async {
    final cancelToken = CancelToken();
    try {
      final response = await request(_dioFor(transport), cancelToken).timeout(requestTimeout);
      _preferredTransport = transport;
      _rememberSuccessfulEndpoint(transport);
      loggy.debug('Auth: $transport path succeeded');
      return response;
    } finally {
      if (!cancelToken.isCancelled) cancelToken.cancel('auth request completed');
    }
  }

  Future<Response<dynamic>> _raceTransports(
    Future<Response<dynamic>> Function(Dio dio, CancelToken cancelToken) request,
  ) {
    final completer = Completer<Response<dynamic>>();
    final cancelTokens = <String, CancelToken>{for (final transport in _transportDios.keys) transport: CancelToken()};
    final errors = <Object>[];
    var pending = cancelTokens.length;

    void completeSuccess(String transport, Response<dynamic> response) {
      if (completer.isCompleted) return;
      _preferredTransport = transport;
      _rememberSuccessfulEndpoint(transport);
      loggy.debug('Auth: $transport path won the login race');
      for (final entry in cancelTokens.entries) {
        if (entry.key != transport && !entry.value.isCancelled) {
          entry.value.cancel('auth $transport path won');
        }
      }
      completer.complete(response);
    }

    void completeFailure(Object error, StackTrace stackTrace) {
      if (completer.isCompleted) return;
      errors.add(error);
      pending -= 1;
      if (pending == 0) {
        completer.completeError(errors.isEmpty ? error : errors.last, stackTrace);
      }
    }

    for (final entry in cancelTokens.entries) {
      final transport = entry.key;
      request(
        _dioFor(transport),
        entry.value,
      ).timeout(requestTimeout).then((response) => completeSuccess(transport, response), onError: completeFailure);
    }

    return completer.future;
  }

  Dio _dioFor(String transport) {
    final dio = _transportDios[transport];
    if (dio == null) throw StateError('Unknown auth transport: $transport');
    return dio;
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
  final XboardEntitlement entitlement;

  XboardSubscribeResult({
    required this.subscribeUrl,
    required this.subscriptions,
    this.planId,
    this.expiredAt,
    this.email,
    this.token,
    required this.appConfig,
    required this.entitlement,
  });
}

/// 面板下发的授权判定结果。
///
/// 面板支持「外部订阅」，节点的到期/用量由第三方面板提供、本面板无从知晓，
/// 所以授权以本面板的套餐记录为准，通过 [allowed] + [reason] 下发。
/// 客户端据此决定是否删除本地已缓存配置、弹哪种提示、并跳转到「关于」页续费。
class XboardEntitlement {
  final bool allowed;
  final String? reason;
  final String message;
  final int deviceLimit;
  final int activeDevices;

  const XboardEntitlement({
    required this.allowed,
    this.reason,
    this.message = '',
    this.deviceLimit = 0,
    this.activeDevices = 0,
  });

  factory XboardEntitlement.fromJson(dynamic value) {
    if (value is! Map) return const XboardEntitlement(allowed: true);
    final json = Map<String, dynamic>.from(value);
    final reason = json['reason']?.toString();
    return XboardEntitlement(
      allowed: json['allowed'] == true,
      reason: reason,
      message: json['message']?.toString() ?? '',
      deviceLimit: XboardApiClient.intOrNull(json['device_limit']) ?? 0,
      activeDevices: XboardApiClient.intOrNull(json['active_devices']) ?? 0,
    );
  }
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
        .map(XboardSubscriptionProfile.fromJson)
        .where((item) => item.subscribeUrl.isNotEmpty)
        .toList(growable: false);
  }

  factory XboardSubscriptionProfile.fromJson(Map<String, dynamic> json) {
    final subscribeUrl = XboardApiClient.firstString(json, const [
      'subscribe_url',
      'subscription_url',
      'subscribeUrl',
      'url',
      'link',
    ]);
    final name = XboardApiClient.firstString(json, const ['plan_name', 'name', 'title']);
    return XboardSubscriptionProfile(
      subscribeUrl: XboardApiClient.normalizeSubscriptionUrl(subscribeUrl),
      name: name.isEmpty ? null : name,
      planId: XboardApiClient.intOrNull(json['plan_id']),
      subscriptionId: XboardApiClient.intOrNull(json['id'] ?? json['subscription_id']),
      upload: XboardApiClient.intOrNull(json['u'] ?? json['upload']),
      download: XboardApiClient.intOrNull(json['d'] ?? json['download']),
      total: XboardApiClient.intOrNull(json['transfer_enable'] ?? json['total']),
      expireAt: XboardApiClient.intOrNull(json['expired_at'] ?? json['expire_at'] ?? json['expire']),
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
