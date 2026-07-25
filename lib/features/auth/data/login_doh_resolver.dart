import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
}

class LoginDohResolver {
  LoginDohResolver({this.timeout = const Duration(seconds: 5), this.cacheTtl = const Duration(minutes: 10)});

  final Duration timeout;
  final Duration cacheTtl;
  final _cache = <String, _CachedResolution>{};
  final _random = Random.secure();

  static const _providers = <_DohProvider>[
    _DohProvider(
      uri: 'https://cloudflare-dns.com/dns-query',
      bootstrapAddresses: ['1.1.1.1', '1.0.0.1'],
      format: _DohFormat.json,
    ),
    _DohProvider(
      uri: 'https://dns.google/resolve',
      bootstrapAddresses: ['8.8.8.8', '8.8.4.4'],
      format: _DohFormat.json,
    ),
    _DohProvider(
      uri: 'https://dns.alidns.com/resolve',
      bootstrapAddresses: ['223.5.5.5', '223.6.6.6'],
      format: _DohFormat.json,
    ),
    _DohProvider(
      uri: 'https://dns.alidns.com/dns-query',
      bootstrapAddresses: ['223.5.5.5', '223.6.6.6'],
      format: _DohFormat.dnsMessage,
    ),
  ];

  Future<LoginDnsResolution> resolve(String host, {bool includeHttps = false}) async {
    final normalizedHost = host.toLowerCase();
    final cached = _cache[normalizedHost];
    if (cached != null && !cached.isExpired) {
      return cached.value;
    }

    final errors = <Object>[];
    for (final provider in _providers) {
      try {
        final result = await _resolveWithProvider(provider, normalizedHost, includeHttps: includeHttps);
        final resolvedAddresses = result.addresses;
        final hasHttpsRecord = result.hasHttpsRecord;
        final hasEchConfig = result.hasEchConfig;

        final unique = <String, InternetAddress>{};
        for (final address in resolvedAddresses) {
          unique[address.address] = address;
        }

        final addresses = unique.values.toList(growable: false);
        if (addresses.isEmpty && !hasHttpsRecord) {
          continue;
        }

        final resolution = LoginDnsResolution(
          host: normalizedHost,
          addresses: addresses,
          hasHttpsRecord: hasHttpsRecord,
          hasEchConfig: hasEchConfig,
        );
        _cache[normalizedHost] = _CachedResolution(resolution, DateTime.now().add(cacheTtl));
        return resolution;
      } catch (error) {
        errors.add(error);
      }
    }

    throw StateError('DoH failed for $normalizedHost: ${errors.isEmpty ? 'empty response' : errors.last}');
  }

  Future<LoginDnsResolution> _resolveWithProvider(
    _DohProvider provider,
    String host, {
    required bool includeHttps,
  }) async {
    final aFuture = _queryAddresses(provider, host, DnsRecordType.a).catchError((Object _) => <InternetAddress>[]);
    final aaaaFuture = _queryAddresses(
      provider,
      host,
      DnsRecordType.aaaa,
    ).catchError((Object _) => <InternetAddress>[]);
    final httpsFuture = includeHttps
        ? _queryHttpsInfo(
            provider,
            host,
          ).catchError((Object _) => const _HttpsInfo(hasHttpsRecord: false, hasEchConfig: false))
        : Future.value(const _HttpsInfo(hasHttpsRecord: false, hasEchConfig: false));

    final results = await Future.wait<dynamic>([aFuture, aaaaFuture, httpsFuture]);
    return LoginDnsResolution(
      host: host,
      addresses: [...results[0] as List<InternetAddress>, ...results[1] as List<InternetAddress>],
      hasHttpsRecord: (results[2] as _HttpsInfo).hasHttpsRecord,
      hasEchConfig: (results[2] as _HttpsInfo).hasEchConfig,
    );
  }

  Future<List<InternetAddress>> _queryAddresses(_DohProvider provider, String host, DnsRecordType type) async {
    if (provider.format == _DohFormat.json) {
      final response = await _queryJson(provider, host, type.code);
      return _parseJsonAddresses(response, type);
    }
    final message = await _query(provider, host, type.code);
    return _DnsMessageParser(message).parseAddresses(type);
  }

  Future<_HttpsInfo> _queryHttpsInfo(_DohProvider provider, String host) async {
    if (provider.format == _DohFormat.json) {
      final response = await _queryJson(provider, host, DnsRecordType.https.code);
      return _parseJsonHttpsInfo(response);
    }
    final message = await _query(provider, host, DnsRecordType.https.code);
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

  Future<Uint8List> _query(_DohProvider provider, String host, int recordType) async {
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
    final uri = Uri.parse(provider.uri);
    final bootstrap = provider.bootstrapAddresses.map(InternetAddress.new).toList(growable: false);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (requestUri) => 'DIRECT';
    client.connectionFactory = (requestUri, proxyHost, proxyPort) async {
      final host = requestUri.host.toLowerCase();
      if (host != uri.host.toLowerCase()) {
        return ConnectionTask.fromSocket(Socket.connect(host, requestUri.port, timeout: timeout), () {});
      }

      return ConnectionTask.fromSocket(_connectFirstAvailable(bootstrap, requestUri.port), () {});
    };
    return client;
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
        if (type == DnsRecordType.a && address.type == InternetAddressType.IPv4) {
          addresses.add(address);
        }
        if (type == DnsRecordType.aaaa && address.type == InternetAddressType.IPv6) {
          addresses.add(address);
        }
      } catch (_) {
        // Ignore CNAME and malformed records in JSON DoH answers.
      }
    }
    return addresses;
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
      hasEchConfig = hasEchConfig || data.contains(' ech=') || data.startsWith('ech=');
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

