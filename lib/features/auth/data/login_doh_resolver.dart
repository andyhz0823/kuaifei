import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class LoginDnsResolution {
  const LoginDnsResolution({
    required this.host,
    required this.addresses,
    required this.hasHttpsRecord,
    required this.hasEchConfig,
  });

  final String host;
  final List<InternetAddress> addresses;
  final bool hasHttpsRecord;
  final bool hasEchConfig;

  bool get isUsable => addresses.isNotEmpty || hasHttpsRecord;
}

class LoginDohResolver {
  LoginDohResolver({
    this.preferences,
    this.timeout = const Duration(seconds: 5),
    this.cacheTtl = const Duration(minutes: 15),
    this.staleIfError = const Duration(days: 7),
  }) {
    _restoreCache();
  }

  final SharedPreferences? preferences;
  final Duration timeout;
  final Duration cacheTtl;
  final Duration staleIfError;
  final _cache = <String, _CachedResolution>{};
  final _random = Random.secure();

  static const preferenceKey = 'login_doh_last_known_good_v1';

  static const _providers = <_DohProvider>[
    _DohProvider(
      uri: 'https://dns.alidns.com/resolve',
      bootstrapAddresses: ['223.5.5.5', '223.6.6.6'],
      format: _DohFormat.json,
    ),
    _DohProvider(
      uri: 'https://cloudflare-dns.com/dns-query',
      bootstrapAddresses: ['1.1.1.1', '1.0.0.1'],
      format: _DohFormat.dnsMessage,
    ),
    _DohProvider(
      uri: 'https://dns.google/resolve',
      bootstrapAddresses: ['8.8.8.8', '8.8.4.4'],
      format: _DohFormat.json,
    ),
    _DohProvider(
      uri: 'https://dns.alidns.com/dns-query',
      bootstrapAddresses: ['223.5.5.5', '223.6.6.6'],
      format: _DohFormat.dnsMessage,
    ),
  ];

  Future<LoginDnsResolution> resolve(String host, {bool includeHttps = true, bool includeIpv6 = true}) async {
    final normalizedHost = _normalizeHost(host);
    if (normalizedHost == null) {
      return const LoginDnsResolution(host: '', addresses: [], hasHttpsRecord: false, hasEchConfig: false);
    }

    final parsedAddress = InternetAddress.tryParse(normalizedHost);
    if (parsedAddress != null) {
      return LoginDnsResolution(
        host: normalizedHost,
        addresses: [parsedAddress],
        hasHttpsRecord: false,
        hasEchConfig: false,
      );
    }

    final cached = _cache[normalizedHost];
    if (cached != null && !cached.isExpired(DateTime.now())) {
      return _filterResolution(cached.value, includeIpv6: includeIpv6);
    }

    Object? lastError;
    final providers = _providers.toList(growable: false)..shuffle(_random);
    for (final provider in providers) {
      try {
        final resolution = await _resolveWithProvider(
          provider,
          normalizedHost,
          includeHttps: includeHttps,
          includeIpv6: includeIpv6,
        ).timeout(timeout + const Duration(milliseconds: 250));
        if (resolution.isUsable) {
          _cache[normalizedHost] = _CachedResolution(resolution, DateTime.now().add(cacheTtl));
          await _persistCache();
          return _filterResolution(resolution, includeIpv6: includeIpv6);
        }
      } catch (error) {
        lastError = error;
      }
    }

    if (cached != null && !cached.isTooStale(DateTime.now(), staleIfError)) {
      return _filterResolution(cached.value, includeIpv6: includeIpv6);
    }

    if (lastError != null) {
      throw SocketException('DoH resolve failed for $normalizedHost: $lastError');
    }
    return LoginDnsResolution(host: normalizedHost, addresses: const [], hasHttpsRecord: false, hasEchConfig: false);
  }

