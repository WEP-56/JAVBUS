import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'lan_history_store.dart';
import 'lan_models.dart';

class LanTransferService extends ChangeNotifier {
  LanTransferService({LanHistoryStore? historyStore})
    : _historyStore = historyStore ?? LanHistoryStore();

  static const int discoveryPort = 45656;
  static const int transferPort = 45657;
  static const String protocol = 'javbus-lan-v1';

  final LanHistoryStore _historyStore;
  final Map<String, LanPeer> _peers = <String, LanPeer>{};
  final Random _random = Random.secure();

  HttpServer? _server;
  RawDatagramSocket? _discoverySocket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  List<LanTransferRecord> _history = const <LanTransferRecord>[];
  late final String _deviceId = _newId();
  late final String _deviceName = Platform.localHostname.isEmpty
      ? 'JAVBUS 设备'
      : Platform.localHostname;
  bool _starting = false;
  String? _error;

  List<LanPeer> get peers {
    final List<LanPeer> items = _peers.values.toList(growable: false);
    items.sort((LanPeer a, LanPeer b) => a.name.compareTo(b.name));
    return items;
  }

  List<LanTransferRecord> get history => _history;
  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  int? get port => _server?.port;
  bool get running => _server != null;
  bool get starting => _starting;
  String? get error => _error;