  Future<List<int>> _readResponseBytes(HttpClientResponse response) {
    final bytes = BytesBuilder(copy: false);
    return response.listen(bytes.add).asFuture<void>().then((_) => bytes.takeBytes());
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

  bool get isExpired => DateTime.now().isAfter(expiresAt);
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
    final answers = _parseAnswers();
    final addresses = <InternetAddress>[];
    for (final answer in answers) {
      if (answer.type == DnsRecordType.a.code && type == DnsRecordType.a && answer.data.length == 4) {
        addresses.add(InternetAddress(answer.data.join('.'), type: InternetAddressType.IPv4));
      }
      if (answer.type == DnsRecordType.aaaa.code && type == DnsRecordType.aaaa && answer.data.length == 16) {
        final parts = <String>[];
        for (var i = 0; i < 16; i += 2) {
          parts.add(((answer.data[i] << 8) | answer.data[i + 1]).toRadixString(16));
        }
        addresses.add(InternetAddress(parts.join(':'), type: InternetAddressType.IPv6));
      }
    }
    return addresses;
  }

  _HttpsInfo parseHttpsInfo() {
    final answers = _parseAnswers();
    var hasHttpsRecord = false;
    var hasEchConfig = false;
    for (final answer in answers) {
      if (answer.type != DnsRecordType.https.code) continue;
      hasHttpsRecord = true;
      hasEchConfig = hasEchConfig || _httpsRecordHasEch(answer.data);
    }
    return _HttpsInfo(hasHttpsRecord: hasHttpsRecord, hasEchConfig: hasEchConfig);
  }

  List<_DnsAnswer> _parseAnswers() {
    if (message.length < 12) {
      throw const FormatException('DNS response is too short');
    }
    final flags = _readUint16(2);
    final rcode = flags & 0x000f;
    if (rcode != 0) {
      throw FormatException('DNS response error code $rcode');
    }
    final questionCount = _readUint16(4);
    final answerCount = _readUint16(6);
    var offset = 12;
    for (var i = 0; i < questionCount; i++) {
      offset = _skipName(offset) + 4;
      _checkOffset(offset);
    }

    final answers = <_DnsAnswer>[];
    for (var i = 0; i < answerCount; i++) {
      offset = _skipName(offset);
      final type = _readUint16(offset);
      offset += 2;
      offset += 2; // class
      offset += 4; // ttl
      final rdLength = _readUint16(offset);
      offset += 2;
      final dataEnd = offset + rdLength;
      _checkOffset(dataEnd);
      answers.add(_DnsAnswer(type, message.sublist(offset, dataEnd)));
      offset = dataEnd;
    }
    return answers;
  }

  bool _httpsRecordHasEch(Uint8List data) {
    if (data.length < 3) return false;
    var offset = 2; // priority
    offset = _skipNameInData(data, offset);
    while (offset + 4 <= data.length) {
      final key = (data[offset] << 8) | data[offset + 1];
      final length = (data[offset + 2] << 8) | data[offset + 3];
      offset += 4;
      if (offset + length > data.length) return false;
      if (key == 5 && length > 0) return true; // SvcParamKey ech
      offset += length;
    }
    return false;
  }

  int _skipName(int offset) {
    var currentOffset = offset;
    while (true) {
      _checkOffset(currentOffset + 1);
      final length = message[currentOffset];
      if ((length & 0xc0) == 0xc0) {
        _checkOffset(currentOffset + 2);
        return currentOffset + 2;
      }
      if (length == 0) {
        return currentOffset + 1;
      }
      currentOffset += length + 1;
      _checkOffset(currentOffset);
    }
  }

  int _skipNameInData(Uint8List data, int offset) {
    var currentOffset = offset;
    while (currentOffset < data.length) {
      final length = data[currentOffset];
      currentOffset += 1;
      if (length == 0) return currentOffset;
      currentOffset += length;
    }
    return data.length;
  }

  int _readUint16(int offset) {
    _checkOffset(offset + 2);
    return (message[offset] << 8) | message[offset + 1];
  }

  void _checkOffset(int offset) {
    if (offset > message.length) {
      throw const FormatException('DNS response is truncated');
    }
  }
}

class _DnsAnswer {
  const _DnsAnswer(this.type, this.data);

  final int type;
  final Uint8List data;
}