  LoginDnsResolution _filterResolution(LoginDnsResolution resolution, {required bool includeIpv6}) {
    final addresses = _dedupeAddresses(
      resolution.addresses.where((address) {
        return includeIpv6 || address.type == InternetAddressType.IPv4;
      }),
    );
    return LoginDnsResolution(
      host: resolution.host,
      addresses: addresses,
      hasHttpsRecord: resolution.hasHttpsRecord,
      hasEchConfig: resolution.hasEchConfig,
    );
  }

  Future<LoginDnsResolution> _resolveWithProvider(
    _DohProvider provider,
    String host, {
    required bool includeHttps,
    required bool includeIpv6,
  }) async {
    final aFuture = _queryAddresses(provider, host, DnsRecordType.a).catchError((Object _) => <InternetAddress>[]);
    final aaaaFuture = includeIpv6
        ? _queryAddresses(provider, host, DnsRecordType.aaaa).catchError((Object _) => <InternetAddress>[])
        : Future.value(<InternetAddress>[]);
    final httpsFuture = includeHttps
        ? _queryHttpsInfo(
            provider,
            host,
          ).catchError((Object _) => const _HttpsInfo(hasHttpsRecord: false, hasEchConfig: false))
        : Future.value(const _HttpsInfo(hasHttpsRecord: false, hasEchConfig: false));

    final results = await Future.wait<dynamic>([aFuture, aaaaFuture, httpsFuture]);
    final addresses = _dedupeAddresses([
      ...results[0] as List<InternetAddress>,
      ...results[1] as List<InternetAddress>,
    ]);
    final httpsInfo = results[2] as _HttpsInfo;
    return LoginDnsResolution(
      host: host,
      addresses: addresses,
      hasHttpsRecord: httpsInfo.hasHttpsRecord,
      hasEchConfig: httpsInfo.hasEchConfig,
    );
  }

  Future<List<InternetAddress>> _queryAddresses(_DohProvider provider, String host, DnsRecordType type) async {
    if (provider.format == _DohFormat.json) {
      final response = await _queryJson(provider, host, type.code);
      return _parseJsonAddresses(response, type);
    }
    final message = await _queryDnsMessage(provider, host, type.code);
    return _DnsMessageParser(message).parseAddresses(type);
  }

  Future<_HttpsInfo> _queryHttpsInfo(_DohProvider provider, String host) async {
    if (provider.format == _DohFormat.json) {
      final response = await _queryJson(provider, host, DnsRecordType.https.code);
      return _parseJsonHttpsInfo(response);
    }
    final message = await _queryDnsMessage(provider, host, DnsRecordType.https.code);
    return _DnsMessageParser(message).parseHttpsInfo();
  }

  Future<Map<String, dynamic>> _queryJson(_DohProvider provider, String host, int recordType) async {
    final client = _createDohHttpClient(provider);
    try {
      final uri = Uri.parse(provider.uri).replace(queryParameters: {'name': host, 'type': recordType.toString()});
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json, application/json');
      final response = await request.close().timeout(timeout);
      final body = await _readResponseBytes(response).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('DoH JSON HTTP ${response.statusCode}', uri: uri);
      }
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) {
        throw const FormatException('DoH JSON response is not an object');
      }
      final result = Map<String, dynamic>.from(decoded);
      final status = result['Status'];
      if (status is num && status.toInt() != 0) {
        throw FormatException('DoH JSON response status ${status.toInt()}');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _queryDnsMessage(_DohProvider provider, String host, int recordType) async {
    final client = _createDohHttpClient(provider);
    try {
      final query = base64Url.encode(_buildDnsQuery(host, recordType)).replaceAll('=', '');
      final uri = Uri.parse(provider.uri).replace(queryParameters: {'dns': query});
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
      final response = await request.close().timeout(timeout);
      final body = await _readResponseBytes(response).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('DoH HTTP ${response.statusCode}', uri: uri);
      }
      return Uint8List.fromList(body);
    } finally {
      client.close(force: true);
    }
  }

