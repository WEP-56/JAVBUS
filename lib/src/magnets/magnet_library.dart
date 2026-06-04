import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/app_storage.dart';

enum FavoriteKind {
  magnet('magnet', '磁力'),
  pan('pan', '网盘'),
  link('link', '链接');

  const FavoriteKind(this.value, this.label);

  final String value;
  final String label;

  static FavoriteKind fromValue(String value) {
    return FavoriteKind.values.firstWhere(
      (FavoriteKind kind) => kind.value == value,
      orElse: () => FavoriteKind.magnet,
    );
  }
}

class StoredFavorite {
  const StoredFavorite({
    required this.id,
    required this.kind,
    required this.title,
    required this.url,
    required this.password,
    required this.tags,
    required this.note,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final FavoriteKind kind;
  final String title;
  final String url;
  final String password;
  final List<String> tags;
  final String note;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get magnet => kind == FavoriteKind.magnet ? url : '';

  StoredFavorite copyWith({
    FavoriteKind? kind,
    String? title,
    String? url,
    String? password,
    List<String>? tags,
    String? note,
    String? source,
    DateTime? updatedAt,
  }) {
    return StoredFavorite(
      id: id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      url: url ?? this.url,
      password: password ?? this.password,
      tags: tags ?? this.tags,
      note: note ?? this.note,
      source: source ?? this.source,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'kind': kind.value,
      'title': title,
      'url': url,
      'password': password,
      'tags': tags,
      'note': note,
      'source': source,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory StoredFavorite.fromJson(Map<String, Object?> json) {
    final String kindValue = _stringValue(json['kind']);
    final String url = _stringValue(json['url'], _stringValue(json['magnet']));
    return StoredFavorite(
      id: _stringValue(json['id']),
      kind: kindValue.isEmpty
          ? FavoriteKind.magnet
          : FavoriteKind.fromValue(kindValue),
      title: _stringValue(json['title']),
      url: url,
      password: _stringValue(json['password']),
      tags: _stringList(json['tags']),
      note: _stringValue(json['note']),
      source: _stringValue(json['source']),
      createdAt:
          DateTime.tryParse(_stringValue(json['createdAt'])) ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(_stringValue(json['updatedAt'])) ?? DateTime.now(),
    );
  }
}

typedef StoredMagnet = StoredFavorite;

class MagnetLibrary {
  MagnetLibrary({Directory? storageRoot}) : _storageRoot = storageRoot;

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Directory? _storageRoot;

  Future<List<StoredFavorite>> load() async {
    final File file = await _file();
    if (await file.exists()) {
      return _readFavorites(file);
    }
    final File legacy = await _legacyFile();
    if (!await legacy.exists()) {
      return const <StoredFavorite>[];
    }
    final List<StoredFavorite> migrated = await _readFavorites(legacy);
    if (migrated.isNotEmpty) {
      await saveAll(migrated);
    }
    return migrated;
  }

  Future<void> saveAll(List<StoredFavorite> items) async {
    final File file = await _file();
    final JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(
        items.map((StoredFavorite item) => item.toJson()).toList(),
      ),
    );
  }

  Future<StoredFavorite> upsert(StoredFavorite item) async {
    final List<StoredFavorite> items = List<StoredFavorite>.of(await load());
    final int index = items.indexWhere(
      (StoredFavorite candidate) => candidate.id == item.id,
    );
    final StoredFavorite updated = item.copyWith(updatedAt: DateTime.now());
    if (index >= 0) {
      items[index] = updated;
    } else {
      items.insert(0, updated);
    }
    await saveAll(items);
    revision.value++;
    return updated;
  }

  Future<void> delete(String id) async {
    final List<StoredFavorite> items = List<StoredFavorite>.of(await load());
    items.removeWhere((StoredFavorite item) => item.id == id);
    await saveAll(items);
    revision.value++;
  }

  Future<List<StoredFavorite>> _readFavorites(File file) async {
    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <StoredFavorite>[];
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const <StoredFavorite>[];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(StoredFavorite.fromJson)
        .where((StoredFavorite item) => item.url.isNotEmpty)
        .toList(growable: false);
  }

  Future<File> _file() async {
    final Directory directory = await _libraryDirectory();
    return File('${directory.path}${Platform.pathSeparator}favorites.json');
  }

  Future<File> _legacyFile() async {
    final Directory directory = await _libraryDirectory();
    return File('${directory.path}${Platform.pathSeparator}magnets.json');
  }

  Future<Directory> _libraryDirectory() async {
    final Directory? root = _storageRoot;
    if (root == null) {
      return AppStorage.ensureSubdirectory('library');
    }
    final Directory directory = Directory(
      '${root.path}${Platform.pathSeparator}library',
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}

StoredFavorite newStoredFavorite({
  required FavoriteKind kind,
  required String title,
  required String url,
  String password = '',
  List<String> tags = const <String>[],
  String note = '',
  String source = '',
  String? id,
}) {
  final DateTime now = DateTime.now();
  return StoredFavorite(
    id: id ?? now.microsecondsSinceEpoch.toString(),
    kind: kind,
    title: title,
    url: url,
    password: password,
    tags: tags,
    note: note,
    source: source,
    createdAt: now,
    updatedAt: now,
  );
}

StoredFavorite newStoredMagnet({
  required String title,
  required String magnet,
  List<String> tags = const <String>[],
  String note = '',
  String source = '',
  String? id,
}) {
  return newStoredFavorite(
    id: id,
    kind: FavoriteKind.magnet,
    title: title,
    url: magnet,
    tags: tags,
    note: note,
    source: source,
  );
}

String _stringValue(Object? value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

List<String> _stringList(Object? value) {
  if (value is! List<Object?>) {
    return const <String>[];
  }
  return value.map((Object? item) => item.toString()).toList(growable: false);
}
