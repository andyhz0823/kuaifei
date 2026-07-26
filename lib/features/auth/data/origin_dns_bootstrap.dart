import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:hiddify/core/http_client/kuaifei_origin.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OriginDnsBootstrap {
  const OriginDnsBootstrap._();

  static const url = Constants.originDnsUrl;
  static const _publicKeyBase64 = 'g0+dbfOVBvm1ufO7itA99nvG/l+b1o4N3nQc0fWJ4WU=';

  static Future<bool> refresh(SharedPreferences preferences, {Duration timeout = const Duration(seconds: 6)}) async {
    final uri = Uri.parse(url);
    final client = HttpClient(context: KuaifeiOrigin.securityContext)
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      return ConnectionTask.fromSocket(_connect(requestUri, timeout), () {});
    };

    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) return false;
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      final envelope = jsonDecode(body);
      if (envelope is! Map) return false;

      final payload = base64Decode(envelope['payload']?.toString() ?? '');
      final signature = base64Decode(envelope['signature']?.toString() ?? '');
      final verified = await Ed25519().verify(
        payload,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(base64Decode(_publicKeyBase64), type: KeyPairType.ed25519),
        ),
      );
      if (!verified) return false;

      return KuaifeiOrigin.replace(
        preferences,
        OriginDnsConfig.fromJson(jsonDecode(utf8.decode(payload))),
        onlyIfNewer: true,
      );
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Socket> _connect(Uri uri, Duration timeout) async {
    final addresses = KuaifeiOrigin.connectionAddressesForHost(uri.host);
    Object? lastError;
    for (final address in addresses) {
      try {
        return await Socket.connect(address, uri.port, timeout: timeout);
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw SocketException('Distribution bootstrap connection failed: $lastError');
    }
    return Socket.connect(uri.host, uri.port, timeout: timeout);
  }
}