  HttpClient _createDohHttpClient(_DohProvider provider) {
    final providerUri = Uri.parse(provider.uri);
    final bootstrapAddresses = provider.bootstrapAddresses.map(InternetAddress.new).toList(growable: false);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      if (requestUri.host.toLowerCase() != providerUri.host.toLowerCase()) {
        final socket = await Socket.connect(requestUri.host, requestUri.port, timeout: timeout);
        return ConnectionTask.fromSocket(_secureIfNeeded(requestUri, socket), () {});
      }

      final socket = await _connectFirstAvailable(bootstrapAddresses, requestUri.port);
      return ConnectionTask.fromSocket(_secureIfNeeded(requestUri, socket), () {});
    };
    return client;
  }

  Future<Socket> _secureIfNeeded(Uri uri, Socket socket) {
    if (!uri.isScheme('https')) return Future.value(socket);
    return SecureSocket.secure(socket, host: uri.host);
  }

  Future<Socket> _connectFirstAvailable(List<InternetAddress> addresses, int port) async {
    final shuffled = addresses.toList(growable: false)..shuffle(_random);
    Object? lastError;
    for (final address in shuffled) {
      try {
        return await Socket.connect(address, port, timeout: timeout);
      } catch (error) {
        lastError = error;
      }
    }
    throw SocketException('Unable to connect to DoH bootstrap address: $lastError');
  }

  List<InternetAddress> _parseJsonAddresses(Map<String, dynamic> response, DnsRecordType type) {
    final answers = response['Answer'];
    if (answers is! List) return const [];

    final addresses = <InternetAddress>[];
    for (final answer in answers.whereType<Map>()) {
      final answerType = answer['type'];
      if (answerType is! num || answerType.toInt() != type.code) continue;

      final data = answer['data']?.toString();
      if (data == null || data.isEmpty) continue;

      try {
        final address = InternetAddress(data);
        if (type == DnsRecordType.a && address.type == InternetAddressType.IPv4) addresses.add(address);
        if (type == DnsRecordType.aaaa && address.type == InternetAddressType.IPv6) addresses.add(address);
      } catch (_) {
        // Ignore CNAME and malformed records in JSON DoH answers.
      }
    }
    return _dedupeAddresses(addresses);
  }

  _HttpsInfo _parseJsonHttpsInfo(Map<String, dynamic> response) {
    final answers = response['Answer'];
    if (answers is! List) return const _HttpsInfo(hasHttpsRecord: false, hasEchConfig: false);

    var hasHttpsRecord = false;
    var hasEchConfig = false;
    for (final answer in answers.whereType<Map>()) {
      final answerType = answer['type'];
      if (answerType is! num || answerType.toInt() != DnsRecordType.https.code) continue;
      hasHttpsRecord = true;
      final data = answer['data']?.toString().toLowerCase() ?? '';
      hasEchConfig = hasEchConfig || data.contains(' ech=') || data.startsWith('ech=') || data.contains(' echconfig=');
    }
    return _HttpsInfo(hasHttpsRecord: hasHttpsRecord, hasEchConfig: hasEchConfig);
  }

  Uint8List _buildDnsQuery(String host, int recordType) {
    final bytes = BytesBuilder();
    final id = _random.nextInt(0xffff);
    bytes.add([id >> 8, id & 0xff, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for (final label in host.split('.')) {
      final encoded = ascii.encode(label);
      if (encoded.length > 63) {
        throw FormatException('DNS label is too long: $label');
      }
      bytes.addByte(encoded.length);
      bytes.add(encoded);
    }
    bytes.addByte(0);
    bytes.add([recordType >> 8, recordType & 0xff, 0x00, 0x01]);
    return bytes.toBytes();
  }

  Future<List<int>> _readResponseBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _restoreCache() {
    final raw = preferences?.getString(preferenceKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final now = DateTime.now();
      for (final entry in decoded.entries) {
        final host = _normalizeHost(entry.key.toString());
        if (host == null || entry.value is! Map) continue;
        final cached = _CachedResolution.fromJson(Map<String, dynamic>.from(entry.value as Map));
        if (cached != null && !cached.isTooStale(now, staleIfError)) {
          _cache[host] = cached;
        }
      }
    } catch (_) {
      // Broken cache data is ignored and replaced by the next successful DoH lookup.
    }
  }

  Future<void> _persistCache() async {
    final prefs = preferences;
    if (prefs == null) return;
    final now = DateTime.now();
    _cache.removeWhere((_, cached) => cached.isTooStale(now, staleIfError));
    final encoded = jsonEncode({for (final entry in _cache.entries) entry.key: entry.value.toJson()});
    await prefs.setString(preferenceKey, encoded);
  }

  String? _normalizeHost(String value) {
    var host = value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.isEmpty) return null;
    if (host.contains('://')) {
      final uri = Uri.tryParse(host);
      if (uri == null || uri.host.isEmpty) return null;
      host = uri.host.toLowerCase();
    }
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.contains('/')) {
      final uri = Uri.tryParse('https://$host');
      if (uri?.host.isNotEmpty == true) host = uri!.host.toLowerCase();
    }
    if (host.contains(':') && InternetAddress.tryParse(host) == null) {
      final uri = Uri.tryParse('https://$host');
      if (uri?.host.isNotEmpty == true) host = uri!.host.toLowerCase();
    }
    host = host.replaceFirst(RegExp(r'\.$'), '');
    return host.isEmpty ? null : host;
  }

  List<InternetAddress> _dedupeAddresses(Iterable<InternetAddress> addresses) {
    final seen = <String>{};
    final v4 = <InternetAddress>[];
    final v6 = <InternetAddress>[];
    for (final address in addresses) {
      if (!seen.add(address.address)) continue;
      if (address.type == InternetAddressType.IPv4) {
        v4.add(address);
      } else if (address.type == InternetAddressType.IPv6) {
        v6.add(address);
      }
    }
    return [...v4, ...v6];
  }
}

