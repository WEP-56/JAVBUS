import 'dart:convert';
import 'dart:io';

import '../storage/app_storage.dart';

class AppSettings {
  const AppSettings({
    required this.panServiceUrl,
    required this.panRequiresApiKey,
    required this.panApiKey,
    required this.lanReceiveDirectory,
    required this.lanAutoStart,
    required this.themeMode,
    required this.accentColor,
    required this.windowsCloseBehavior,
    required this.windowWidth,
    required this.windowHeight,
  });

  final String panServiceUrl;
  final bool panRequiresApiKey;
  final String panApiKey;
  final String lanReceiveDirectory;
  final bool lanAutoStart;
  final String themeMode;
  final String accentColor;
  final String windowsCloseBehavior;
  final double windowWidth;
  final double windowHeight;

  bool get hasPanService => panServiceUrl.trim().isNotEmpty;

  AppSettings copyWith({
    String? panServiceUrl,
    bool? panRequiresApiKey,
    String? panApiKey,
    String? lanReceiveDirectory,
    bool? lanAutoStart,
    String? themeMode,
    String? accentColor,
    String? windowsCloseBehavior,
    double? windowWidth,
    double? windowHeight,
  }) {
    return AppSettings(
      panServiceUrl: panServiceUrl ?? this.panServiceUrl,
      panRequiresApiKey: panRequiresApiKey ?? this.panRequiresApiKey,
      panApiKey: panApiKey ?? this.panApiKey,
      lanReceiveDirectory: lanReceiveDirectory ?? this.lanReceiveDirectory,
      lanAutoStart: lanAutoStart ?? this.lanAutoStart,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      windowsCloseBehavior: windowsCloseBehavior ?? this.windowsCloseBehavior,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'panServiceUrl': panServiceUrl,
      'panRequiresApiKey': panRequiresApiKey,
      'panApiKey': panApiKey,
      'lanReceiveDirectory': lanReceiveDirectory,
      'lanAutoStart': lanAutoStart,
      'themeMode': themeMode,
      'accentColor': accentColor,
      'windowsCloseBehavior': windowsCloseBehavior,
      'windowWidth': windowWidth,
      'windowHeight': windowHeight,
    };
  }

  factory AppSettings.fromJson(Map<String, Object?> json) {
    return AppSettings(
      panServiceUrl: _stringValue(json['panServiceUrl']),
      panRequiresApiKey: _boolValue(json['panRequiresApiKey']),
      panApiKey: _stringValue(json['panApiKey']),
      lanReceiveDirectory: _stringValue(json['lanReceiveDirectory']),
      lanAutoStart: _boolValue(json['lanAutoStart']),
      themeMode: _themeModeValue(json['themeMode']),
      accentColor: _accentColorValue(json['accentColor']),
      windowsCloseBehavior: _windowsCloseBehaviorValue(
        json['windowsCloseBehavior'],
      ),
      windowWidth: _doubleValue(json['windowWidth'], 1280),
      windowHeight: _doubleValue(json['windowHeight'], 720),
    );
  }

  static const AppSettings empty = AppSettings(
    panServiceUrl: '',
    panRequiresApiKey: false,
    panApiKey: '',
    lanReceiveDirectory: '',
    lanAutoStart: false,
    themeMode: 'system',
    accentColor: 'teal',
    windowsCloseBehavior: 'minimizeToTray',
    windowWidth: 1280,
    windowHeight: 720,
  );
}

class AppSettingsStore {
  Future<AppSettings> load() async {
    final File file = await _file();
    if (!await file.exists()) {
      return AppSettings.empty;
    }
    final String raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return AppSettings.empty;
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      return AppSettings.empty;
    }
    return AppSettings.fromJson(decoded);
  }

  Future<void> save(AppSettings settings) async {
    final File file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  Future<File> _file() async {
    final Directory directory = await AppStorage.ensureSubdirectory('settings');
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }
}

String _stringValue(Object? value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

bool _boolValue(Object? value, [bool fallback = false]) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    return value.toLowerCase() == 'true';
  }
  return fallback;
}

double _doubleValue(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

String _themeModeValue(Object? value) {
  final String mode = _stringValue(value, 'system');
  return switch (mode) {
    'light' || 'dark' || 'system' => mode,
    _ => 'system',
  };
}

String _accentColorValue(Object? value) {
  final String color = _stringValue(value, 'teal');
  return switch (color) {
    'teal' || 'blue' || 'violet' || 'rose' || 'amber' || 'green' => color,
    _ => 'teal',
  };
}

String _windowsCloseBehaviorValue(Object? value) {
  final String behavior = _stringValue(value, 'minimizeToTray');
  return switch (behavior) {
    'minimizeToTray' || 'exit' => behavior,
    _ => 'minimizeToTray',
  };
}
