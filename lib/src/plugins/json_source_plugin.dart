import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../storage/app_storage.dart';
import 'magnet_item.dart';

class JsonSourcePlugin {
  const JsonSourcePlugin({
    required this.schemaVersion,
    required this.id,
    required this.name,
    required this.enabled,
    required this.baseUrl,
    required this.capabilities,
    required this.announcement,
    required this.headers,
    required this.search,
    required this.detail,
    required this.fields,
    required this.fileFields,
    required this.defaults,
  });

  final int schemaVersion;
  final String id;
  final String name;
  final bool enabled;
  final Uri baseUrl;
  final PluginCapabilities capabilities;
  final PluginAnnouncement? announcement;
  final Map<String, String> headers;
  final PluginEndpoint search;
  final PluginEndpoint? detail;
  final Map<String, String> fields;
  final Map<String, String> fileFields;
  final Map<String, String> defaults;

  JsonSourcePlugin copyWith({Uri? baseUrl}) {
    return JsonSourcePlugin(
      schemaVersion: schemaVersion,
      id: id,
      name: name,
      enabled: enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      capabilities: capabilities,
      announcement: announcement,
      headers: headers,
      search: search,
      detail: detail,
      fields: fields,
      fileFields: fileFields,
      defaults: defaults,
    );
  }

  factory JsonSourcePlugin.fromJson(Map<String, Object?> json) {
    final Object? searchJson = json['search'];
    if (searchJson is! Map<String, Object?>) {
      throw const PluginException('插件缺少 search 配置');
    }

    final Object? detailJson = json['detail'];
    final Object? announcementJson = json['announcement'];
    final PluginAnnouncement? announcement =
        announcementJson is Map<String, Object?>
        ? PluginAnnouncement.fromJson(announcementJson)
        : null;

    // baseUrl is optional when announcement is enabled
    final String baseUrlString = _stringValue(json['baseUrl']);
    final Uri baseUrl = baseUrlString.isEmpty
        ? Uri.parse('https://placeholder.local')
        : Uri.parse(baseUrlString);

    return JsonSourcePlugin(
      schemaVersion: _intValue(json['schemaVersion'], 1),
      id: _stringValue(json['id']),
      name: _stringValue(json['name']),
      enabled: _boolValue(json['enabled'], true),
      baseUrl: baseUrl,
      capabilities: PluginCapabilities.fromJson(json['capabilities']),
      announcement: announcement,
      headers: _stringMap(json['headers']),
      search: PluginEndpoint.fromJson(searchJson),
      detail: detailJson is Map<String, Object?>
          ? PluginEndpoint.fromJson(detailJson)
          : null,
      fields: _stringMap(json['fields']),
      fileFields: _stringMap(json['fileFields']),
      defaults: _stringMap(json['defaults']),
    );
  }