enum DnsRecordType {
  a(1),
  aaaa(28),
  https(65);

  const DnsRecordType(this.code);
  final int code;
}

class _DohProvider {
  const _DohProvider({required this.uri, required this.bootstrapAddresses, required this.format});

  final String uri;
  final List<String> bootstrapAddresses;
  final _DohFormat format;
}

enum _DohFormat { dnsMessage, json }

class _CachedResolution {
  const _CachedResolution(this.value, this.expiresAt);

  final LoginDnsResolution value;
  final DateTime expiresAt;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  bool isTooStale(DateTime now, Duration staleIfError) => expiresAt.add(staleIfError).isBefore(now);

  Map<String, dynamic> toJson() => {
    'addresses': value.addresses.map((address) => address.address).toList(growable: false),
    'expires_at': expiresAt.millisecondsSinceEpoch,
    'has_https_record': value.hasHttpsRecord,
    'has_ech_config': value.hasEchConfig,
  };

  static _CachedResolution? fromJson(Map<String, dynamic> json) {
    final addresses = <InternetAddress>[];
    final rawAddresses = json['addresses'];
    if (rawAddresses is Iterable) {
      for (final item in rawAddresses) {
        final address = InternetAddress.tryParse(item.toString());
        if (address != null) addresses.add(address);
      }
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(switch (json['expires_at']) {
      final int value => value,
      final num value => value.toInt(),
      final value => int.tryParse(value?.toString() ?? '') ?? 0,
    });
    if (expiresAt.millisecondsSinceEpoch == 0) return null;

    return _CachedResolution(
      LoginDnsResolution(
        host: '',
        addresses: addresses,
        hasHttpsRecord: json['has_https_record'] == true,
        hasEchConfig: json['has_ech_config'] == true,
      ),
      expiresAt,
    );
  }
}

class _HttpsInfo {
  const _HttpsInfo({required this.hasHttpsRecord, required this.hasEchConfig});

