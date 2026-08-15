import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:hiddify/features/auth/data/login_doh_resolver.dart';
import 'package:hiddify/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  /// Mapped addresses are best effort; stale Cloudflare IPs must not block sync.
  static const mappedConnectionBudget = Duration(seconds: 2);
  static const mappedHostFailureCooldown = Duration(minutes: 15);
  // A failed mapped-origin probe must not make each subscription wait through
  // the normal retry chain. Try the public route directly first, then the
  // local proxy once, each with a bounded budget.
  static const subscriptionFallbackBudget = Duration(seconds: 8);

  static final Map<String, DateTime> _mappedHostUnavailableUntil = {};
  static final Set<String> _mappedHostsInFlight = {};

  final Map<String, Dio> _dio = {};
  late final Dio _mappedDio;
  late final Dio _fastDirectDio;
  late final Dio _fastProxyDio;
  late final LoginDohResolver _dohResolver;

  DioHttpClient({
    required Duration timeout,
    required this.userAgent,
    required bool debug,
  }) {
    _dohResolver = LoginDohResolver(timeout: const Duration(seconds: 2));
    for (final mode in ['proxy', 'direct', 'both']) {
      _dio[mode] = Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          headers: {'User-Agent': userAgent},
        ),
      );
      _dio[mode]!.interceptors.add(
        RetryInterceptor(
          dio: _dio[mode]!,
          retryDelays: [
            const Duration(seconds: 1),
            if (mode != 'proxy') ...[const Duration(seconds: 2), const Duration(seconds: 3)],
          ],
        ),
      );
      _dio[mode]!.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          // Normal requests use the public certificate chain. The origin-CA
          // context is reserved for mapped connections to the VPS origin;
          // using it for Cloudflare Worker/public subscription URLs can make
          // the server terminate the TLS handshake before the normal fallback.
          final client = HttpClient(context: SecurityContext(withTrustedRoots: true));
          client.findProxy = (url) {
            if (mode == 'proxy') return 'PROXY localhost:$port';
            if (mode == 'direct') return 'DIRECT';
            return 'PROXY localhost:$port; DIRECT';
          };
          return client;
        },
      );
    }

    _fastDirectDio = _createFastTransportDio(
      mode: 'direct',
      timeout: subscriptionFallbackBudget,
    );
    _fastProxyDio = _createFastTransportDio(
      mode: 'proxy',
      timeout: subscriptionFallbackBudget,
    );

    _mappedDio = Dio(
      BaseOptions(
        connectTimeout: mappedConnectionBudget,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        headers: {'User-Agent': userAgent},
      ),
    );
    _mappedDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: KuaifeiOrigin.securityContext)
          ..connectionTimeout = mappedConnectionBudget
          ..findProxy = (_) => 'DIRECT';
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          return ConnectionTask.fromSocket(_connectMapped(uri), () {});
        };
        return client;
      },
    );

    if (debug) {
      // _mappedDio.interceptors.add(LoggyDioInterceptor(requestHeader: true));
    }
  }

  int port = 0;
  String userAgent;

  Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  void setProxyPort(int port) {
    this.port = port;
    loggy.debug('setting proxy port: [$port]');
  }

  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    final options = _options(url, userAgent: userAgent, credentials: credentials);
    final mappedResponse = await _tryMappedRequest<T>(
      url: url,
      proxyOnly: proxyOnly,
      action: 'GET',
      request: () => _mappedDio.get<T>(url, cancelToken: cancelToken, options: options),
    );
    if (mappedResponse != null) return mappedResponse;
    return _dio[await _transportMode(proxyOnly)]!.get<T>(url, cancelToken: cancelToken, options: options);
  }

  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    final options = _options(url, userAgent: userAgent, credentials: credentials);
    final mappedResponse = await _tryMappedRequest<dynamic>(
      url: url,
      proxyOnly: proxyOnly,
      action: 'download',
      request: () => _mappedDio.download(url, path, cancelToken: cancelToken, options: options),
    );
    if (mappedResponse != null) return mappedResponse;

    // Do not fall through to the normal Dio instance here. It has a retry
    // interceptor intended for ordinary API calls, which made one failed
    // mapped probe hold the login import for roughly 40 seconds per package.
    // Subscription URLs are already authenticated and idempotent, so a direct
    // public request followed by one proxy request is safer and much faster.
    if (proxyOnly) {
      return _fastProxyDio.download(url, path, cancelToken: cancelToken, options: options);
    }

    try {
      loggy.debug('Subscription download fallback: trying direct transport for $url');
      return await _fastDirectDio.download(url, path, cancelToken: cancelToken, options: options);
    } catch (error, stackTrace) {
      if (_isCancelled(error)) rethrow;
      loggy.warning('Direct subscription download failed; trying proxy transport for $url', error, stackTrace);
      if (!await isPortOpen('127.0.0.1', port, timeout: const Duration(seconds: 1))) {
        rethrow;
      }
      return _fastProxyDio.download(url, path, cancelToken: cancelToken, options: options);
    }
  }

  Dio _createFastTransportDio({required String mode, required Duration timeout}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        headers: {'User-Agent': userAgent},
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(context: SecurityContext(withTrustedRoots: true));
        client.connectionTimeout = timeout;
        client.findProxy = (_) => mode == 'proxy' ? 'PROXY localhost:$port' : 'DIRECT';
        return client;
      },
    );
    return dio;
  }

  Future<String> _transportMode(bool proxyOnly) async {
    if (proxyOnly) return 'proxy';
    return await isPortOpen('127.0.0.1', port) ? 'both' : 'direct';
  }

  Future<Response<T>?> _tryMappedRequest<T>({
    required String url,
    required bool proxyOnly,
    required String action,
    required Future<Response<T>> Function() request,
  }) async {
    final host = _hostForUrl(url);
    if (host == null || !_shouldAttemptMappedTransport(url, host, proxyOnly)) return null;
    if (!_mappedHostsInFlight.add(host)) {
      loggy.debug('Mapped $action probe already in flight for $host; using normal transport');
      return null;
    }
    try {
      final response = await request();
      _mappedHostUnavailableUntil.remove(host);
      return response;
    } catch (error, stackTrace) {
      if (_isCancelled(error)) rethrow;
      if (_isMappedConnectionFailure(error)) {
        final retryAt = DateTime.now().add(mappedHostFailureCooldown);
        _mappedHostUnavailableUntil[host] = retryAt;
        loggy.warning('Mapped $action failed for $host; bypassing mapped transport until $retryAt', error, stackTrace);
      } else {
        loggy.warning('Mapped $action failed for $url; falling back to normal transport', error, stackTrace);
      }
      return null;
    } finally {
      _mappedHostsInFlight.remove(host);
    }
  }

  bool _isCancelled(Object error) {
    return error is DioException && (CancelToken.isCancel(error) || error.type == DioExceptionType.cancel);
  }

  bool _isMappedConnectionFailure(Object error) {
    if (error is SocketException || error is HandshakeException || error is TimeoutException) return true;
    if (error is! DioException) return false;
    if (error.type == DioExceptionType.connectionTimeout || error.type == DioExceptionType.connectionError) {
      return true;
    }
    final cause = error.error;
    return cause is SocketException || cause is HandshakeException || cause is TimeoutException;
  }

  bool _shouldAttemptMappedTransport(String url, String host, bool proxyOnly) {
    if (_isMappedHostCoolingDown(host)) return false;
    return _hasMappedEndpoint(url) || (!proxyOnly && _canDohBootstrap(url));
  }

  bool _isMappedHostCoolingDown(String host) {
    final unavailableUntil = _mappedHostUnavailableUntil[host];
    if (unavailableUntil == null) return false;
    if (unavailableUntil.isAfter(DateTime.now())) {
      loggy.debug('Mapped transport is cooling down for $host until $unavailableUntil');
      return true;
    }
    _mappedHostUnavailableUntil.remove(host);
    return false;
  }

  Options _options(String url, {String? userAgent, ({String username, String password})? credentials}) {
    final uri = Uri.parse(url);
    String? userInfo;
    if (credentials != null) {
      userInfo = '${credentials.username}:${credentials.password}';
    } else if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }
    final basicAuth = userInfo == null ? null : 'Basic ${base64.encode(utf8.encode(userInfo))}';
    return Options(
      headers: {if (userAgent != null) 'User-Agent': userAgent, if (basicAuth != null) 'authorization': basicAuth},
    );
  }

  String? _hostForUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri.host.toLowerCase();
  }

  bool _hasMappedEndpoint(String url) {
    final host = _hostForUrl(url);
    return host != null && KuaifeiOrigin.connectionAddressesForHost(host).isNotEmpty;
  }

  bool _canDohBootstrap(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) return false;
    return InternetAddress.tryParse(uri.host) == null;
  }

  Future<Socket> _connectMapped(Uri uri) async {
    final configured = KuaifeiOrigin.connectionAddressesForHost(
      uri.host,
    ).map(InternetAddress.new).toList(growable: false);
    final addresses = configured.isNotEmpty ? configured : await _resolveDohAddresses(uri.host);
    final stopwatch = Stopwatch()..start();
    Object? lastError;
    for (final address in _preferIpv4(addresses)) {
      Socket? socket;
      try {
        final remaining = mappedConnectionBudget - stopwatch.elapsed;
        if (remaining <= Duration.zero) break;
        socket = await Socket.connect(address, uri.port, timeout: remaining);
        final tlsRemaining = mappedConnectionBudget - stopwatch.elapsed;
        if (tlsRemaining <= Duration.zero) throw TimeoutException('Mapped endpoint connection budget exhausted');
        return await _secureIfNeeded(uri, socket).timeout(tlsRemaining);
      } catch (error) {
        socket?.destroy();
        lastError = error;
      }
    }
    throw SocketException('Unable to connect mapped endpoint for ${uri.host}: $lastError');
  }

  Future<List<InternetAddress>> _resolveDohAddresses(String host) async {
    try {
      final resolution = await _dohResolver.resolve(host).timeout(mappedConnectionBudget);
      final addresses = resolution.addresses;
      if (addresses.isNotEmpty) {
        loggy.debug('DoH bootstrap resolved $host to ${addresses.map((item) => item.address).join(', ')}');
        return addresses;
      }
    } catch (error, stackTrace) {
      loggy.warning('DoH bootstrap failed for $host', error, stackTrace);
    }
    return const [];
  }

  List<InternetAddress> _preferIpv4(List<InternetAddress> addresses) {
    final v4 = addresses.where((item) => item.type == InternetAddressType.IPv4);
    final v6 = addresses.where((item) => item.type == InternetAddressType.IPv6);
    return [...v4, ...v6];
  }

  Future<Socket> _secureIfNeeded(Uri uri, Socket socket) {
    if (!uri.isScheme('https')) return Future.value(socket);
    return SecureSocket.secure(socket, host: uri.host, context: KuaifeiOrigin.securityContext);
  }
}
