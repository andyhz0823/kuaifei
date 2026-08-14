import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OriginDnsBootstrap {
  const OriginDnsBootstrap._();

  static const urls = [Constants.bootstrapUrl, Constants.originDnsUrl];
  static const _publicKeyBase64 = '2OgYgpyYnI53e7hSNxh6OX4pjbLx5r0WDE/tnphd9ug=';

  static Future<bool> refresh(SharedPreferences preferences, {Duration timeout = const Duration(seconds: 6)}) async {
    final client = HttpClient(context: KuaifeiOrigin.securityContext)
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      return ConnectionTask.fromSocket(_connect(requestUri, timeout), () {});
    };

    try {
      for (final url in urls) {
        try {
          final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          final panelHost = _panelHost(preferences);
          if (panelHost != null) {
            request.headers.set('X-Kuaifei-Panel-Host', panelHost);
          }
          final response = await request.close().timeout(timeout);
          if (response.statusCode != HttpStatus.ok) continue;
          final body = await utf8.decoder.bind(response).join().timeout(timeout);
          final config = await _verify(body);
          if (config == null) continue;
          if (config.revision == KuaifeiOrigin.config.revision) return false;
          return KuaifeiOrigin.replace(preferences, config, onlyIfNewer: true);
        } catch (_) {
          // Try the compatibility endpoint before retaining the cached document.
        }
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<OriginDnsConfig?> _verify(String body) async {
    try {
      final envelope = jsonDecode(body);
      if (envelope is! Map) return null;
      final payload = base64Decode(envelope['payload']?.toString() ?? '');
      final signature = base64Decode(envelope['signature']?.toString() ?? '');
      final verified = await Ed25519().verify(
        payload,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(base64Decode(_publicKeyBase64), type: KeyPairType.ed25519),
        ),
      );
      if (!verified) return null;
      final config = OriginDnsConfig.fromJson(jsonDecode(utf8.decode(payload)));
      return config.isUsable ? config : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Socket> _connect(Uri uri, Duration timeout) async {
    final addresses = KuaifeiOrigin.connectionAddressesForHost(uri.host);
    Object? lastError;
    for (final address in addresses) {
      try {
        final socket = await Socket.connect(address, uri.port, timeout: timeout);
        return _secureIfNeeded(uri, socket);
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw SocketException('Distribution bootstrap connection failed: $lastError');
    }
    final socket = await Socket.connect(uri.host, uri.port, timeout: timeout);
    return _secureIfNeeded(uri, socket);
  }

  static Future<Socket> _secureIfNeeded(Uri uri, Socket socket) {
    if (!uri.isScheme('https')) return Future.value(socket);
    return SecureSocket.secure(socket, host: uri.host, context: KuaifeiOrigin.securityContext);
  }

  static String? _panelHost(SharedPreferences preferences) {
    final candidates = [preferences.getString('auth_last_panel_url'), preferences.getString('auth_panel_url')];
    for (final value in candidates) {
      if (value == null || value.trim().isEmpty) continue;
      final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
      final host = uri?.host.toLowerCase();
      final normalizedHost = host == null ? null : KuaifeiOrigin.normalizeHost(host);
      if (normalizedHost != null) return normalizedHost;
    }
    return null;
  }
}
