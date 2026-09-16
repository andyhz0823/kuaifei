import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:hiddify/core/http_client/tkya_origin.dart';
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
  static const subscriptionEndpointProbeBudget = Duration(seconds: 6);

  static final Map<String, DateTime> _mappedHostUnavailableUntil = {};
  static final Set<String> _mappedHostsInFlight = {};

  final Map<String, Dio> _dio = {};
  late final Dio _mappedDio;
  late final Dio _fastDirectDio;
  late final Dio _fastProxyDio;
  late final Dio _subscriptionProbeDio;
  late final LoginDohResolver _dohResolver;
  String? _subscriptionFallbackBaseUrl;
  Future<String?>? _subscriptionEndpointDiscovery;

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
    _subscriptionProbeDio = _createFastTransportDio(
      mode: 'direct',
      timeout: subscriptionEndpointProbeBudget,
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
        final client = HttpClient(context: TkyaOrigin.securityContext)
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

    Object? lastError;
    StackTrace? lastStackTrace;
    try {
      loggy.debug('Subscription download fallback: trying direct transport for ${Uri.tryParse(url)?.host ?? 'unknown host'}');
      return await _fastDirectDio.download(url, path, cancelToken: cancelToken, options: options);
    } catch (error, stackTrace) {
      if (_isCancelled(error)) rethrow;
      lastError = error;
      lastStackTrace = stackTrace;
      loggy.warning('Direct subscription download failed for ${Uri.tryParse(url)?.host ?? 'unknown host'}', error, stackTrace);
    }

    if (port > 0 && await isPortOpen('127.0.0.1', port, timeout: const Duration(seconds: 1))) {
      try {
        loggy.debug('Subscription download fallback: trying local proxy transport');
        return await _fastProxyDio.download(url, path, cancelToken: cancelToken, options: options);
      } catch (error, stackTrace) {
        if (_isCancelled(error)) rethrow;
        lastError = error;
        lastStackTrace = stackTrace;
        loggy.warning('Local proxy subscription download failed; trying signed endpoint pool', error, stackTrace);
      }
    }

    final fallbackUrl = await _resolveSubscriptionFallbackUrl(url, options: options);
    if (fallbackUrl == null) {
      Error.throwWithStackTrace(lastError, lastStackTrace);
    }

    try {
      final fallbackHost = Uri.parse(fallbackUrl).host;
      loggy.info('Subscription download fallback: using signed endpoint $fallbackHost');
      return await _fastDirectDio.download(fallbackUrl, path, cancelToken: cancelToken, options: options);
    } catch (error, stackTrace) {
      if (_isCancelled(error)) rethrow;
      final failedBase = _subscriptionFallbackBaseUrl;
      if (failedBase != null && fallbackUrl.startsWith(failedBase)) {
        _subscriptionFallbackBaseUrl = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<String?> _resolveSubscriptionFallbackUrl(String url, {required Options options}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) return null;

    final endpoints = TkyaOrigin.config.authEndpoints.where((endpoint) => endpoint.supportsSubscription).toList();
    final knownHosts = endpoints.map((endpoint) => Uri.tryParse(endpoint.url)?.host).whereType<String>().toSet();
    if (!knownHosts.contains(uri.host)) return null;

    final cachedBase = _subscriptionFallbackBaseUrl;
    if (cachedBase != null && Uri.tryParse(cachedBase)?.host != uri.host) {
      return _replaceSubscriptionBase(uri, cachedBase).toString();
    }

    final currentDiscovery = _subscriptionEndpointDiscovery;
    if (currentDiscovery != null) {
      final base = await currentDiscovery;
      return base == null ? null : _replaceSubscriptionBase(uri, base).toString();
    }

    final discovery = _discoverSubscriptionEndpoint(uri, endpoints, options);
    _subscriptionEndpointDiscovery = discovery;
    try {
      final base = await discovery;
      if (base == null) return null;
      _subscriptionFallbackBaseUrl = base;
      return _replaceSubscriptionBase(uri, base).toString();
    } finally {
      if (identical(_subscriptionEndpointDiscovery, discovery)) {
        _subscriptionEndpointDiscovery = null;
      }
    }
  }

  Future<String?> _discoverSubscriptionEndpoint(
    Uri original,
    List<ClientAuthEndpoint> endpoints,
    Options options,
  ) async {
    final candidates = <String>[];
    final seenHosts = <String>{original.host};
    for (final endpoint in endpoints) {
      final endpointUri = Uri.tryParse(endpoint.url);
      if (endpointUri == null || !endpointUri.isScheme('https') || !seenHosts.add(endpointUri.host)) continue;
      candidates.add(endpoint.url);
    }
    if (candidates.isEmpty) return null;

    final completer = Completer<String?>();
    final cancelTokens = <CancelToken>[];
    var remaining = candidates.length;
    for (final base in candidates) {
      final candidateUri = _replaceSubscriptionBase(original, base);
      final token = CancelToken();
      cancelTokens.add(token);
      unawaited(() async {
        try {
          await _subscriptionProbeDio.get<List<int>>(
            candidateUri.toString(),
            cancelToken: token,
            options: options.copyWith(responseType: ResponseType.bytes),
          );
          if (!completer.isCompleted) {
            completer.complete(base);
            for (final other in cancelTokens) {
              if (!identical(other, token) && !other.isCancelled) other.cancel('subscription endpoint selected');
            }
          }
        } catch (error, stackTrace) {
          if (!_isCancelled(error)) {
            loggy.debug('Subscription endpoint probe failed for ${candidateUri.host}', error, stackTrace);
          }
        } finally {
          remaining -= 1;
          if (remaining == 0 && !completer.isCompleted) completer.complete(null);
        }
      }());
    }
    return completer.future.timeout(
      subscriptionEndpointProbeBudget + const Duration(seconds: 1),
      onTimeout: () {
        for (final token in cancelTokens) {
          if (!token.isCancelled) token.cancel('subscription endpoint discovery timed out');
        }
        return null;
      },
    );
  }

  Uri _replaceSubscriptionBase(Uri original, String base) {
    final endpoint = Uri.parse(base);
    final prefix = endpoint.path.replaceFirst(RegExp(r'/+$'), '');
    final suffix = original.path.startsWith('/') ? original.path : '/${original.path}';
    return Uri(
      scheme: endpoint.scheme,
      host: endpoint.host,
      port: endpoint.hasPort ? endpoint.port : null,
      path: '$prefix$suffix',
      query: original.hasQuery ? original.query : null,
    );
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
    return host != null && TkyaOrigin.connectionAddressesForHost(host).isNotEmpty;
  }

  bool _canDohBootstrap(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.isScheme('https') || uri.host.isEmpty) return false;
    return InternetAddress.tryParse(uri.host) == null;
  }

  Future<Socket> _connectMapped(Uri uri) async {
    final configured = TkyaOrigin.connectionAddressesForHost(
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
    return SecureSocket.secure(socket, host: uri.host, context: TkyaOrigin.securityContext);
  }
}