  Future<void> start() async {
    if (_starting || running) {
      return;
    }
    _starting = true;
    _error = null;
    notifyListeners();
    try {
      _history = await _historyStore.load();
      _server = await _bindServer();
      unawaited(_server!.listen(_handleRequest).asFuture<void>());
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen(_handleDiscoveryEvent);
      _announceTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => announce(),
      );
      _pruneTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _prunePeers(),
      );
      announce();
    } catch (error) {
      _error = error.toString();
      await stop();
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _discoverySocket?.close();
    _discoverySocket = null;
    await _server?.close(force: true);
    _server = null;
    _peers.clear();
    notifyListeners();
  }

  void announce() {
    final RawDatagramSocket? socket = _discoverySocket;
    final HttpServer? server = _server;
    if (socket == null || server == null) {
      return;
    }
    final Uint8List data = utf8.encode(
      jsonEncode(<String, Object?>{
        'protocol': protocol,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'port': server.port,
        'version': 1,
      }),
    );
    socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
  }

  Future<LanPeer> addManualPeer(String value) async {
    final Uri uri = _parsePeerEndpoint(value);
    final http.Response response = await http
        .get(uri.replace(path: '/api/lan/ping'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: ${response.body}');
    }
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?> || decoded['protocol'] != protocol) {
      throw const FormatException('不是 JAVBUS 互传设备');
    }
    final LanPeer peer = LanPeer(
      id: _string(decoded['deviceId'], 'manual-${uri.host}:${uri.port}'),
      name: _string(decoded['deviceName'], '${uri.host}:${uri.port}'),
      address: uri.host,
      port: uri.port,
      lastSeen: DateTime.now(),
    );
    _peers[peer.id] = peer;
    notifyListeners();
    return peer;
  }

  Future<void> sendText(LanPeer peer, String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final String sessionId = _newId();
    try {
      final http.Response response = await http
          .post(
            Uri.parse('${peer.endpoint}/api/lan/text'),
            headers: <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
            },
            body: jsonEncode(<String, Object?>{
              'protocol': protocol,
              'sessionId': sessionId,
              'senderId': _deviceId,
              'senderName': _deviceName,
              'text': trimmed,
              'createdAt': DateTime.now().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: ${response.body}');
      }
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.outgoing,
          kind: LanTransferKind.text,
          peerId: peer.id,
          peerName: peer.name,
          createdAt: DateTime.now(),
          status: LanTransferStatus.completed,
          text: trimmed,
        ),
      );
    } catch (error) {
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.outgoing,
          kind: LanTransferKind.text,
          peerId: peer.id,
          peerName: peer.name,
          createdAt: DateTime.now(),
          status: LanTransferStatus.failed,
          text: trimmed,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> sendFile(LanPeer peer, File file) async {
    final String sessionId = _newId();
    final int fileSize = await file.length();
    final String fileName = _fileName(file.path);
    try {
      final Uri uri = Uri.parse('${peer.endpoint}/api/lan/file').replace(
        queryParameters: <String, String>{
          'sessionId': sessionId,
          'fileName': fileName,
          'fileSize': fileSize.toString(),
        },
      );
      final http.StreamedRequest request = http.StreamedRequest('POST', uri);
      request.headers.addAll(<String, String>{
        'X-Javbus-Protocol': protocol,
        'X-Javbus-Device-Id': _deviceId,
        'X-Javbus-Device-Name': _deviceName,
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
      });
      request.contentLength = fileSize;
      await request.sink.addStream(file.openRead());
      await request.sink.close();
      final http.StreamedResponse response = await request.send().timeout(
        const Duration(minutes: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await response.stream.bytesToString();
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      await response.stream.drain<void>();
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.outgoing,
          kind: LanTransferKind.file,
          peerId: peer.id,
          peerName: peer.name,
          createdAt: DateTime.now(),
          status: LanTransferStatus.completed,
          fileName: fileName,
          filePath: file.path,
          fileSize: fileSize,
        ),
      );
    } catch (error) {
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.outgoing,
          kind: LanTransferKind.file,
          peerId: peer.id,
          peerName: peer.name,
          createdAt: DateTime.now(),
          status: LanTransferStatus.failed,
          fileName: fileName,
          filePath: file.path,
          fileSize: fileSize,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> clearHistory() async {
    await _historyStore.clear();
    _history = const <LanTransferRecord>[];
    notifyListeners();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/api/lan/ping') {
        _writeJson(request, <String, Object?>{
          'protocol': protocol,
          'deviceId': _deviceId,
          'deviceName': _deviceName,
          'port': _server?.port,
        });
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/api/lan/text') {
        await _receiveText(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/api/lan/file') {
        await _receiveFile(request);
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not found');
      await request.response.close();
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(error.toString());
      await request.response.close();
    }
  }

  Future<void> _receiveText(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?> || decoded['protocol'] != protocol) {
      throw const FormatException('Invalid LAN text payload');
    }
    final String sessionId = _string(decoded['sessionId'], _newId());
    final String senderId = _string(decoded['senderId']);
    final String senderName = _string(
      decoded['senderName'],
      request.connectionInfo?.remoteAddress.address ?? '未知设备',
    );
    final String text = _string(decoded['text']);
    await _addRecord(
      LanTransferRecord(
        id: _newId(),
        sessionId: sessionId,
        direction: LanTransferDirection.incoming,
        kind: LanTransferKind.text,
        peerId: senderId,
        peerName: senderName,
        createdAt: DateTime.now(),
        status: LanTransferStatus.completed,
        text: text,
      ),
    );
    _writeJson(request, <String, Object?>{'ok': true});
  }

  Future<void> _receiveFile(HttpRequest request) async {
    final String sessionId =
        request.uri.queryParameters['sessionId'] ?? _newId();
    final String senderId = request.headers.value('X-Javbus-Device-Id') ?? '';
    final String senderName =
        request.headers.value('X-Javbus-Device-Name') ??
        request.connectionInfo?.remoteAddress.address ??
        '未知设备';
    final String requestedName =
        request.uri.queryParameters['fileName'] ?? 'received-file';
    final Directory directory = await _historyStore.receivedDirectory();
    final String safeName = _safeFileName(requestedName);
    final File file = await _uniqueFile(directory, safeName);
    IOSink? sink;
    int size = 0;
    try {
      sink = file.openWrite();
      await for (final List<int> chunk in request) {
        size += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.incoming,
          kind: LanTransferKind.file,
          peerId: senderId,
          peerName: senderName,
          createdAt: DateTime.now(),
          status: LanTransferStatus.completed,
          fileName: safeName,
          filePath: file.path,
          fileSize: size,
        ),
      );
      _writeJson(request, <String, Object?>{'ok': true});
    } catch (error) {
      await sink?.close();
      if (await file.exists()) {
        await file.delete();
      }
      await _addRecord(
        LanTransferRecord(
          id: _newId(),
          sessionId: sessionId,
          direction: LanTransferDirection.incoming,
          kind: LanTransferKind.file,
          peerId: senderId,
          peerName: senderName,
          createdAt: DateTime.now(),
          status: LanTransferStatus.failed,
          fileName: safeName,
          filePath: file.path,
          fileSize: size,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  void _handleDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    Datagram? datagram;
    while ((datagram = _discoverySocket?.receive()) != null) {
      final Datagram current = datagram!;
      try {
        final String raw = utf8.decode(current.data);
        final Object? decoded = jsonDecode(raw);
        if (decoded is! Map<String, Object?> ||
            decoded['protocol'] != protocol) {
          continue;
        }
        final String id = _string(decoded['deviceId']);
        if (id.isEmpty || id == _deviceId) {
          continue;
        }
        final int port = _intValue(decoded['port']);
        if (port <= 0) {
          continue;
        }
        _peers[id] = LanPeer(
          id: id,
          name: _string(decoded['deviceName'], current.address.address),
          address: current.address.address,
          port: port,
          lastSeen: DateTime.now(),
        );
        notifyListeners();
      } on Object {
        continue;
      }
    }
  }

  Future<void> _addRecord(LanTransferRecord record) async {
    await _historyStore.add(record);
    _history = <LanTransferRecord>[
      record,
      ..._history,
    ].take(LanHistoryStore.maxRecords).toList(growable: false);
    notifyListeners();
  }

  void _prunePeers() {
    final DateTime cutoff = DateTime.now().subtract(
      const Duration(seconds: 15),
    );
    _peers.removeWhere((_, LanPeer peer) => peer.lastSeen.isBefore(cutoff));
    notifyListeners();
  }

  void _writeJson(HttpRequest request, Map<String, Object?> json) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(json));
    unawaited(request.response.close());
  }

  String _newId() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<HttpServer> _bindServer() async {
    try {
      return HttpServer.bind(InternetAddress.anyIPv4, transferPort);
    } on SocketException {
      return HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
  }
}

String _string(Object? value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

int _intValue(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

String _fileName(String path) {
  return path
      .split(RegExp(r'[\\/]'))
      .where((String part) => part.isNotEmpty)
      .last;
}

String _safeFileName(String name) {
  final String cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? 'received-file' : cleaned;
}

Future<File> _uniqueFile(Directory directory, String fileName) async {
  final int dot = fileName.lastIndexOf('.');
  final String stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final String ext = dot > 0 ? fileName.substring(dot) : '';
  File file = File('${directory.path}${Platform.pathSeparator}$fileName');
  int index = 1;
  while (await file.exists()) {
    file = File('${directory.path}${Platform.pathSeparator}$stem ($index)$ext');
    index += 1;
  }
  return file;
}

Uri _parsePeerEndpoint(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('请输入地址');
  }
  final Uri uri = Uri.parse(
    trimmed.startsWith('http://') ? trimmed : 'http://$trimmed',
  );
  if (uri.host.isEmpty) {
    throw const FormatException('地址格式不正确');
  }
  final int port = uri.hasPort ? uri.port : LanTransferService.transferPort;
  return Uri(scheme: 'http', host: uri.host, port: port);
}
