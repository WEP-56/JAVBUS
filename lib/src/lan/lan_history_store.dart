import 'dart:convert';
import 'dart:io';

import '../storage/app_storage.dart';
import 'lan_models.dart';

class LanHistoryStore {
  static const int maxRecords = 200;

  Future<List<LanTransferRecord>> load() async {
    final File file = await _historyFile();
    if (!await file.exists()) {
      return const <LanTransferRecord>[];
    }
    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <LanTransferRecord>[];
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const <LanTransferRecord>[];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(LanTransferRecord.fromJson)
        .toList(growable: false);
  }

  Future<void> add(LanTransferRecord record) async {
    final List<LanTransferRecord> records = <LanTransferRecord>[
      record,
      ...await load(),
    ];
    await save(records.take(maxRecords).toList(growable: false));
  }

  Future<void> save(List<LanTransferRecord> records) async {
    final File file = await _historyFile();
    await file.writeAsString(
      encodeLanJson(
        records.map((LanTransferRecord item) => item.toJson()).toList(),
      ),
    );
  }

  Future<void> clear() async {
    final File file = await _historyFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Directory> receivedDirectory() {
    return AppStorage.ensureSubdirectory('lan/received');
  }

  Future<File> _historyFile() async {
    final Directory directory = await AppStorage.ensureSubdirectory('lan');
    return File('${directory.path}${Platform.pathSeparator}history.json');
  }
}
