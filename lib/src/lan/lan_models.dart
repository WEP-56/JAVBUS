import 'dart:convert';

enum LanTransferKind { text, file }

enum LanTransferDirection { incoming, outgoing }

enum LanTransferStatus { completed, failed }

class LanPeer {
  const LanPeer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String address;
  final int port;
  final DateTime lastSeen;

  String get endpoint => 'http://$address:$port';
}

class LanTransferRecord {
  const LanTransferRecord({
    required this.id,
    required this.sessionId,
    required this.direction,
    required this.kind,
    required this.peerId,
    required this.peerName,
    required this.createdAt,
    required this.status,
    this.text,
    this.fileName,
    this.filePath,
    this.fileSize = 0,
    this.error,
  });

  final String id;
  final String sessionId;
  final LanTransferDirection direction;
  final LanTransferKind kind;
  final String peerId;
  final String peerName;
  final DateTime createdAt;
  final LanTransferStatus status;
  final String? text;
  final String? fileName;
  final String? filePath;
  final int fileSize;
  final String? error;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'sessionId': sessionId,
      'direction': direction.name,
      'kind': kind.name,
      'peerId': peerId,
      'peerName': peerName,
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
      if (text != null) 'text': text,
      if (fileName != null) 'fileName': fileName,
      if (filePath != null) 'filePath': filePath,
      'fileSize': fileSize,
      if (error != null) 'error': error,
    };
  }

  factory LanTransferRecord.fromJson(Map<String, Object?> json) {
    return LanTransferRecord(
      id: _string(json['id']),
      sessionId: _string(json['sessionId']),
      direction: _enumValue(
        LanTransferDirection.values,
        _string(json['direction']),
        LanTransferDirection.incoming,
      ),
      kind: _enumValue(
        LanTransferKind.values,
        _string(json['kind']),
        LanTransferKind.text,
      ),
      peerId: _string(json['peerId']),
      peerName: _string(json['peerName'], '未知设备'),
      createdAt:
          DateTime.tryParse(_string(json['createdAt'])) ?? DateTime.now(),
      status: _enumValue(
        LanTransferStatus.values,
        _string(json['status']),
        LanTransferStatus.completed,
      ),
      text: _nullableString(json['text']),
      fileName: _nullableString(json['fileName']),
      filePath: _nullableString(json['filePath']),
      fileSize: _intValue(json['fileSize']),
      error: _nullableString(json['error']),
    );
  }
}

String encodeLanJson(Object? value) {
  return const JsonEncoder.withIndent('  ').convert(value);
}

String _string(Object? value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

String? _nullableString(Object? value) {
  if (value == null) {
    return null;
  }
  final String text = value.toString();
  return text.isEmpty ? null : text;
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

T _enumValue<T extends Enum>(List<T> values, String name, T fallback) {
  for (final T value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}