  final bool hasHttpsRecord;
  final bool hasEchConfig;
}

class _DnsMessageParser {
  _DnsMessageParser(this.message);

  final Uint8List message;

  List<InternetAddress> parseAddresses(DnsRecordType type) {
    final addresses = <InternetAddress>[];
    for (final answer in _parseAnswers()) {
      if (answer.type != type.code || answer.dnsClass != 1) continue;
      if (type == DnsRecordType.a && answer.data.length == 4) {
        addresses.add(InternetAddress(answer.data.join('.')));
      }
      if (type == DnsRecordType.aaaa && answer.data.length == 16) {
        final parts = <String>[];
        for (var i = 0; i < answer.data.length; i += 2) {
          parts.add(((answer.data[i] << 8) | answer.data[i + 1]).toRadixString(16));
        }
        addresses.add(InternetAddress(parts.join(':')));
      }
    }
    return addresses;
  }

  _HttpsInfo parseHttpsInfo() {
    var hasHttpsRecord = false;
    var hasEchConfig = false;
    for (final answer in _parseAnswers()) {
      if (answer.type != DnsRecordType.https.code || answer.dnsClass != 1) continue;
      hasHttpsRecord = true;
      hasEchConfig = hasEchConfig || _httpsRecordHasEch(answer.data);
    }
    return _HttpsInfo(hasHttpsRecord: hasHttpsRecord, hasEchConfig: hasEchConfig);
  }

  List<_DnsAnswer> _parseAnswers() {
    if (message.length < 12) return const [];
    final qdCount = _readUint16(4);
    final anCount = _readUint16(6);
    var offset = 12;

    for (var i = 0; i < qdCount; i++) {
      offset = _skipName(offset);
      offset += 4;
      if (offset > message.length) return const [];
    }

    final answers = <_DnsAnswer>[];
    for (var i = 0; i < anCount; i++) {
      offset = _skipName(offset);
      if (offset + 10 > message.length) return answers;
      final type = _readUint16(offset);
      final dnsClass = _readUint16(offset + 2);
      final dataLength = _readUint16(offset + 8);
      offset += 10;
      if (offset + dataLength > message.length) return answers;
      answers.add(_DnsAnswer(type, dnsClass, Uint8List.sublistView(message, offset, offset + dataLength)));
      offset += dataLength;
    }
    return answers;
  }

  bool _httpsRecordHasEch(Uint8List data) {
    if (data.length < 3) return false;
    var offset = 2; // SvcPriority
    offset = _skipNameInData(data, offset);
    while (offset + 4 <= data.length) {
      final key = (data[offset] << 8) | data[offset + 1];
      final length = (data[offset + 2] << 8) | data[offset + 3];
      offset += 4;
      if (offset + length > data.length) return false;
      if (key == 5 && length > 0) return true; // SVCB/HTTPS ech parameter.
      offset += length;
    }
    return false;
  }

  int _skipName(int offset) {
    final start = offset;
    var cursor = offset;
    while (cursor < message.length) {
      final length = message[cursor];
      if ((length & 0xc0) == 0xc0) {
        return cursor + 2;
      }
      cursor += 1;
      if (length == 0) return cursor;
      cursor += length;
    }
    return start;
  }

  int _skipNameInData(Uint8List data, int offset) {
    var cursor = offset;
    while (cursor < data.length) {
      final length = data[cursor];
      cursor += 1;
      if (length == 0) return cursor;
      if ((length & 0xc0) == 0xc0) return cursor + 1;
      cursor += length;
    }
    return data.length;
  }

  int _readUint16(int offset) {
    if (offset + 2 > message.length) return 0;
    return (message[offset] << 8) | message[offset + 1];
  }
}

class _DnsAnswer {
  const _DnsAnswer(this.type, this.dnsClass, this.data);

  final int type;
  final int dnsClass;
  final Uint8List data;
}