  Future<PluginSearchResult> runSearch({
    required String query,
    required int page,
    http.Client? client,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response response = await _get(
        httpClient,
        search,
        _variablesForSearch(query: query, page: page),
        extraHeaders,
      );
      _throwIfHumanVerification(response);
      if (response.statusCode != 200) {
        throw PluginException('$name 搜索失败：HTTP ${response.statusCode}');
      }

      if (search.isHtml) {
        return parseSearchHtml(response.body, page: page);
      }

      final Object? decoded = jsonDecode(response.body);
      final Object? itemsValue = _valueAt(decoded, search.itemsPath);
      if (itemsValue is! List<Object?>) {
        throw PluginException('$name 搜索返回缺少列表：${search.itemsPath}');
      }

      final int total = _intValue(_valueAt(decoded, search.totalPath));
      final int currentPage = _intValue(
        _valueAt(decoded, search.currentPagePath),
        page,
      );
      final int lastPage = search.lastPagePath.isNotEmpty
          ? _intValue(_valueAt(decoded, search.lastPagePath), page)
          : _lastPageFromTotal(total, search.pageSize);

      return PluginSearchResult(
        items: itemsValue
            .whereType<Map<String, Object?>>()
            .map((Map<String, Object?> item) => _itemFromJson(item))
            .toList(growable: false),
        currentPage: currentPage <= 0 ? page : currentPage,
        lastPage: lastPage <= 0 ? page : lastPage,
        total: total,
      );
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  PluginSearchResult parseSearchHtml(String html, {required int page}) {
    final List<Map<String, Object?>> items = _htmlItems(html, search);
    final int total = _firstIntMatch(html, search.totalPattern, items.length);
    final int lastPage = search.lastPagePattern.isNotEmpty
        ? _firstIntMatch(html, search.lastPagePattern, page)
        : _lastPageFromTotal(total, search.pageSize);
    return PluginSearchResult(
      items: items
          .map((Map<String, Object?> item) => _itemFromJson(item))
          .where((MagnetItem item) => item.sourceItemId.isNotEmpty)
          .toList(growable: false),
      currentPage: page,
      lastPage: lastPage <= 0 ? page : lastPage,
      total: total,
    );
  }

  Uri resolveSearchUrl({required String query, required int page}) {
    return _resolveEndpoint(
      search.url,
      _variablesForSearch(query: query, page: page),
    );
  }

  Future<MagnetItem> runDetail(
    MagnetItem item, {
    http.Client? client,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final PluginEndpoint? endpoint = detail;
    if (endpoint == null) {
      return item;
    }

    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response response = await _get(
        httpClient,
        endpoint,
        _variablesForItem(item),
        extraHeaders,
      );
      _throwIfHumanVerification(response);
      if (response.statusCode != 200) {
        throw PluginException('$name 详情失败：HTTP ${response.statusCode}');
      }

      if (endpoint.isHtml) {
        return parseDetailHtml(item, response.body);
      }

      final Object? decoded = jsonDecode(response.body);
      final Object? root = endpoint.rootPath.isEmpty
          ? decoded
          : _valueAt(decoded, endpoint.rootPath);
      if (root is! Map<String, Object?>) {
        throw PluginException('$name 详情返回格式异常');
      }

      final MagnetItem merged = _itemFromJson(root, fallback: item);
      final Object? filesValue = _valueAt(root, endpoint.filesPath);
      if (filesValue is! List<Object?>) {
        return merged;
      }

      return merged.copyWith(
        files: filesValue
            .whereType<Map<String, Object?>>()
            .map(_fileFromJson)
            .toList(growable: false),
      );
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  MagnetItem parseDetailHtml(MagnetItem item, String html) {
    final PluginEndpoint? endpoint = detail;
    if (endpoint == null || !endpoint.isHtml) {
      return item;
    }
    final List<Map<String, Object?>> roots = _htmlItems(html, endpoint);
    final MagnetItem merged = roots.isEmpty
        ? item
        : _itemFromJson(roots.first, fallback: item);
    return merged.copyWith(files: _htmlFiles(html, endpoint));
  }

  Uri? resolveDetailUrl(MagnetItem item) {
    final PluginEndpoint? endpoint = detail;
    if (endpoint == null) {
      return null;
    }
    return _resolveEndpoint(endpoint.url, _variablesForItem(item));
  }

  MagnetItem _itemFromJson(Map<String, Object?> json, {MagnetItem? fallback}) {
    final String infoHash = _field(
      json,
      'infoHash',
      fallback?.infoHash,
    ).toUpperCase();
    final Map<String, String> variables = <String, String>{
      'infoHash': infoHash,
      'infoHashLower': infoHash.toLowerCase(),
      'infoHashUpper': infoHash.toUpperCase(),
      'sourceItemId': _field(json, 'sourceItemId', fallback?.sourceItemId),
    };

    final String sourceItemId = variables['sourceItemId']!.isNotEmpty
        ? variables['sourceItemId']!
        : infoHash;
    variables['sourceItemId'] = sourceItemId;
    variables.addAll(_encodedVariables(variables));

    return MagnetItem(
      pluginId: id,
      pluginName: name,
      sourceItemId: sourceItemId,
      title: _field(json, 'title', fallback?.title),
      infoHash: infoHash,
      magnet: _fieldOrDefault(json, 'magnet', variables, fallback?.magnet),
      size: _intValue(_fieldRaw(json, 'size'), fallback?.size ?? 0),
      humanSize: _field(json, 'humanSize', fallback?.humanSize),
      seeders: _intValue(_fieldRaw(json, 'seeders'), fallback?.seeders ?? 0),
      leechers: _intValue(_fieldRaw(json, 'leechers'), fallback?.leechers ?? 0),
      score: _doubleValue(_fieldRaw(json, 'score'), fallback?.score ?? 0),
      health: _doubleValue(_fieldRaw(json, 'health'), fallback?.health ?? 0),
      verified: _boolValue(
        _fieldRaw(json, 'verified'),
        fallback?.verified ?? false,
      ),
      largestFile: _field(json, 'largestFile', fallback?.largestFile),
      webUrl: _absoluteUrl(
        _fieldOrDefault(json, 'webUrl', variables, fallback?.webUrl),
      ),
      createdAt:
          _dateValue(_fieldRaw(json, 'createdAt')) ?? fallback?.createdAt,
      lastSeen: _dateValue(_fieldRaw(json, 'lastSeen')) ?? fallback?.lastSeen,
      files: fallback?.files ?? const <MagnetFile>[],
    );
  }

  MagnetFile _fileFromJson(Map<String, Object?> json) {
    return MagnetFile(
      path: _fileField(json, 'path'),
      size: _intValue(_fileFieldRaw(json, 'size')),
      humanSize: _fileField(json, 'humanSize'),
    );
  }

  String _field(Map<String, Object?> json, String key, [String? fallback]) {
    final Object? value = _fieldRaw(json, key);
    if (value == null) {
      return fallback ?? '';
    }
    return value.toString();
  }

  Object? _fieldRaw(Map<String, Object?> json, String key) {
    final String? path = fields[key];
    if (path == null || path.isEmpty) {
      return null;
    }
    return _valueAt(json, path);
  }

  String _fieldOrDefault(
    Map<String, Object?> json,
    String key,
    Map<String, String> variables, [
    String? fallback,
  ]) {
    final String value = _field(json, key, fallback);
    if (value.isNotEmpty) {
      return value;
    }
    final String? template = defaults[key];
    if (template == null) {
      return fallback ?? '';
    }
    if (key == 'magnet' && (variables['infoHash'] ?? '').isEmpty) {
      return fallback ?? '';
    }
    return _applyTemplate(template, variables);
  }

  String _fileField(Map<String, Object?> json, String key) {
    final Object? value = _fileFieldRaw(json, key);
    return value?.toString() ?? '';
  }

  Object? _fileFieldRaw(Map<String, Object?> json, String key) {
    final String? path = fileFields[key];
    if (path == null || path.isEmpty) {
      return null;
    }
    return _valueAt(json, path);
  }

  Uri _resolveEndpoint(String pathTemplate, Map<String, String> variables) {
    final String path = _applyTemplate(pathTemplate, variables);
    final Uri parsed = Uri.parse(path);
    if (parsed.hasScheme) {
      return parsed;
    }
    return baseUrl.resolve(path);
  }

  Future<http.Response> _get(
    http.Client httpClient,
    PluginEndpoint endpoint,
    Map<String, String> variables,
    Map<String, String> extraHeaders,
  ) async {
    if (endpoint.method.toUpperCase() != 'GET') {
      throw PluginException('$name 暂只支持 GET 插件请求');
    }
    final Uri uri = _resolveEndpoint(endpoint.url, variables);
    try {
      return await httpClient
          .get(
            uri,
            headers: <String, String>{
              ...headers,
              ...endpoint.headers,
              ...extraHeaders,
            },
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw PluginException('$name 请求超时：$uri');
    } on SocketException catch (error) {
      throw PluginException('$name 网络连接失败：${error.message}：$uri');
    } on http.ClientException catch (error) {
      throw PluginException('$name HTTP 请求失败：$error');
    }
  }

  List<Map<String, Object?>> _htmlItems(String html, PluginEndpoint endpoint) {
    if (endpoint.itemPattern.isEmpty) {
      throw PluginException('$name HTML 插件缺少 itemPattern');
    }
    return _matchesAsMaps(
      _htmlScope(html, endpoint),
      endpoint.itemPattern,
      fields.values,
    );
  }

  List<MagnetFile> _htmlFiles(String html, PluginEndpoint endpoint) {
    if (endpoint.filePattern.isEmpty) {
      return const <MagnetFile>[];
    }
    return _matchesAsMaps(
      _htmlFileScope(html, endpoint),
      endpoint.filePattern,
      fileFields.values,
    ).map(_fileFromJson).toList(growable: false);
  }

  String _htmlScope(String html, PluginEndpoint endpoint) {
    if (endpoint.rootPattern.isEmpty) {
      return html;
    }
    final RegExpMatch? match = RegExp(
      endpoint.rootPattern,
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    ).firstMatch(html);
    return match?.group(1) ?? match?.group(0) ?? html;
  }

  String _htmlFileScope(String html, PluginEndpoint endpoint) {
    if (endpoint.fileRootPattern.isEmpty) {
      return _htmlScope(html, endpoint);
    }
    final RegExpMatch? match = RegExp(
      endpoint.fileRootPattern,
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    ).firstMatch(html);
    return match?.group(1) ?? match?.group(0) ?? _htmlScope(html, endpoint);
  }

  Map<String, String> _variablesForItem(MagnetItem item) {
    final Map<String, String> variables = <String, String>{
      'sourceItemId': item.sourceItemId,
      'infoHash': item.infoHash,
      'infoHashLower': item.infoHash.toLowerCase(),
      'infoHashUpper': item.infoHash.toUpperCase(),
    };
    return <String, String>{...variables, ..._encodedVariables(variables)};
  }

  Map<String, String> _variablesForSearch({
    required String query,
    required int page,
  }) {
    final int page0 = page > 0 ? page - 1 : 0;
    return <String, String>{
      'query': Uri.encodeComponent(query),
      'queryRaw': query,
      'queryBase64': _base64NoPadding(query),
      'page': page.toString(),
      'page0': page0.toString(),
    };
  }

  String _absoluteUrl(String url) {
    if (url.isEmpty) {
      return '';
    }
    final Uri parsed = Uri.parse(url);
    if (parsed.hasScheme) {
      return url;
    }
    return baseUrl.resolve(url).toString();
  }

  void _throwIfHumanVerification(http.Response response) {
    if (!capabilities.requiresHumanVerification) {
      return;
    }
    if (!_looksLikeHumanVerification(response)) {
      return;
    }
    throw PluginHumanVerificationException(
      '$name requires human verification before retrying.',
      verificationUrl: response.request?.url ?? baseUrl,
    );
  }
}

class PluginCapabilities {
  const PluginCapabilities({required this.requiresHumanVerification});

  final bool requiresHumanVerification;

  factory PluginCapabilities.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return const PluginCapabilities(requiresHumanVerification: false);
    }
    return PluginCapabilities(
      requiresHumanVerification: _boolValue(json['requiresHumanVerification']),
    );
  }
}

class PluginAnnouncement {
  const PluginAnnouncement({
    required this.enabled,
    required this.url,
    required this.urlPattern,
    required this.urlDecoding,
    required this.targetPattern,
    required this.steps,
  });

  final bool enabled;
  final String url;
  final String urlPattern;
  final String urlDecoding;
  final String targetPattern;
  final List<PluginAnnouncementStep> steps;

  factory PluginAnnouncement.fromJson(Map<String, Object?> json) {
    return PluginAnnouncement(
      enabled: _boolValue(json['enabled']),
      url: _stringValue(json['url']),
      urlPattern: _stringValue(json['urlPattern']),
      urlDecoding: _stringValue(json['urlDecoding'], 'none'),
      targetPattern: _stringValue(json['targetPattern']),
      steps: _announcementStepsFromJson(json['steps']),
    );
  }
}

class PluginAnnouncementStep {
  const PluginAnnouncementStep({
    required this.url,
    required this.urlPattern,
    required this.urlDecoding,
    required this.targetPattern,
  });

  final String url;
  final String urlPattern;
  final String urlDecoding;
  final String targetPattern;

  factory PluginAnnouncementStep.fromJson(Map<String, Object?> json) {
    return PluginAnnouncementStep(
      url: _stringValue(json['url']),
      urlPattern: _stringValue(
        json['urlPattern'],
        _stringValue(json['extract']),
      ),
      urlDecoding: _stringValue(
        json['urlDecoding'],
        _stringValue(json['decode'], 'none'),
      ),
      targetPattern: _stringValue(json['targetPattern']),
    );
  }
}

class PluginEndpoint {
  const PluginEndpoint({
    required this.method,
    required this.url,
    required this.responseType,
    required this.headers,
    required this.itemsPath,
    required this.totalPath,
    required this.currentPagePath,
    required this.lastPagePath,
    required this.rootPath,
    required this.filesPath,
    required this.rootPattern,
    required this.itemPattern,
    required this.fileRootPattern,
    required this.filePattern,
    required this.totalPattern,
    required this.lastPagePattern,
    required this.pageSize,
  });

  final String method;
  final String url;
  final String responseType;
  final Map<String, String> headers;
  final String itemsPath;
  final String totalPath;
  final String currentPagePath;
  final String lastPagePath;
  final String rootPath;
  final String filesPath;
  final String rootPattern;
  final String itemPattern;
  final String fileRootPattern;
  final String filePattern;
  final String totalPattern;
  final String lastPagePattern;
  final int pageSize;

  bool get isHtml => responseType.toLowerCase() == 'html';

  factory PluginEndpoint.fromJson(Map<String, Object?> json) {
    return PluginEndpoint(
      method: _stringValue(json['method'], 'GET'),
      url: _stringValue(json['url']),
      responseType: _stringValue(json['responseType'], 'json'),
      headers: _stringMap(json['headers']),
      itemsPath: _stringValue(json['itemsPath']),
      totalPath: _stringValue(json['totalPath']),
      currentPagePath: _stringValue(json['currentPagePath']),
      lastPagePath: _stringValue(json['lastPagePath']),
      rootPath: _stringValue(json['rootPath']),
      filesPath: _stringValue(json['filesPath']),
      rootPattern: _stringValue(json['rootPattern']),
      itemPattern: _stringValue(json['itemPattern']),
      fileRootPattern: _stringValue(json['fileRootPattern']),
      filePattern: _stringValue(json['filePattern']),
      totalPattern: _stringValue(json['totalPattern']),
      lastPagePattern: _stringValue(json['lastPagePattern']),
      pageSize: _intValue(json['pageSize'], 20),
    );
  }
}

class JsonPluginRegistry {
  factory JsonPluginRegistry({http.Client? client}) {
    final http.Client resolvedClient = client ?? _createDefaultHttpClient();
    return JsonPluginRegistry._(
      client: resolvedClient,
      resolver: AnnouncementResolver(client: resolvedClient),
    );
  }

  JsonPluginRegistry._({
    required http.Client client,
    required AnnouncementResolver resolver,
  }) : _client = client,
       _resolver = resolver;

  final http.Client _client;
  final AnnouncementResolver _resolver;
  final Map<String, String> _cookiesByHost = <String, String>{};
  final Map<String, PluginRuntimeState> _states =
      <String, PluginRuntimeState>{};

  Future<List<JsonSourcePlugin>> loadInstalledPlugins() async {
    final Directory directory = await pluginsDirectory();
    final List<FileSystemEntity> entries = await directory
        .list()
        .where((FileSystemEntity entity) => entity is File)
        .toList();
    entries.sort(
      (FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path),
    );

    final List<JsonSourcePlugin> plugins = <JsonSourcePlugin>[];
    for (final FileSystemEntity entity in entries) {
      if (!entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      try {
        final String raw = await File(entity.path).readAsString();
        plugins.add(parsePluginJson(raw));
      } on Object {
        // Keep one broken local plugin from blocking the whole app.
      }
    }
    return plugins;
  }

  Future<Directory> pluginsDirectory() {
    return AppStorage.ensureSubdirectory('plugins');
  }

  Future<JsonSourcePlugin> savePluginJson(
    String raw, {
    String? replacingId,
  }) async {
    final JsonSourcePlugin plugin = parsePluginJson(raw);
    final Directory directory = await pluginsDirectory();
    final File file = _pluginFile(directory, plugin.id);
    final bool isFirstInstall = replacingId == null && !await file.exists();
    if (isFirstInstall) {
      await _checkAnnouncementForFirstInstall(plugin);
    }
    if (replacingId != null &&
        replacingId.isNotEmpty &&
        replacingId != plugin.id) {
      final File previous = _pluginFile(directory, replacingId);
      if (await previous.exists()) {
        await previous.delete();
      }
    }
    await file.writeAsString(_prettyPluginJson(raw));
    return plugin;
  }

  Future<String?> checkAnnouncement(JsonSourcePlugin plugin) {
    return refreshAnnouncementUrl(plugin);
  }

  Future<void> _checkAnnouncementForFirstInstall(
    JsonSourcePlugin plugin,
  ) async {
    if (plugin.announcement == null || !plugin.announcement!.enabled) {
      return;
    }
    try {
      await refreshAnnouncementUrl(plugin);
    } on Object catch (error) {
      throw PluginException('首次安装需要先通过发布页获取地址：$error');
    }
  }

  Future<void> deletePlugin(String pluginId) async {
    final Directory directory = await pluginsDirectory();
    final File file = _pluginFile(directory, pluginId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<String> readPluginJson(String pluginId) async {
    final Directory directory = await pluginsDirectory();
    final File file = _pluginFile(directory, pluginId);
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }

  Future<PluginSearchResult> search(
    JsonSourcePlugin plugin, {
    required String query,
    required int page,
  }) async {
    _log('搜索', '开始搜索 - 插件: ${plugin.name}, 关键词: $query, 页码: $page');
    final PluginRuntimeState state = _getOrCreateState(plugin.id);
    final Uri effectiveBaseUrl = await _getEffectiveBaseUrl(plugin, state);
    _log('搜索', '使用地址: $effectiveBaseUrl');

    try {
      final PluginSearchResult result = await _runSearchWithBaseUrl(
        plugin,
        effectiveBaseUrl,
        query: query,
        page: page,
      );
      _log('搜索', '搜索成功 - 结果数: ${result.items.length}');
      state.lastSuccessfulSearch = DateTime.now();
      state.consecutiveFailures = 0;
      return result;
    } on PluginHumanVerificationException {
      rethrow;
    } on Object catch (error) {
      state.consecutiveFailures++;
      _log('搜索', '搜索失败 - 连续失败次数: ${state.consecutiveFailures}');

      if (plugin.announcement != null && plugin.announcement!.enabled) {
        _log('搜索', '尝试从发布页重新获取地址...');
        try {
          final String newBaseUrl = await _resolver.resolveBaseUrl(
            plugin.announcement!,
          );
          _log('搜索', '重新获取地址成功: $newBaseUrl');
          state.resolvedBaseUrl = newBaseUrl;
          state.lastAnnouncementCheck = DateTime.now();

          // Retry search with new baseUrl
          final PluginSearchResult result = await _runSearchWithBaseUrl(
            plugin,
            Uri.parse(newBaseUrl),
            query: query,
            page: page,
          );
          _log('搜索', '重试搜索成功 - 结果数: ${result.items.length}');
          state.lastSuccessfulSearch = DateTime.now();
          state.consecutiveFailures = 0;
          return result;
        } on Object catch (e) {
          _log('搜索', '重试失败: $e');
          throw PluginException('${plugin.name} 搜索失败：$error；发布页刷新/重试失败：$e');
        }
      }

      rethrow;
    }
  }

  Future<PluginSearchResult> _runSearchWithBaseUrl(
    JsonSourcePlugin plugin,
    Uri baseUrl, {
    required String query,
    required int page,
  }) {
    final JsonSourcePlugin effectivePlugin = plugin.copyWith(baseUrl: baseUrl);

    return effectivePlugin.runSearch(
      query: query,
      page: page,
      client: _client,
      extraHeaders: _extraHeadersFor(effectivePlugin),
    );
  }

  Future<Uri> _getEffectiveBaseUrl(
    JsonSourcePlugin plugin,
    PluginRuntimeState state,
  ) async {
    // If we have a resolved baseUrl from announcement, use it
    if (state.resolvedBaseUrl != null && state.resolvedBaseUrl!.isNotEmpty) {
      _log('发布页', '使用缓存的地址: ${state.resolvedBaseUrl}');
      return Uri.parse(state.resolvedBaseUrl!);
    }

    // If announcement is enabled, check it on first use
    if (plugin.announcement != null && plugin.announcement!.enabled) {
      _log('发布页', '开始从发布页获取地址: ${plugin.announcement!.url}');
      try {
        final String newBaseUrl = await _resolver.resolveBaseUrl(
          plugin.announcement!,
        );
        _log('发布页', '成功获取地址: $newBaseUrl');
        state.resolvedBaseUrl = newBaseUrl;
        state.lastAnnouncementCheck = DateTime.now();
        return Uri.parse(newBaseUrl);
      } on Object catch (e) {
        _log('发布页', '获取地址失败: $e');
        // If we have no fallback baseUrl, rethrow
        if (plugin.baseUrl.host == 'placeholder.local') {
          rethrow;
        }
        // Otherwise fall back to plugin's baseUrl
        _log('发布页', '使用后备地址: ${plugin.baseUrl}');
      }
    }

    // Fall back to plugin's baseUrl
    return plugin.baseUrl;
  }

  PluginRuntimeState _getOrCreateState(String pluginId) {
    return _states.putIfAbsent(pluginId, () => PluginRuntimeState());
  }

  Future<String?> refreshAnnouncementUrl(JsonSourcePlugin plugin) async {
    if (plugin.announcement == null || !plugin.announcement!.enabled) {
      return null;
    }

    try {
      final String newBaseUrl = await _resolver.resolveBaseUrl(
        plugin.announcement!,
      );
      final PluginRuntimeState state = _getOrCreateState(plugin.id);
      state.resolvedBaseUrl = newBaseUrl;
      state.lastAnnouncementCheck = DateTime.now();
      state.consecutiveFailures = 0;
      return newBaseUrl;
    } on Object {
      rethrow;
    }
  }

  String? getResolvedBaseUrl(String pluginId) {
    return _states[pluginId]?.resolvedBaseUrl;
  }

  Future<MagnetItem> details(JsonSourcePlugin plugin, MagnetItem item) async {
    final PluginRuntimeState state = _getOrCreateState(plugin.id);
    final Uri effectiveBaseUrl = await _getEffectiveBaseUrl(plugin, state);

    final JsonSourcePlugin effectivePlugin = plugin.copyWith(
      baseUrl: effectiveBaseUrl,
    );

    return effectivePlugin.runDetail(
      item,
      client: _client,
      extraHeaders: _extraHeadersFor(effectivePlugin),
    );
  }

  void setVerificationCookie(JsonSourcePlugin plugin, String cookie) {
    final String normalized = _normalizeCookie(cookie);
    if (normalized.isEmpty) {
      return;
    }

    // Use resolved baseUrl host if available
    final PluginRuntimeState state = _getOrCreateState(plugin.id);
    String host = plugin.baseUrl.host;
    if (state.resolvedBaseUrl != null && state.resolvedBaseUrl!.isNotEmpty) {
      final Uri? resolvedUri = Uri.tryParse(state.resolvedBaseUrl!);
      if (resolvedUri != null && resolvedUri.host.isNotEmpty) {
        host = resolvedUri.host;
      }
    }

    _log('Cookie', '保存 Cookie 到 host: $host');
    _cookiesByHost[host] = normalized;
  }

  Map<String, String> _extraHeadersFor(JsonSourcePlugin plugin) {
    final String host = plugin.baseUrl.host;
    final String? cookie = _cookiesByHost[host];
    if (cookie == null || cookie.isEmpty) {
      return const <String, String>{};
    }
    _log('Cookie', '使用 Cookie for host: $host');
    return <String, String>{'Cookie': cookie};
  }
}

void _log(String tag, String message) {
  developer.log(message, name: 'javbus.$tag');
}

http.Client _createDefaultHttpClient() {
  final HttpClient httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 20);

  final String proxyRule = _proxyRule();
  if (proxyRule != 'DIRECT') {
    httpClient.findProxy = (_) => proxyRule;
  }

  return IOClient(httpClient);
}

String _proxyRule() {
  final _ProxyAddress? configured = _proxyFromEnvironment();
  if (configured != null) {
    return 'PROXY ${configured.host}:${configured.port}; DIRECT';
  }

  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return 'DIRECT';
  }

  const List<int> commonHttpProxyPorts = <int>[
    7890,
    7897,
    7899,
    10809,
    10808,
    8080,
  ];
  for (final int port in commonHttpProxyPorts) {
    if (_isPortOpen('127.0.0.1', port)) {
      return 'PROXY 127.0.0.1:$port; DIRECT';
    }
  }

  return 'DIRECT';
}

_ProxyAddress? _proxyFromEnvironment() {
  final String? raw = _environmentValue(<String>[
    'JAVBUS_PROXY',
    'HTTPS_PROXY',
    'HTTP_PROXY',
    'ALL_PROXY',
  ]);
  if (raw == null || raw.trim().isEmpty) {
    return null;
  }

  final String value = raw.trim();
  final Uri? uri = Uri.tryParse(
    value.contains('://') ? value : 'http://$value',
  );
  if (uri == null || uri.host.isEmpty || uri.port == 0) {
    return null;
  }
  if (uri.scheme.toLowerCase().startsWith('socks')) {
    return null;
  }
  return _ProxyAddress(uri.host, uri.port);
}

String? _environmentValue(List<String> keys) {
  for (final String key in keys) {
    final String? exact = Platform.environment[key];
    if (exact != null) {
      return exact;
    }
  }

  final Set<String> lowerKeys = keys
      .map((String key) => key.toLowerCase())
      .toSet();
  for (final MapEntry<String, String> entry in Platform.environment.entries) {
    if (lowerKeys.contains(entry.key.toLowerCase())) {
      return entry.value;
    }
  }
  return null;
}

bool _isPortOpen(String host, int port) {
  try {
    final RawSynchronousSocket socket = RawSynchronousSocket.connectSync(
      host,
      port,
    );
    socket.closeSync();
    return true;
  } on Object {
    return false;
  }
}

class _ProxyAddress {
  const _ProxyAddress(this.host, this.port);

  final String host;
  final int port;
}

class PluginException implements Exception {
  const PluginException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PluginHumanVerificationException extends PluginException {
  const PluginHumanVerificationException(
    super.message, {
    required this.verificationUrl,
  });

  final Uri verificationUrl;
}

JsonSourcePlugin parsePluginJson(String raw) {
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const PluginException('插件 JSON 顶层必须是对象');
  }
  final JsonSourcePlugin plugin = JsonSourcePlugin.fromJson(decoded);
  if (plugin.id.trim().isEmpty) {
    throw const PluginException('插件缺少 id');
  }
  if (plugin.name.trim().isEmpty) {
    throw const PluginException('插件缺少 name');
  }

  // baseUrl is optional when announcement is enabled
  final bool hasAnnouncement =
      plugin.announcement != null && plugin.announcement!.enabled;
  if (hasAnnouncement) {
    final PluginAnnouncement announcement = plugin.announcement!;
    if (announcement.steps.isEmpty) {
      if (announcement.url.trim().isEmpty) {
        throw const PluginException('插件 announcement.url 不能为空');
      }
      final Uri? announcementUrl = Uri.tryParse(announcement.url);
      if (announcementUrl == null ||
          !announcementUrl.hasScheme ||
          announcementUrl.host.isEmpty) {
        throw const PluginException('插件 announcement.url 必须是完整 URL');
      }
      if (announcement.urlPattern.trim().isEmpty) {
        throw const PluginException('插件 announcement.urlPattern 不能为空');
      }
    } else {
      for (int index = 0; index < announcement.steps.length; index++) {
        final PluginAnnouncementStep step = announcement.steps[index];
        if (index == 0) {
          if (step.url.trim().isEmpty) {
            throw const PluginException('插件 announcement.steps[0].url 不能为空');
          }
          final Uri? stepUrl = Uri.tryParse(step.url);
          if (stepUrl == null || !stepUrl.hasScheme || stepUrl.host.isEmpty) {
            throw PluginException(
              '插件 announcement.steps[$index].url 必须是完整 URL',
            );
          }
        }
        if (step.urlPattern.trim().isEmpty) {
          throw PluginException(
            '插件 announcement.steps[$index].urlPattern 不能为空',
          );
        }
      }
    }
  }
  if (!hasAnnouncement) {
    if (!plugin.baseUrl.hasScheme || plugin.baseUrl.host.isEmpty) {
      throw const PluginException('插件 baseUrl 必须是完整 URL');
    }
  }

  return plugin;
}

File _pluginFile(Directory directory, String pluginId) {
  return File(
    '${directory.path}${Platform.pathSeparator}${_safePluginFileName(pluginId)}.json',
  );
}

String _safePluginFileName(String value) {
  final String safe = value
      .trim()
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (safe.isNotEmpty) {
    return safe;
  }
  return DateTime.now().microsecondsSinceEpoch.toString();
}

String _prettyPluginJson(String raw) {
  final Object? decoded = jsonDecode(raw);
  return const JsonEncoder.withIndent('  ').convert(decoded);
}

String _normalizeCookie(String cookie) {
  var value = cookie.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  return value.trim();
}

bool _looksLikeHumanVerification(http.Response response) {
  final String body = response.body.toLowerCase();
  final bool hasChallengeMarker =
      body.contains('cf-chl') ||
      body.contains('challenge-platform') ||
      body.contains('cf-mitigated') ||
      body.contains('cf-turnstile') ||
      body.contains('turnstile') ||
      body.contains('enable javascript and cookies') ||
      body.contains('just a moment') ||
      body.contains('checking if the site connection is secure') ||
      (body.contains('cloudflare') && body.contains('challenge'));
  if (hasChallengeMarker) {
    return true;
  }
  return (response.statusCode == 403 || response.statusCode == 503) &&
      body.contains('cloudflare');
}

String _applyTemplate(String template, Map<String, String> variables) {
  var result = template;
  for (final MapEntry<String, String> entry in variables.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}

Map<String, String> _encodedVariables(Map<String, String> variables) {
  return variables.map(
    (String key, String value) =>
        MapEntry<String, String>('${key}Encoded', Uri.encodeComponent(value)),
  );
}

String _base64NoPadding(String value) {
  return base64Url.encode(utf8.encode(value)).replaceAll(RegExp(r'=+$'), '');
}

List<Map<String, Object?>> _matchesAsMaps(
  String input,
  String pattern,
  Iterable<String> targetPaths,
) {
  final RegExp regex = RegExp(
    pattern,
    caseSensitive: false,
    dotAll: true,
    multiLine: true,
  );
  final bool usesNamedGroups = pattern.contains('?<');
  return regex
      .allMatches(input)
      .map((RegExpMatch match) {
        final Map<String, Object?> item = <String, Object?>{};
        var index = 1;
        for (final String targetPath in targetPaths) {
          if (targetPath.isEmpty) {
            continue;
          }
          final String? named = _namedGroup(
            match,
            _lastPathSegment(targetPath),
          );
          if (usesNamedGroups) {
            if (named != null) {
              _setValueAt(item, targetPath, _cleanHtml(named));
            }
            continue;
          }
          final String? indexed = index <= match.groupCount
              ? match.group(index)
              : null;
          _setValueAt(item, targetPath, _cleanHtml(named ?? indexed ?? ''));
          index++;
        }
        return item;
      })
      .toList(growable: false);
}

int _firstIntMatch(String input, String pattern, int fallback) {
  if (pattern.isEmpty) {
    return fallback;
  }
  final RegExpMatch? match = RegExp(
    pattern,
    caseSensitive: false,
    dotAll: true,
    multiLine: true,
  ).firstMatch(input);
  if (match == null) {
    return fallback;
  }
  return int.tryParse(match.group(1) ?? '') ?? fallback;
}

String? _namedGroup(RegExpMatch match, String name) {
  try {
    return match.namedGroup(name);
  } on ArgumentError {
    return null;
  }
}

String _lastPathSegment(String path) {
  if (!path.contains('.')) {
    return path;
  }
  return path.split('.').last;
}

void _setValueAt(Map<String, Object?> target, String path, Object? value) {
  final List<String> parts = path.split('.');
  Map<String, Object?> current = target;
  for (final String part in parts.take(parts.length - 1)) {
    final Object? child = current[part];
    if (child is Map<String, Object?>) {
      current = child;
    } else {
      final Map<String, Object?> next = <String, Object?>{};
      current[part] = next;
      current = next;
    }
  }
  current[parts.last] = value;
}

String _cleanHtml(String value) {
  return value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll('&#xA0;', ' ')
      .replaceAll('\u00A0', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Object? _valueAt(Object? root, String path) {
  if (path.isEmpty) {
    return root;
  }
  Object? current = root;
  for (final String part in path.split('.')) {
    if (current is Map<String, Object?>) {
      current = current[part];
    } else if (current is List<Object?>) {
      final int? index = int.tryParse(part);
      current = index == null || index < 0 || index >= current.length
          ? null
          : current[index];
    } else {
      return null;
    }
  }
  return current;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map<String, Object?>) {
    return const <String, String>{};
  }
  return value.map(
    (String key, Object? raw) => MapEntry<String, String>(key, raw.toString()),
  );
}

List<PluginAnnouncementStep> _announcementStepsFromJson(Object? value) {
  if (value is! List<Object?>) {
    return const <PluginAnnouncementStep>[];
  }
  return value
      .whereType<Map<String, Object?>>()
      .map(PluginAnnouncementStep.fromJson)
      .toList(growable: false);
}

String _stringValue(Object? value, [String fallback = '']) {
  if (value is String) {
    return value;
  }
  return fallback;
}

int _intValue(Object? value, [int fallback = 0]) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

double _doubleValue(Object? value, [double fallback = 0]) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? fallback;
  }
  return fallback;
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

DateTime? _dateValue(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

int _lastPageFromTotal(int total, int pageSize) {
  if (total <= 0 || pageSize <= 0) {
    return 1;
  }
  return (total / pageSize).ceil();
}

class PluginRuntimeState {
  PluginRuntimeState({
    this.resolvedBaseUrl,
    this.lastAnnouncementCheck,
    this.lastSuccessfulSearch,
    this.consecutiveFailures = 0,
  });

  String? resolvedBaseUrl;
  DateTime? lastAnnouncementCheck;
  DateTime? lastSuccessfulSearch;
  int consecutiveFailures;
}

class AnnouncementResolver {
  const AnnouncementResolver({http.Client? client}) : _client = client;

  final http.Client? _client;

  Future<String> resolveBaseUrl(PluginAnnouncement announcement) async {
    final http.Client httpClient = _client ?? http.Client();
    try {
      if (announcement.steps.isNotEmpty) {
        return await _resolveSteps(httpClient, announcement.steps);
      }
      return await _resolveStep(
        httpClient,
        PluginAnnouncementStep(
          url: announcement.url,
          urlPattern: announcement.urlPattern,
          urlDecoding: announcement.urlDecoding,
          targetPattern: announcement.targetPattern,
        ),
        previousUrl: '',
      );
    } on TimeoutException {
      throw PluginException('发布页访问超时：${announcement.url}');
    } on SocketException catch (error) {
      throw PluginException('发布页网络连接失败：${error.message}');
    } on http.ClientException catch (error) {
      throw PluginException('发布页 HTTP 请求失败：$error');
    } finally {
      if (_client == null) {
        httpClient.close();
      }
    }
  }

  Future<String> _resolveSteps(
    http.Client httpClient,
    List<PluginAnnouncementStep> steps,
  ) async {
    String previousUrl = '';
    for (int index = 0; index < steps.length; index++) {
      previousUrl = await _resolveStep(
        httpClient,
        steps[index],
        previousUrl: previousUrl,
      );
    }
    if (previousUrl.isEmpty) {
      throw const PluginException('发布页未找到有效地址');
    }
    return previousUrl;
  }

  Future<String> _resolveStep(
    http.Client httpClient,
    PluginAnnouncementStep step, {
    required String previousUrl,
  }) async {
    if (step.url.trim().isEmpty && previousUrl.isEmpty) {
      throw const PluginException('发布页 step.url 不能为空');
    }
    final String urlTemplate = step.url.trim().isEmpty ? '{value}' : step.url;
    final String requestUrl = _applyAnnouncementStepTemplate(
      urlTemplate,
      previousUrl,
    );
    final Uri? uri = Uri.tryParse(requestUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw PluginException('发布页 step.url 必须解析为完整 URL：$requestUrl');
    }

    final http.Response response = await httpClient
        .get(uri)
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PluginException('发布页访问失败：HTTP ${response.statusCode}');
    }

    final List<String> candidates = extractUrls(
      response.body,
      step.urlPattern,
      step.urlDecoding,
      step.targetPattern,
    );
    if (candidates.isEmpty) {
      throw const PluginException('发布页未找到有效地址');
    }
    return candidates.first;
  }

  List<String> extractUrls(
    String html,
    String pattern,
    String decoding,
    String targetPattern,
  ) {
    if (pattern.isEmpty) {
      throw const PluginException('发布页 urlPattern 不能为空');
    }

    final RegExp regex = RegExp(
      pattern,
      caseSensitive: false,
      dotAll: true,
      multiLine: true,
    );

    final List<String> preferred = <String>[];
    final List<String> fallback = <String>[];
    final Set<String> seen = <String>{};
    for (final RegExpMatch match in regex.allMatches(html)) {
      if (match.groupCount < 1) {
        continue;
      }

      final String? encoded = match.group(1);
      if (encoded == null || encoded.trim().isEmpty) {
        continue;
      }

      String decoded;
      try {
        decoded = _decodeUrl(encoded.trim(), decoding);
      } on Object {
        continue;
      }

      final String? normalized = _normalizeUrl(decoded);
      if (normalized == null) {
        continue;
      }
      if (!seen.add(normalized)) {
        continue;
      }

      if (targetPattern.isNotEmpty) {
        final String context = _contextAround(html, match.start);
        if (context.contains(targetPattern)) {
          preferred.add(normalized);
        } else {
          fallback.add(normalized);
        }
      } else {
        fallback.add(normalized);
      }
    }

    return <String>[...preferred, ...fallback];
  }

  String _decodeUrl(String encoded, String decoding) {
    switch (decoding.toLowerCase()) {
      case 'base64':
        return utf8.decode(base64.decode(_padBase64(encoded)));
      case 'base64url':
        return utf8.decode(base64Url.decode(_padBase64(encoded)));
      case 'hex':
        final List<int> bytes = <int>[];
        for (int i = 0; i < encoded.length; i += 2) {
          if (i + 1 < encoded.length) {
            bytes.add(int.parse(encoded.substring(i, i + 2), radix: 16));
          }
        }
        return utf8.decode(bytes);
      case 'none':
      default:
        return encoded;
    }
  }

  String _applyAnnouncementStepTemplate(String template, String previousUrl) {
    if (previousUrl.isEmpty) {
      return template;
    }
    final Uri? uri = Uri.tryParse(previousUrl);
    final String origin = uri == null || !uri.hasScheme || uri.host.isEmpty
        ? previousUrl
        : '${uri.scheme}://${uri.authority}';
    return template
        .replaceAll('{value}', previousUrl)
        .replaceAll('{url}', previousUrl)
        .replaceAll('{origin}', origin)
        .replaceAll('{host}', uri?.host ?? previousUrl);
  }

  String? _normalizeUrl(String url) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    Uri? uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return uri.toString();
    }
    if (!RegExp(r'^[a-zA-Z0-9.-]+(?::\d+)?(?:/.*)?$').hasMatch(trimmed) ||
        !trimmed.contains('.')) {
      return null;
    }
    uri = Uri.tryParse('https://$trimmed');
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri.toString();
  }

  String _contextAround(String html, int position) {
    final int start = (position - 500).clamp(0, html.length).toInt();
    final int end = (position + 500).clamp(0, html.length).toInt();
    return html.substring(start, end);
  }
}

String _padBase64(String value) {
  final int remainder = value.length % 4;
  return remainder == 0
      ? value
      : value.padRight(value.length + 4 - remainder, '=');
}
