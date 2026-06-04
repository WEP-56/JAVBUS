import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../lan/lan_transfer_service.dart';
import '../magnets/magnet_library.dart';
import '../plugins/json_source_plugin.dart';
import '../plugins/magnet_item.dart';
import '../platform/android_storage_access.dart';
import '../platform/android_foreground_service.dart';
import '../settings/app_settings.dart';
import 'human_verification_dialog.dart';
import 'lan_transfer_page.dart';
import 'magnet_library_page.dart';
import 'pan_search_page.dart';

enum _WorkbenchSection {
  search('资源搜索', '磁力', Icons.search_rounded),
  pan('搜盘', '搜盘', Icons.cloud_rounded),
  library('收藏管理', '收藏', Icons.bookmarks_rounded),
  lan('局域网互传', '互传', Icons.sync_alt_rounded),
  settings('设置中心', '设置', Icons.tune_rounded);

  const _WorkbenchSection(this.label, this.dockLabel, this.icon);

  final String label;
  final String dockLabel;
  final IconData icon;
}

const List<_WorkbenchSection> _dockSections = <_WorkbenchSection>[
  _WorkbenchSection.search,
  _WorkbenchSection.pan,
  _WorkbenchSection.library,
  _WorkbenchSection.lan,
];

class PluginSearchPage extends StatefulWidget {
  const PluginSearchPage({super.key});

  @override
  State<PluginSearchPage> createState() => _PluginSearchPageState();
}

class _PluginSearchPageState extends State<PluginSearchPage> {
  final JsonPluginRegistry _registry = JsonPluginRegistry();
  final MagnetLibrary _magnetLibrary = MagnetLibrary();
  final LanTransferService _lanTransferService = LanTransferService();
  final AppSettingsStore _settingsStore = AppSettingsStore();
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _pluginFilterController = TextEditingController();
  final Map<String, VerifiedWebViewSession> _verifiedSessions =
      <String, VerifiedWebViewSession>{};
  final Set<String> _verifiedHosts = <String>{};

  _WorkbenchSection _active = _WorkbenchSection.search;
  List<JsonSourcePlugin> _plugins = const <JsonSourcePlugin>[];
  JsonSourcePlugin? _selectedPlugin;
  List<MagnetItem> _items = const <MagnetItem>[];
  final Set<String> _loadingDetails = <String>{};
  AppSettings _settings = AppSettings.empty;
  bool _loadingPlugins = true;
  bool _loadingSettings = true;
  bool _searching = false;
  bool _showPluginSettings = false;
  String? _message;
  String _pluginFilter = '';
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _lanTransferService.addListener(_syncAndroidForegroundStatus);
    }
    _loadSettings();
    _loadPlugins();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _pluginFilterController.dispose();
    for (final VerifiedWebViewSession session in _verifiedSessions.values) {
      unawaited(session.dispose());
    }
    if (Platform.isAndroid) {
      _lanTransferService.removeListener(_syncAndroidForegroundStatus);
    }
    unawaited(_stopLanTransferService());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = _effectiveBrightness(context);

    return Theme(
      data: buildAppTheme(brightness, accentColor: _settings.accentColor),
      child: Builder(
        builder: (BuildContext context) {
          final bool compact = MediaQuery.sizeOf(context).width < 760;
          final double horizontalPadding = compact ? 16 : 26;
          final bool customTitleBar = Platform.isWindows;

          return Scaffold(
            backgroundColor: AppTheme.bg(context),
            body: Column(
              children: <Widget>[
                if (customTitleBar) const _WindowsTitleBar(),
                Expanded(
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: ColoredBox(color: AppTheme.bg(context)),
                      ),
                      SafeArea(
                        top: !customTitleBar,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            compact ? 16 : 24,
                            horizontalPadding,
                            compact ? 96 : 108,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: _maxContentWidth(_active),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Expanded(child: _buildWorkspaceContent()),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: compact ? 14 : 24,
                        child: SafeArea(
                          top: false,
                          child: _FloatingDock(
                            active: _active,
                            compact: compact,
                            dark: AppTheme.isDark(context),
                            onChanged: (_WorkbenchSection section) {
                              setState(() {
                                _active = section;
                                if (section != _WorkbenchSection.settings) {
                                  _showPluginSettings = false;
                                }
                              });
                            },
                            onOpenSettings: () {
                              setState(() {
                                _active = _WorkbenchSection.settings;
                                _showPluginSettings = false;
                              });
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildWorkspaceContent() {
    final bool showingSettings = _active == _WorkbenchSection.settings;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Offstage(
            offstage: showingSettings,
            child: TickerMode(
              enabled: !showingSettings,
              child: IndexedStack(
                index: _primarySectionIndex,
                children: <Widget>[
                  _buildSearchSection(),
                  const PanSearchSection(),
                  const MagnetLibraryPage(),
                  LanTransferPage(
                    service: _lanTransferService,
                    onStartService: _startLanTransferService,
                    onStopService: _stopLanTransferService,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showingSettings)
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: KeyedSubtree(
                key: ValueKey<bool>(_showPluginSettings),
                child: _buildSettingsSection(),
              ),
            ),
          ),
      ],
    );
  }

  int get _primarySectionIndex {
    return switch (_active) {
      _WorkbenchSection.search || _WorkbenchSection.settings => 0,
      _WorkbenchSection.pan => 1,
      _WorkbenchSection.library => 2,
      _WorkbenchSection.lan => 3,
    };
  }

  Widget _buildSettingsSection() {
    if (_showPluginSettings) {
      return _PluginsSection(
        plugins: _filteredPlugins,
        selectedPlugin: _selectedPlugin,
        loading: _loadingPlugins,
        filterController: _pluginFilterController,
        onFilterChanged: (String value) {
          setState(() => _pluginFilter = value);
        },
        onSelect: _selectPlugin,
        onInstall: _installPlugin,
        onCreate: _createPlugin,
        onEdit: _editPlugin,
        onDelete: _deletePlugin,
        onReload: _loadPlugins,
        onBack: () => setState(() => _showPluginSettings = false),
      );
    }
    return _SettingsSection(
      pluginCount: _plugins.length,
      settings: _settings,
      loading: _loadingSettings,
      onSettingsChanged: _saveSettings,
      onOpenPlugins: () => setState(() => _showPluginSettings = true),
    );
  }

  Brightness _effectiveBrightness(BuildContext context) {
    return switch (_settings.themeMode) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => MediaQuery.platformBrightnessOf(context),
    };
  }

  Widget _buildSearchSection() {
    final bool loadingResults = _searching && _items.isEmpty;

    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _SearchCommandBox(
            controller: _queryController,
            plugins: _enabledPlugins,
            selectedPlugin: _selectedPlugin,
            loading: _loadingPlugins || _searching,
            onPluginChanged: _selectPlugin,
            onSearch: _searchFirstPage,
          ),
        ),
        if (_message != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _InfoStrip(message: _message!),
            ),
          ),
        if (_loadingPlugins)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 12),
              child: _LoadingStrip(message: '正在加载 JSON 插件源...'),
            ),
          )
        else if (loadingResults)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 12),
              child: _LoadingStrip(message: '正在搜索资源...'),
            ),
          )
        else if (_items.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 46),
              child: _SearchEmptyState(),
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
              child: _SectionLead(
                title: '搜索结果',
                subtitle: '来自 ${_selectedPlugin?.name ?? '当前插件源'}',
                trailing: '$_total 条',
              ),
            ),
          ),
          SliverList.separated(
            itemBuilder: (BuildContext context, int index) {
              final MagnetItem item = _items[index];
              return _MagnetCard(
                item: item,
                detailLoading: _loadingDetails.contains(item.stableKey),
                onCopy: () => _copyMagnet(item),
                onSave: () => _saveMagnet(item),
                onDetails: () => _loadDetails(item),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemCount: _items.length,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 10),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _searching || _page >= _lastPage
                      ? null
                      : _loadMore,
                  icon: _searching
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more_rounded),
                  label: Text(
                    _page >= _lastPage ? '没有更多结果' : '加载更多 $_page/$_lastPage',
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  List<JsonSourcePlugin> get _filteredPlugins {
    final String query = _pluginFilter.trim().toLowerCase();
    if (query.isEmpty) {
      return _plugins;
    }
    return _plugins
        .where((JsonSourcePlugin plugin) {
          return plugin.name.toLowerCase().contains(query) ||
              plugin.id.toLowerCase().contains(query) ||
              plugin.baseUrl.toString().toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  List<JsonSourcePlugin> get _enabledPlugins {
    return _plugins
        .where((JsonSourcePlugin plugin) => plugin.enabled)
        .toList(growable: false);
  }

  double _maxContentWidth(_WorkbenchSection section) {
    switch (section) {
      case _WorkbenchSection.search:
        return 1060;
      case _WorkbenchSection.library:
        return 980;
      case _WorkbenchSection.pan:
        return 1060;
      case _WorkbenchSection.lan:
        return 1120;
      case _WorkbenchSection.settings:
        return _showPluginSettings ? 920 : 840;
    }
  }

  Future<void> _loadPlugins() async {
    if (mounted) {
      setState(() => _loadingPlugins = true);
    }
    try {
      final List<JsonSourcePlugin> plugins = await _registry
          .loadInstalledPlugins();
      if (!mounted) {
        return;
      }
      setState(() {
        _plugins = plugins;
        final List<JsonSourcePlugin> enabledPlugins = plugins
            .where((JsonSourcePlugin plugin) => plugin.enabled)
            .toList(growable: false);
        _selectedPlugin = enabledPlugins.isEmpty
            ? null
            : enabledPlugins.firstWhere(
                (JsonSourcePlugin plugin) => plugin.id == _selectedPlugin?.id,
                orElse: () => enabledPlugins.first,
              );
        _message = '已加载 ${plugins.length} 个 JSON 插件源。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingPlugins = false);
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final AppSettings settings = await _settingsStore.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = settings;
        _loadingSettings = false;
      });
      if (settings.lanAutoStart) {
        unawaited(_startLanTransferService());
      } else if (Platform.isAndroid) {
        unawaited(stopAndroidForegroundService());
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _loadingSettings = false);
      _showSnack(error.toString());
    }
  }

  Future<void> _saveSettings(AppSettings settings) async {
    await _settingsStore.save(settings);
    if (mounted) {
      setState(() => _settings = settings);
    }
  }

  Future<void> _startLanTransferService() async {
    if (Platform.isAndroid) {
      await startAndroidForegroundService();
    }
    await _lanTransferService.start();
    _syncAndroidForegroundStatus();
  }

  Future<void> _stopLanTransferService() async {
    if (!_lanTransferService.running && !_lanTransferService.starting) {
      return;
    }
    await _lanTransferService.stop();
    if (Platform.isAndroid) {
      await stopAndroidForegroundService();
    }
  }

  void _syncAndroidForegroundStatus() {
    if (!Platform.isAndroid) {
      return;
    }
    unawaited(
      updateAndroidForegroundStatus(
        running: _lanTransferService.running,
        peerCount: _lanTransferService.peers.length,
        error: _lanTransferService.error,
      ),
    );
  }

  void _selectPlugin(JsonSourcePlugin plugin) {
    setState(() {
      _selectedPlugin = plugin;
      _active = _WorkbenchSection.search;
      _showPluginSettings = false;
    });
  }

  Future<void> _searchFirstPage() async {
    final JsonSourcePlugin? plugin = _selectedPlugin;
    final String query = _queryController.text.trim();
    if (plugin == null) {
      _showSnack('没有可用插件源');
      return;
    }
    if (query.isEmpty) {
      _showSnack('请输入番号、标题或关键词');
      return;
    }

    setState(() {
      _searching = true;
      _message = null;
      _items = const <MagnetItem>[];
      _lastQuery = query;
      _page = 1;
      _lastPage = 1;
      _total = 0;
    });

    try {
      final PluginSearchResult? webViewResult =
          await _searchWithVerifiedWebView(plugin, query: query, page: 1);
      if (webViewResult != null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _items = webViewResult.items;
          _page = webViewResult.currentPage;
          _lastPage = webViewResult.lastPage;
          _total = webViewResult.total;
          _message = '${plugin.name} 返回 ${webViewResult.total} 条结果。';
        });
        return;
      }

      final PluginSearchResult result = await _registry.search(
        plugin,
        query: query,
        page: 1,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _items = result.items;
        _page = result.currentPage;
        _lastPage = result.lastPage;
        _total = result.total;
        _message = '${plugin.name} 返回 ${result.total} 条结果。';
      });
    } on PluginHumanVerificationException catch (error) {
      if (mounted) {
        final HumanVerificationResult? verification =
            await _handleHumanVerification(plugin, error);
        if (verification != null &&
            verification.hasHtml &&
            plugin.search.isHtml) {
          final PluginSearchResult result = plugin.parseSearchHtml(
            verification.html,
            page: 1,
          );
          if (result.items.isNotEmpty) {
            setState(() {
              _items = result.items;
              _page = result.currentPage;
              _lastPage = result.lastPage;
              _total = result.total;
              _message = '${plugin.name} 返回 ${result.total} 条结果。';
            });
            return;
          }
        }
        if (verification != null && verification.hasCookie) {
          await _searchFirstPage();
          return;
        }
        setState(() => _message = '需要完成人机验证后才能搜索 ${plugin.name}。');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _loadMore() async {
    final JsonSourcePlugin? plugin = _selectedPlugin;
    if (plugin == null || _lastQuery.isEmpty || _page >= _lastPage) {
      return;
    }
    setState(() => _searching = true);
    try {
      final PluginSearchResult? webViewResult =
          await _searchWithVerifiedWebView(
            plugin,
            query: _lastQuery,
            page: _page + 1,
          );
      if (webViewResult != null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _items = <MagnetItem>[..._items, ...webViewResult.items];
          _page = webViewResult.currentPage;
          _lastPage = webViewResult.lastPage;
          _total = webViewResult.total;
        });
        return;
      }

      final PluginSearchResult result = await _registry.search(
        plugin,
        query: _lastQuery,
        page: _page + 1,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _items = <MagnetItem>[..._items, ...result.items];
        _page = result.currentPage;
        _lastPage = result.lastPage;
        _total = result.total;
      });
    } on PluginHumanVerificationException catch (error) {
      if (mounted) {
        final HumanVerificationResult? verification =
            await _handleHumanVerification(plugin, error);
        if (verification != null &&
            verification.hasHtml &&
            plugin.search.isHtml) {
          final PluginSearchResult result = plugin.parseSearchHtml(
            verification.html,
            page: _page + 1,
          );
          if (result.items.isNotEmpty) {
            setState(() {
              _items = <MagnetItem>[..._items, ...result.items];
              _page = result.currentPage;
              _lastPage = result.lastPage;
              _total = result.total;
            });
            return;
          }
        }
        if (verification != null && verification.hasCookie) {
          await _loadMore();
          return;
        }
        _showSnack('需要完成人机验证后才能继续加载');
      }
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _loadDetails(MagnetItem item) async {
    final JsonSourcePlugin? plugin = _selectedPlugin;
    final String key = item.stableKey;
    if (plugin == null || _loadingDetails.contains(key)) {
      return;
    }
    setState(() => _loadingDetails.add(key));
    try {
      final MagnetItem? webViewItem = await _detailsWithVerifiedWebView(
        plugin,
        item,
      );
      if (webViewItem != null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _items = _items
              .map(
                (MagnetItem candidate) =>
                    candidate.stableKey == key ? webViewItem : candidate,
              )
              .toList(growable: false);
        });
        return;
      }

      final MagnetItem detailed = await _registry.details(plugin, item);
      if (!mounted) {
        return;
      }
      setState(() {
        _items = _items
            .map(
              (MagnetItem candidate) =>
                  candidate.stableKey == key ? detailed : candidate,
            )
            .toList(growable: false);
      });
    } on PluginHumanVerificationException catch (error) {
      if (mounted) {
        final HumanVerificationResult? verification =
            await _handleHumanVerification(plugin, error);
        if (verification != null &&
            verification.hasHtml &&
            (plugin.detail?.isHtml ?? false)) {
          final MagnetItem detailed = plugin.parseDetailHtml(
            item,
            verification.html,
          );
          setState(() {
            _items = _items
                .map(
                  (MagnetItem candidate) =>
                      candidate.stableKey == key ? detailed : candidate,
                )
                .toList(growable: false);
          });
          return;
        }
        if (verification != null && verification.hasCookie) {
          setState(() => _loadingDetails.remove(key));
          await _loadDetails(item);
          return;
        }
        _showSnack('需要完成人机验证后才能加载详情');
      }
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loadingDetails.remove(key));
      }
    }
  }

  Future<void> _copyMagnet(MagnetItem item) async {
    await Clipboard.setData(ClipboardData(text: item.magnet));
    if (mounted) {
      _showSnack('已复制 magnet 链接');
    }
  }

  Future<void> _saveMagnet(MagnetItem item) async {
    try {
      MagnetItem target = item;
      if (target.magnet.isEmpty) {
        final MagnetItem? detailed = await _loadDetailsForSave(item);
        if (detailed != null) {
          target = detailed;
        }
      }
      if (target.magnet.isEmpty) {
        _showSnack('当前结果没有 magnet 链接');
        return;
      }
      final String stableId = target.infoHash.isNotEmpty
          ? 'magnet_${target.infoHash.toUpperCase()}'
          : 'magnet_${_stableFavoriteId(target.magnet)}';
      await _magnetLibrary.upsert(
        newStoredMagnet(
          id: stableId,
          title: target.title.isEmpty ? target.infoHash : target.title,
          magnet: target.magnet,
          tags: <String>[target.pluginName],
          note: target.largestFile,
          source: target.webUrl,
        ),
      );
      if (mounted) {
        _showSnack('已保存到收藏');
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnack('收藏失败：$error');
      }
    }
  }

  Future<MagnetItem?> _loadDetailsForSave(MagnetItem item) async {
    final JsonSourcePlugin? plugin = _selectedPlugin;
    if (plugin == null || plugin.detail == null) {
      return null;
    }
    final String key = item.stableKey;
    if (mounted) {
      setState(() => _loadingDetails.add(key));
    }
    try {
      final MagnetItem? webViewDetailed = await _detailsWithVerifiedWebView(
        plugin,
        item,
      );
      final MagnetItem detailed =
          webViewDetailed ?? await _registry.details(plugin, item);
      if (mounted) {
        setState(() {
          _items = _items
              .map(
                (MagnetItem candidate) =>
                    candidate.stableKey == key ? detailed : candidate,
              )
              .toList(growable: false);
        });
      }
      return detailed;
    } on PluginHumanVerificationException catch (error) {
      if (!mounted) {
        return null;
      }
      final HumanVerificationResult? verification =
          await _handleHumanVerification(plugin, error);
      if (verification != null &&
          verification.hasHtml &&
          plugin.detail!.isHtml) {
        final MagnetItem parsed = plugin.parseDetailHtml(
          item,
          verification.html,
        );
        if (mounted) {
          setState(() {
            _items = _items
                .map(
                  (MagnetItem candidate) =>
                      candidate.stableKey == key ? parsed : candidate,
                )
                .toList(growable: false);
          });
        }
        return parsed;
      }
      if (verification != null && verification.hasCookie) {
        return _loadDetailsForSave(item);
      }
      return null;
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _loadingDetails.remove(key));
      }
    }
  }

  Future<PluginSearchResult?> _searchWithVerifiedWebView(
    JsonSourcePlugin plugin, {
    required String query,
    required int page,
  }) async {
    if (!_shouldUseVerifiedWebView(plugin) || !plugin.search.isHtml) {
      return null;
    }
    final HumanVerificationResult result = await _verifiedSessionFor(
      plugin,
    ).load(plugin.resolveSearchUrl(query: query, page: page));
    if (!result.hasHtml || _looksLikeChallengeHtml(result.html)) {
      _verifiedHosts.remove(plugin.baseUrl.host);
      return null;
    }
    final PluginSearchResult parsed = plugin.parseSearchHtml(
      result.html,
      page: page,
    );
    return parsed.items.isEmpty ? null : parsed;
  }

  Future<MagnetItem?> _detailsWithVerifiedWebView(
    JsonSourcePlugin plugin,
    MagnetItem item,
  ) async {
    if (!_shouldUseVerifiedWebView(plugin) ||
        !(plugin.detail?.isHtml ?? false)) {
      return null;
    }
    final Uri? url = plugin.resolveDetailUrl(item);
    if (url == null) {
      return null;
    }
    final HumanVerificationResult result = await _verifiedSessionFor(
      plugin,
    ).load(url);
    if (!result.hasHtml || _looksLikeChallengeHtml(result.html)) {
      _verifiedHosts.remove(plugin.baseUrl.host);
      return null;
    }
    final MagnetItem parsed = plugin.parseDetailHtml(item, result.html);
    final bool changed =
        parsed.infoHash.isNotEmpty ||
        parsed.magnet.isNotEmpty ||
        parsed.files.isNotEmpty;
    return changed ? parsed : null;
  }

  bool _shouldUseVerifiedWebView(JsonSourcePlugin plugin) {
    return plugin.capabilities.requiresHumanVerification &&
        _verifiedHosts.contains(plugin.baseUrl.host);
  }

  VerifiedWebViewSession _verifiedSessionFor(JsonSourcePlugin plugin) {
    return _verifiedSessions.putIfAbsent(
      plugin.baseUrl.host,
      VerifiedWebViewSession.new,
    );
  }

  bool _looksLikeChallengeHtml(String html) {
    final String body = html.toLowerCase();
    return body.contains('cf-chl') ||
        body.contains('challenge-platform') ||
        body.contains('enable javascript and cookies') ||
        body.contains('just a moment') ||
        body.contains('cloudflare');
  }

  Future<HumanVerificationResult?> _handleHumanVerification(
    JsonSourcePlugin plugin,
    PluginHumanVerificationException error,
  ) async {
    final HumanVerificationResult? result = await showHumanVerificationDialog(
      context: context,
      url: error.verificationUrl,
      pluginName: plugin.name,
    );
    if (result == null || (!result.hasCookie && !result.hasHtml)) {
      return null;
    }
    if (result.hasCookie) {
      _registry.setVerificationCookie(plugin, result.cookie);
    }
    _verifiedHosts.add(plugin.baseUrl.host);
    if (mounted) {
      final String suffix = result.hasCookie ? 'Cookie 已保存' : '已读取页面内容';
      _showSnack('${plugin.name} 验证完成，$suffix');
    }
    return result;
  }

  Future<void> _installPlugin() async {
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('安装插件'),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('paste'),
              child: const ListTile(
                leading: Icon(Icons.content_paste_rounded),
                title: Text('粘贴 JSON'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('file'),
              child: const ListTile(
                leading: Icon(Icons.upload_file_rounded),
                title: Text('选择 JSON 文件'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('url'),
              child: const ListTile(
                leading: Icon(Icons.link_rounded),
                title: Text('从 URL 安装'),
              ),
            ),
          ],
        );
      },
    );
    switch (action) {
      case 'paste':
        await _openPluginEditor(title: '安装 JSON 插件');
      case 'file':
        await _installPluginFromFile();
      case 'url':
        await _installPluginFromUrl();
      case null:
        return;
    }
  }

  Future<void> _createPlugin() async {
    await _openPluginEditor(title: '新建插件', initialJson: _defaultPluginJson());
  }

  Future<void> _editPlugin(JsonSourcePlugin plugin) async {
    final String raw = await _registry.readPluginJson(plugin.id);
    await _openPluginEditor(
      title: '编辑插件',
      initialJson: raw.isEmpty ? _pluginToJson(plugin) : raw,
      replacingId: plugin.id,
    );
  }

  Future<void> _installPluginFromFile() async {
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final PlatformFile picked = result.files.single;
      final String raw = picked.bytes != null
          ? utf8.decode(picked.bytes!)
          : await File(
              picked.path ?? (throw const PluginException('没有读取到插件文件路径')),
            ).readAsString();
      await _savePluginRaw(raw);
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
    }
  }

  Future<void> _installPluginFromUrl() async {
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _PluginUrlDialog(),
    );
    if (url == null || url.trim().isEmpty) {
      return;
    }
    try {
      final Uri? uri = Uri.tryParse(url.trim());
      if (uri == null ||
          !uri.hasScheme ||
          uri.host.isEmpty ||
          !uri.path.toLowerCase().endsWith('.json')) {
        throw const PluginException('请输入以 .json 结尾的插件 URL');
      }
      final http.Response response = await http
          .get(uri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw PluginException('插件下载失败：HTTP ${response.statusCode}');
      }
      await _savePluginRaw(response.body);
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
    }
  }

  Future<void> _savePluginRaw(String raw, {String? replacingId}) async {
    final JsonSourcePlugin plugin = await _registry.savePluginJson(
      raw,
      replacingId: replacingId,
    );
    await _loadPlugins();
    if (mounted) {
      setState(() => _selectedPlugin = plugin.enabled ? plugin : null);
      _showSnack('已保存插件：${plugin.name}');
    }
  }

  Future<void> _openPluginEditor({
    required String title,
    String? initialJson,
    String? replacingId,
  }) async {
    final String? raw = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return _PluginEditorDialog(title: title, initialJson: initialJson);
      },
    );
    if (raw == null) {
      return;
    }
    try {
      await _savePluginRaw(raw, replacingId: replacingId);
    } catch (error) {
      if (mounted) {
        _showSnack(error.toString());
      }
    }
  }

  Future<void> _deletePlugin(JsonSourcePlugin plugin) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('删除插件'),
              content: Text('确定删除「${plugin.name}」吗？'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    await _registry.deletePlugin(plugin.id);
    if (_selectedPlugin?.id == plugin.id) {
      _selectedPlugin = null;
    }
    await _loadPlugins();
    if (mounted) {
      _showSnack('已删除插件：${plugin.name}');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(appSnack(message));
  }
}

class _SearchCommandBox extends StatelessWidget {
  const _SearchCommandBox({
    required this.controller,
    required this.plugins,
    required this.selectedPlugin,
    required this.loading,
    required this.onPluginChanged,
    required this.onSearch,
  });

  final TextEditingController controller;
  final List<JsonSourcePlugin> plugins;
  final JsonSourcePlugin? selectedPlugin;
  final bool loading;
  final ValueChanged<JsonSourcePlugin> onPluginChanged;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < 650;
          final Widget query = _CommandInput(
            controller: controller,
            loading: loading,
            onSearch: onSearch,
          );
          final Widget picker = _PluginPicker(
            plugins: plugins,
            selectedPlugin: selectedPlugin,
            loading: loading,
            onPluginChanged: onPluginChanged,
          );
          final Widget button = SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: loading ? null : onSearch,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(loading ? '处理中' : '搜索'),
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                query,
                const SizedBox(height: 10),
                picker,
                const SizedBox(height: 10),
                button,
              ],
            );
          }

          return Row(
            children: <Widget>[
              Expanded(child: query),
              const SizedBox(width: 10),
              SizedBox(width: 190, child: picker),
              const SizedBox(width: 10),
              button,
            ],
          );
        },
      ),
    );
  }
}

class _CommandInput extends StatelessWidget {
  const _CommandInput({
    required this.controller,
    required this.loading,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool loading;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 13),
          Icon(Icons.search_rounded, color: AppTheme.text3(context), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !loading,
              autofocus: true,
              decoration: InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: '输入番号、标题或关键词',
                hintStyle: TextStyle(color: AppTheme.text3(context)),
              ),
              style: TextStyle(
                color: AppTheme.text1(context),
                fontSize: 14,
                height: 1.2,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

class _PluginPicker extends StatelessWidget {
  const _PluginPicker({
    required this.plugins,
    required this.selectedPlugin,
    required this.loading,
    required this.onPluginChanged,
  });

  final List<JsonSourcePlugin> plugins;
  final JsonSourcePlugin? selectedPlugin;
  final bool loading;
  final ValueChanged<JsonSourcePlugin> onPluginChanged;

  @override
  Widget build(BuildContext context) {
    final String? value =
        plugins.any(
          (JsonSourcePlugin plugin) => plugin.id == selectedPlugin?.id,
        )
        ? selectedPlugin?.id
        : null;

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(
            '选择插件源',
            style: TextStyle(color: AppTheme.text3(context), fontSize: 13),
          ),
          borderRadius: BorderRadius.circular(10),
          dropdownColor: AppTheme.surface(context),
          icon: Icon(Icons.unfold_more_rounded, color: AppTheme.text3(context)),
          isExpanded: true,
          style: TextStyle(color: AppTheme.text1(context), fontSize: 13),
          items: plugins
              .map(
                (JsonSourcePlugin plugin) => DropdownMenuItem<String>(
                  value: plugin.id,
                  child: Text(plugin.name, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(growable: false),
          onChanged: loading
              ? null
              : (String? pluginId) {
                  if (pluginId == null) {
                    return;
                  }
                  for (final JsonSourcePlugin plugin in plugins) {
                    if (plugin.id == pluginId) {
                      onPluginChanged(plugin);
                      break;
                    }
                  }
                },
        ),
      ),
    );
  }
}

class _PluginsSection extends StatelessWidget {
  const _PluginsSection({
    required this.plugins,
    required this.selectedPlugin,
    required this.loading,
    required this.filterController,
    required this.onFilterChanged,
    required this.onSelect,
    required this.onInstall,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
    required this.onReload,
    required this.onBack,
  });

  final List<JsonSourcePlugin> plugins;
  final JsonSourcePlugin? selectedPlugin;
  final bool loading;
  final TextEditingController filterController;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<JsonSourcePlugin> onSelect;
  final VoidCallback onInstall;
  final VoidCallback onCreate;
  final ValueChanged<JsonSourcePlugin> onEdit;
  final ValueChanged<JsonSourcePlugin> onDelete;
  final VoidCallback onReload;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: '返回设置',
                child: IconButton.filledTonal(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  style: IconButton.styleFrom(
                    fixedSize: const Size(38, 38),
                    minimumSize: const Size(38, 38),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool compact = constraints.maxWidth < 640;
              final Widget filter = SizedBox(
                height: 42,
                child: TextField(
                  controller: filterController,
                  onChanged: onFilterChanged,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: '搜索已加载插件',
                  ),
                ),
              );
              final Widget install = SizedBox(
                height: 42,
                child: FilledButton.icon(
                  onPressed: loading ? null : onInstall,
                  icon: const Icon(Icons.file_upload_rounded, size: 18),
                  label: const Text('安装 JSON'),
                ),
              );
              final Widget create = SizedBox(
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: loading ? null : onCreate,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建'),
                ),
              );
              final Widget reload = SizedBox(
                height: 42,
                child: OutlinedButton.icon(
                  onPressed: loading ? null : onReload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新加载'),
                ),
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    filter,
                    const SizedBox(height: 10),
                    install,
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(child: create),
                        const SizedBox(width: 10),
                        Expanded(child: reload),
                      ],
                    ),
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  Expanded(child: filter),
                  const SizedBox(width: 10),
                  install,
                  const SizedBox(width: 10),
                  create,
                  const SizedBox(width: 10),
                  reload,
                ],
              );
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        if (loading)
          const SliverToBoxAdapter(child: _LoadingStrip(message: '正在加载插件源...'))
        else if (plugins.isEmpty)
          const SliverToBoxAdapter(child: _PluginEmptyState())
        else
          SliverList.separated(
            itemBuilder: (BuildContext context, int index) {
              final JsonSourcePlugin plugin = plugins[index];
              return _PluginCard(
                plugin: plugin,
                selected: selectedPlugin?.id == plugin.id,
                onTap: () => onSelect(plugin),
                onEdit: () => onEdit(plugin),
                onDelete: () => onDelete(plugin),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemCount: plugins.length,
          ),
      ],
    );
  }
}

class _PluginEditorDialog extends StatefulWidget {
  const _PluginEditorDialog({required this.title, required this.initialJson});

  final String title;
  final String? initialJson;

  @override
  State<_PluginEditorDialog> createState() => _PluginEditorDialogState();
}

class _PluginUrlDialog extends StatefulWidget {
  const _PluginUrlDialog();

  @override
  State<_PluginUrlDialog> createState() => _PluginUrlDialogState();
}

class _PluginUrlDialogState extends State<_PluginUrlDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从 URL 安装插件'),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '插件 JSON URL',
            hintText: 'https://example.com/plugin.json',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('安装')),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }
}

class _PluginEditorDialogState extends State<_PluginEditorDialog> {
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _searchUrlController = TextEditingController();
  final TextEditingController _responseTypeController = TextEditingController();
  final TextEditingController _itemPatternController = TextEditingController();
  final TextEditingController _totalPatternController = TextEditingController();
  final TextEditingController _lastPagePatternController =
      TextEditingController();
  final TextEditingController _fieldsController = TextEditingController();
  final TextEditingController _jsonController = TextEditingController();

  bool _enabled = true;
  bool _requiresHumanVerification = false;
  String _mode = 'form';

  @override
  void initState() {
    super.initState();
    _jsonController.text = widget.initialJson ?? '';
    if (_jsonController.text.trim().isNotEmpty) {
      _applyJsonToForm(showError: false);
    }
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _baseUrlController.dispose();
    _searchUrlController.dispose();
    _responseTypeController.dispose();
    _itemPatternController.dispose();
    _totalPatternController.dispose();
    _lastPagePatternController.dispose();
    _fieldsController.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 720,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'form',
                  label: Text('表单'),
                  icon: Icon(Icons.tune_rounded),
                ),
                ButtonSegment<String>(
                  value: 'json',
                  label: Text('JSON'),
                  icon: Icon(Icons.data_object_rounded),
                ),
              ],
              selected: <String>{_mode},
              onSelectionChanged: (Set<String> values) {
                setState(() => _mode = values.first);
              },
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _mode == 'form' ? _buildForm(context) : _buildJson(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _mode == 'json'
              ? () => _applyJsonToForm(showError: true)
              : null,
          child: const Text('JSON 填表'),
        ),
        TextButton(
          onPressed: _mode == 'form' ? _syncFormToJson : null,
          child: const Text('生成 JSON'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _idController,
                  decoration: const InputDecoration(labelText: '插件 ID'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(labelText: 'Base URL'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchUrlController,
            decoration: const InputDecoration(
              labelText: '搜索 URL 模板',
              hintText: '/search/{query}/{page}',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _responseTypeController,
                  decoration: const InputDecoration(
                    labelText: '响应类型',
                    hintText: 'html 或 json',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SwitchListTile.adaptive(
                  value: _enabled,
                  onChanged: (bool value) => setState(() => _enabled = value),
                  title: const Text('启用'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            value: _requiresHumanVerification,
            onChanged: (bool value) {
              setState(() => _requiresHumanVerification = value);
            },
            title: const Text('需要人机验证'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _itemPatternController,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'itemPattern'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _totalPatternController,
            decoration: const InputDecoration(labelText: 'totalPattern'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _lastPagePatternController,
            decoration: const InputDecoration(labelText: 'lastPagePattern'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _fieldsController,
            minLines: 8,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: '字段映射，每行 key=path',
              hintText: 'title=title\ninfoHash=infoHash\nmagnet=magnet',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJson() {
    return TextField(
      controller: _jsonController,
      expands: true,
      minLines: null,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
      decoration: const InputDecoration(
        alignLabelWithHint: true,
        labelText: '原始 JSON',
      ),
    );
  }

  void _applyJsonToForm({required bool showError}) {
    try {
      final JsonSourcePlugin plugin = parsePluginJson(_jsonController.text);
      _idController.text = plugin.id;
      _nameController.text = plugin.name;
      _baseUrlController.text = plugin.baseUrl.toString();
      _searchUrlController.text = plugin.search.url;
      _responseTypeController.text = plugin.search.responseType;
      _itemPatternController.text = plugin.search.itemPattern;
      _totalPatternController.text = plugin.search.totalPattern;
      _lastPagePatternController.text = plugin.search.lastPagePattern;
      _fieldsController.text = plugin.fields.entries
          .map((MapEntry<String, String> entry) {
            return '${entry.key}=${entry.value}';
          })
          .join('\n');
      setState(() {
        _enabled = plugin.enabled;
        _requiresHumanVerification =
            plugin.capabilities.requiresHumanVerification;
        _mode = 'form';
      });
    } catch (error) {
      if (showError) {
        _showDialogSnack(error.toString());
      }
    }
  }

  void _syncFormToJson() {
    final Map<String, Object?> json = <String, Object?>{
      'schemaVersion': 1,
      'id': _idController.text.trim(),
      'name': _nameController.text.trim(),
      'enabled': _enabled,
      'baseUrl': _baseUrlController.text.trim(),
      'capabilities': <String, Object?>{
        'requiresHumanVerification': _requiresHumanVerification,
      },
      'headers': <String, Object?>{},
      'search': <String, Object?>{
        'method': 'GET',
        'url': _searchUrlController.text.trim(),
        'responseType': _responseTypeController.text.trim().isEmpty
            ? 'html'
            : _responseTypeController.text.trim(),
        'itemPattern': _itemPatternController.text,
        'totalPattern': _totalPatternController.text,
        'lastPagePattern': _lastPagePatternController.text,
        'pageSize': 20,
      },
      'fields': _fieldsFromText(_fieldsController.text),
      'fileFields': <String, Object?>{},
      'defaults': <String, Object?>{'magnet': 'magnet:?xt=urn:btih:{infoHash}'},
    };
    _jsonController.text = const JsonEncoder.withIndent('  ').convert(json);
    _showDialogSnack('已生成 JSON');
  }

  void _save() {
    if (_mode == 'form') {
      _syncFormToJson();
    }
    try {
      parsePluginJson(_jsonController.text);
      Navigator.of(context).pop(_jsonController.text);
    } catch (error) {
      _showDialogSnack(error.toString());
    }
  }

  void _showDialogSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(appSnack(message));
  }
}

String _defaultPluginJson() {
  final Map<String, Object?> json = <String, Object?>{
    'schemaVersion': 1,
    'id': 'custom_source',
    'name': '自定义搜索源',
    'enabled': true,
    'baseUrl': 'https://example.com/',
    'capabilities': <String, Object?>{'requiresHumanVerification': false},
    'headers': <String, Object?>{
      'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    },
    'search': <String, Object?>{
      'method': 'GET',
      'url': '/search/{query}/{page}',
      'responseType': 'html',
      'itemPattern': '',
      'totalPattern': '',
      'lastPagePattern': '',
      'pageSize': 20,
    },
    'fields': <String, Object?>{
      'sourceItemId': 'sourceItemId',
      'title': 'title',
      'infoHash': 'infoHash',
      'magnet': 'magnet',
      'humanSize': 'humanSize',
      'seeders': 'seeders',
      'leechers': 'leechers',
      'webUrl': 'webUrl',
    },
    'fileFields': <String, Object?>{},
    'defaults': <String, Object?>{'magnet': 'magnet:?xt=urn:btih:{infoHash}'},
  };
  return const JsonEncoder.withIndent('  ').convert(json);
}

String _pluginToJson(JsonSourcePlugin plugin) {
  final Map<String, Object?> json = <String, Object?>{
    'schemaVersion': plugin.schemaVersion,
    'id': plugin.id,
    'name': plugin.name,
    'enabled': plugin.enabled,
    'baseUrl': plugin.baseUrl.toString(),
    'capabilities': <String, Object?>{
      'requiresHumanVerification':
          plugin.capabilities.requiresHumanVerification,
    },
    'headers': plugin.headers,
    'search': _endpointToJson(plugin.search),
    if (plugin.detail != null) 'detail': _endpointToJson(plugin.detail!),
    'fields': plugin.fields,
    'fileFields': plugin.fileFields,
    'defaults': plugin.defaults,
  };
  return const JsonEncoder.withIndent('  ').convert(json);
}

Map<String, Object?> _endpointToJson(PluginEndpoint endpoint) {
  return <String, Object?>{
    'method': endpoint.method,
    'url': endpoint.url,
    'responseType': endpoint.responseType,
    if (endpoint.headers.isNotEmpty) 'headers': endpoint.headers,
    if (endpoint.itemsPath.isNotEmpty) 'itemsPath': endpoint.itemsPath,
    if (endpoint.totalPath.isNotEmpty) 'totalPath': endpoint.totalPath,
    if (endpoint.currentPagePath.isNotEmpty)
      'currentPagePath': endpoint.currentPagePath,
    if (endpoint.lastPagePath.isNotEmpty) 'lastPagePath': endpoint.lastPagePath,
    if (endpoint.rootPath.isNotEmpty) 'rootPath': endpoint.rootPath,
    if (endpoint.filesPath.isNotEmpty) 'filesPath': endpoint.filesPath,
    if (endpoint.rootPattern.isNotEmpty) 'rootPattern': endpoint.rootPattern,
    if (endpoint.itemPattern.isNotEmpty) 'itemPattern': endpoint.itemPattern,
    if (endpoint.fileRootPattern.isNotEmpty)
      'fileRootPattern': endpoint.fileRootPattern,
    if (endpoint.filePattern.isNotEmpty) 'filePattern': endpoint.filePattern,
    if (endpoint.totalPattern.isNotEmpty) 'totalPattern': endpoint.totalPattern,
    if (endpoint.lastPagePattern.isNotEmpty)
      'lastPagePattern': endpoint.lastPagePattern,
    'pageSize': endpoint.pageSize,
  };
}

Map<String, Object?> _fieldsFromText(String text) {
  final Map<String, Object?> fields = <String, Object?>{};
  for (final String line in text.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final int index = trimmed.indexOf('=');
    if (index <= 0) {
      continue;
    }
    final String key = trimmed.substring(0, index).trim();
    final String value = trimmed.substring(index + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) {
      fields[key] = value;
    }
  }
  return fields;
}

class _SettingsSection extends StatefulWidget {
  const _SettingsSection({
    required this.pluginCount,
    required this.settings,
    required this.loading,
    required this.onSettingsChanged,
    required this.onOpenPlugins,
  });

  final int pluginCount;
  final AppSettings settings;
  final bool loading;
  final Future<void> Function(AppSettings settings) onSettingsChanged;
  final VoidCallback onOpenPlugins;

  @override
  State<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<_SettingsSection> {
  static final Uri _latestReleaseUrl = Uri.parse(
    'https://github.com/WEP-56/JAVBUS/releases/latest',
  );
  static final Uri _releasePage = Uri.parse(
    'https://github.com/WEP-56/JAVBUS/releases',
  );

  final TextEditingController _panServiceController = TextEditingController();
  final TextEditingController _panKeyController = TextEditingController();

  bool _saving = false;
  bool _panRequiresKey = false;

  @override
  void initState() {
    super.initState();
    _syncForm();
  }

  @override
  void didUpdateWidget(covariant _SettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.panServiceUrl != widget.settings.panServiceUrl ||
        oldWidget.settings.panApiKey != widget.settings.panApiKey ||
        oldWidget.settings.panRequiresApiKey !=
            widget.settings.panRequiresApiKey) {
      _syncForm();
    }
  }

  @override
  void dispose() {
    _panServiceController.dispose();
    _panKeyController.dispose();
    super.dispose();
  }

  void _syncForm() {
    _panServiceController.text = widget.settings.panServiceUrl;
    _panKeyController.text = widget.settings.panApiKey;
    _panRequiresKey = widget.settings.panRequiresApiKey;
  }

  Future<void> _saveSettings() async {
    final String serviceUrl = _panServiceController.text.trim();
    if (serviceUrl.isNotEmpty) {
      final Uri? uri = Uri.tryParse(
        serviceUrl.contains('://') ? serviceUrl : 'http://$serviceUrl',
      );
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        _showSnack('盘搜服务地址无效');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await widget.onSettingsChanged(
        widget.settings.copyWith(
          panServiceUrl: serviceUrl,
          panRequiresApiKey: _panRequiresKey,
          panApiKey: _panKeyController.text.trim(),
        ),
      );
      _showSnack('设置已保存');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(appSnack(message));
  }

  Future<void> _saveAppearance({String? themeMode, String? accentColor}) async {
    await widget.onSettingsChanged(
      widget.settings.copyWith(themeMode: themeMode, accentColor: accentColor),
    );
  }

  Future<void> _saveWindowsCloseBehavior(String behavior) async {
    await widget.onSettingsChanged(
      widget.settings.copyWith(windowsCloseBehavior: behavior),
    );
    _showSnack(behavior == 'exit' ? '关闭按钮将直接退出' : '关闭按钮将隐藏到托盘');
  }

  Future<void> _saveLanAutoStart(bool value) async {
    await widget.onSettingsChanged(
      widget.settings.copyWith(lanAutoStart: value),
    );
    _showSnack(value ? '局域网互传将随应用启动' : '已关闭局域网互传自启动');
  }

  Future<void> _showAboutDialog() async {
    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return _AboutJavbusDialog(
          version: packageInfo.version,
          buildNumber: packageInfo.buildNumber,
          onCheckUpdate: _checkForUpdates,
          onOpenReleases: _openReleasePage,
        );
      },
    );
  }

  Future<void> _checkForUpdates() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final http.Response response = await http
          .get(
            _latestReleaseUrl,
            headers: const <String, String>{'User-Agent': 'JAVBUS'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 404) {
        _showSnack('还没有发布过 Release');
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('GitHub Release 页面返回 HTTP ${response.statusCode}');
      }
      final String latest = _latestVersionFromReleaseResponse(response);
      if (latest.isEmpty) {
        throw const FormatException('无法从 Release 页面识别版本号');
      }
      final bool hasUpdate = _compareVersions(latest, packageInfo.version) > 0;
      if (!mounted) {
        return;
      }
      if (hasUpdate) {
        await _showUpdateDialog(latest, packageInfo.version);
      } else {
        _showSnack('当前已是最新版本');
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnack('检测更新失败：$error');
      }
    }
  }

  Future<void> _showUpdateDialog(String latest, String current) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('发现新版本'),
          content: Text('当前版本 $current，最新版本 $latest。请前往 GitHub Release 页面下载。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(_openReleasePage());
              },
              child: const Text('打开 Release'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openReleasePage() async {
    final bool opened = await launchUrl(
      _releasePage,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      _showSnack('无法打开 Release 页面');
    }
  }

  Future<void> _chooseLanReceiveDirectory() async {
    final String? directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择互传接收目录',
      initialDirectory: widget.settings.lanReceiveDirectory.trim().isEmpty
          ? null
          : widget.settings.lanReceiveDirectory.trim(),
    );
    if (directory == null || directory.trim().isEmpty) {
      return;
    }
    if (Platform.isAndroid &&
        !await AndroidStorageAccess.ensurePublicDirectoryAccess()) {
      _showSnack('需要授予所有文件访问权限后才能保存到该目录');
      return;
    }
    try {
      final Directory target = Directory(directory.trim());
      if (!await target.exists()) {
        await target.create(recursive: true);
      }
      final File probe = File(
        '${target.path}${Platform.pathSeparator}.javbus_write_test',
      );
      await probe.writeAsString('ok');
      await probe.delete();
    } on Object catch (error) {
      _showSnack('目录不可用：$error');
      return;
    }
    await widget.onSettingsChanged(
      widget.settings.copyWith(lanReceiveDirectory: directory.trim()),
    );
    _showSnack('互传接收目录已保存');
  }

  Future<void> _resetLanReceiveDirectory() async {
    await widget.onSettingsChanged(
      widget.settings.copyWith(lanReceiveDirectory: ''),
    );
    _showSnack('已恢复默认接收目录');
  }

  @override
  Widget build(BuildContext context) {
    final String selected = widget.settings.themeMode;
    final bool busy = widget.loading || _saving;

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.contrast_rounded,
            title: '显示模式',
            subtitle: '选择跟随系统，或固定浅色、深色外观。',
            trailing: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'system', label: Text('系统')),
                ButtonSegment<String>(value: 'light', label: Text('浅色')),
                ButtonSegment<String>(value: 'dark', label: Text('深色')),
              ],
              selected: <String>{selected},
              onSelectionChanged: (Set<String> values) {
                _saveAppearance(themeMode: values.first);
              },
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.palette_rounded,
            title: '主题色',
            subtitle: '选择界面高亮色，双端都会保存到本地设置。',
            trailing: _AccentPicker(
              selected: widget.settings.accentColor,
              enabled: !busy,
              onChanged: (String value) {
                _saveAppearance(accentColor: value);
              },
            ),
          ),
        ),
        if (Platform.isWindows) ...<Widget>[
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: _SettingTile(
              icon: Icons.space_dashboard_rounded,
              title: '关闭按钮行为',
              subtitle: '选择点窗口关闭按钮时隐藏到托盘继续运行，或直接退出应用。',
              trailing: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(
                    value: 'minimizeToTray',
                    label: Text('隐藏到托盘'),
                  ),
                  ButtonSegment<String>(value: 'exit', label: Text('退出')),
                ],
                selected: <String>{widget.settings.windowsCloseBehavior},
                onSelectionChanged: busy
                    ? null
                    : (Set<String> values) {
                        _saveWindowsCloseBehavior(values.first);
                      },
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.cloud_rounded,
            title: '盘搜服务',
            subtitle: '填写你自己部署的 PanSou 服务地址；留空时搜盘页不会请求任何默认服务。',
            trailing: _PanSettingsForm(
              serviceController: _panServiceController,
              keyController: _panKeyController,
              requiresKey: _panRequiresKey,
              loading: busy,
              onRequiresKeyChanged: (bool value) {
                setState(() => _panRequiresKey = value);
              },
              onSave: _saveSettings,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.sync_alt_rounded,
            title: '自启动局域网互传服务',
            subtitle: '开启后应用启动时会自动发现设备并接收文本、文件；关闭后可在互传页手动开启。',
            trailing: Switch.adaptive(
              value: widget.settings.lanAutoStart,
              onChanged: busy ? null : _saveLanAutoStart,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.download_rounded,
            title: '互传接收目录',
            subtitle: 'Windows 和 Android 接收文件时会保存到这里；留空则使用应用默认目录。',
            trailing: _DirectoryPickerControl(
              path: widget.settings.lanReceiveDirectory,
              loading: busy,
              onChoose: _chooseLanReceiveDirectory,
              onReset: _resetLanReceiveDirectory,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.folder_open_rounded,
            title: '插件目录',
            subtitle: '插件只从用户数据目录读取，需要在插件页自行安装 JSON。',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _ValueBadge(text: '${widget.pluginCount} 个'),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.text3(context),
                ),
              ],
            ),
            onTap: widget.onOpenPlugins,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        const SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.route_rounded,
            title: '网络代理',
            subtitle: '启动时会读取 JAVBUS_PROXY、HTTP_PROXY 等环境变量，也会尝试常见本地端口。',
            trailing: _ValueBadge(text: '自动'),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        SliverToBoxAdapter(
          child: _SettingTile(
            icon: Icons.info_outline_rounded,
            title: '关于',
            subtitle: '查看版本信息，或前往 GitHub Release 获取更新。',
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: AppTheme.text3(context),
            ),
            onTap: _showAboutDialog,
          ),
        ),
      ],
    );
  }
}

class _AboutJavbusDialog extends StatelessWidget {
  const _AboutJavbusDialog({
    required this.version,
    required this.buildNumber,
    required this.onCheckUpdate,
    required this.onOpenReleases,
  });

  final String version;
  final String buildNumber;
  final Future<void> Function() onCheckUpdate;
  final Future<void> Function() onOpenReleases;

  @override
  Widget build(BuildContext context) {
    final String displayVersion = buildNumber.isEmpty
        ? version
        : '$version+$buildNumber';
    return AlertDialog(
      title: const Text('关于'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'javbus',
              style: TextStyle(
                color: AppTheme.text1(context),
                fontWeight: FontWeight.w900,
                fontSize: 22,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '版本 $displayVersion',
              style: TextStyle(color: AppTheme.text2(context)),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () => unawaited(onOpenReleases()),
          child: const Text('Release'),
        ),
        FilledButton(
          onPressed: () => unawaited(onCheckUpdate()),
          child: const Text('检测更新'),
        ),
      ],
    );
  }
}

class _PanSettingsForm extends StatelessWidget {
  const _PanSettingsForm({
    required this.serviceController,
    required this.keyController,
    required this.requiresKey,
    required this.loading,
    required this.onRequiresKeyChanged,
    required this.onSave,
  });

  final TextEditingController serviceController;
  final TextEditingController keyController;
  final bool requiresKey;
  final bool loading;
  final ValueChanged<bool> onRequiresKeyChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: serviceController,
            enabled: !loading,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: 'https://your-pansou.example.com',
            ),
          ),
          const SizedBox(height: 10),
          SwitchListTile.adaptive(
            value: requiresKey,
            onChanged: loading ? null : onRequiresKeyChanged,
            title: const Text('需要密钥'),
            contentPadding: EdgeInsets.zero,
          ),
          if (requiresKey) ...<Widget>[
            const SizedBox(height: 10),
            TextField(
              controller: keyController,
              enabled: !loading,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密钥',
                hintText: 'Bearer token 或纯 token',
              ),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: loading ? null : onSave,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DirectoryPickerControl extends StatelessWidget {
  const _DirectoryPickerControl({
    required this.path,
    required this.loading,
    required this.onChoose,
    required this.onReset,
  });

  final String path;
  final bool loading;
  final VoidCallback onChoose;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final String trimmed = path.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.elevated(context),
              border: Border.all(color: AppTheme.border(context)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              trimmed.isEmpty ? '应用默认目录' : trimmed,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: trimmed.isEmpty
                    ? AppTheme.text3(context)
                    : AppTheme.text2(context),
                fontSize: 12,
                fontFamily: trimmed.isEmpty ? null : 'Consolas',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: loading || trimmed.isEmpty ? null : onReset,
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('默认'),
              ),
              FilledButton.icon(
                onPressed: loading ? null : onChoose,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('选择目录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccentPicker extends StatelessWidget {
  const _AccentPicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String selected;
  final bool enabled;
  final ValueChanged<String> onChanged;

  static const List<({String id, String label})> _items =
      <({String id, String label})>[
        (id: 'teal', label: '青绿'),
        (id: 'blue', label: '蓝色'),
        (id: 'violet', label: '紫色'),
        (id: 'rose', label: '玫红'),
        (id: 'amber', label: '琥珀'),
        (id: 'green', label: '绿色'),
      ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final ({String id, String label}) item in _items)
          Tooltip(
            message: item.label,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: enabled ? () => onChanged(item.id) : null,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: appAccentColor(item.id, Theme.of(context).brightness),
                  border: Border.all(
                    color: item.id == selected
                        ? AppTheme.text1(context)
                        : AppTheme.border(context),
                    width: item.id == selected ? 2 : 1,
                  ),
                ),
                child: item.id == selected
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.black
                            : Colors.white,
                        size: 17,
                      )
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

class _MagnetCard extends StatelessWidget {
  const _MagnetCard({
    required this.item,
    required this.detailLoading,
    required this.onCopy,
    required this.onSave,
    required this.onDetails,
  });

  final MagnetItem item;
  final bool detailLoading;
  final VoidCallback onCopy;
  final VoidCallback onSave;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final String title = item.title.isEmpty ? item.infoHash : item.title;

    return _ToolSurface(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ResultIcon(verified: item.verified),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.text1(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        height: 1.32,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: <Widget>[
                        _TinyChip(label: item.pluginName),
                        _TinyChip(label: item.displaySize),
                        _TinyChip(label: 'S ${item.seeders}'),
                        _TinyChip(label: 'L ${item.leechers}'),
                        if (item.verified) const _TinyChip(label: '已验证'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (item.largestFile.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 16,
                  color: AppTheme.text3(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.largestFile,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.text2(context),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.elevated(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              item.infoHash,
              maxLines: 1,
              style: TextStyle(
                color: AppTheme.text3(context),
                fontFamily: 'Consolas',
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: item.magnet.isEmpty ? null : onCopy,
                icon: const Icon(Icons.content_copy_rounded, size: 18),
                label: const Text('复制 magnet'),
              ),
              OutlinedButton.icon(
                onPressed: item.magnet.isEmpty && item.sourceItemId.isEmpty
                    ? null
                    : onSave,
                icon: const Icon(Icons.bookmark_add_rounded, size: 18),
                label: const Text('保存'),
              ),
              OutlinedButton.icon(
                onPressed: detailLoading ? null : onDetails,
                icon: detailLoading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.list_alt_rounded, size: 18),
                label: Text(item.hasDetails ? '刷新详情' : '文件列表'),
              ),
            ],
          ),
          if (item.files.isNotEmpty) ...<Widget>[
            Divider(height: 24, color: AppTheme.border(context)),
            for (final MagnetFile file in item.files.take(6))
              _FileRow(file: file),
            if (item.files.length > 6)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '还有 ${item.files.length - 6} 个文件',
                  style: TextStyle(
                    color: AppTheme.text3(context),
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final JsonSourcePlugin plugin;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                _PluginMark(selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              plugin.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.text1(context),
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _TinyChip(label: 'schema ${plugin.schemaVersion}'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${plugin.id} · ${plugin.baseUrl}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.text3(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: '编辑插件',
                  child: IconButton(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    color: AppTheme.text2(context),
                    style: IconButton.styleFrom(
                      fixedSize: const Size(36, 36),
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: '删除插件',
                  child: IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    color: AppTheme.text2(context),
                    style: IconButton.styleFrom(
                      fixedSize: const Size(36, 36),
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: selected ? '当前搜索源' : '设为搜索源',
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: selected
                        ? AppTheme.accent(context)
                        : AppTheme.text3(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool compact = constraints.maxWidth < 620;
                final Widget content = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.accentDim(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        icon,
                        color: AppTheme.accent(context),
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            style: TextStyle(
                              color: AppTheme.text1(context),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: AppTheme.text3(context),
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );

                if (compact) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      content,
                      const SizedBox(height: 14),
                      Align(alignment: Alignment.centerLeft, child: trailing),
                    ],
                  );
                }

                return Row(
                  children: <Widget>[
                    Expanded(child: content),
                    const SizedBox(width: 18),
                    trailing,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingDock extends StatelessWidget {
  const _FloatingDock({
    required this.active,
    required this.compact,
    required this.dark,
    required this.onChanged,
    required this.onOpenSettings,
  });

  final _WorkbenchSection active;
  final bool compact;
  final bool dark;
  final ValueChanged<_WorkbenchSection> onChanged;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppTheme.dock(context),
              border: Border.all(color: AppTheme.border(context)),
              borderRadius: BorderRadius.circular(18),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.34 : 0.08),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final _WorkbenchSection section in _dockSections)
                    _DockItem(
                      section: section,
                      selected: section == active,
                      compact: compact,
                      onTap: () => onChanged(section),
                    ),
                  Container(
                    width: 1,
                    height: 22,
                    margin: const EdgeInsets.symmetric(horizontal: 7),
                    color: AppTheme.border(context),
                  ),
                  Tooltip(
                    message: '设置',
                    child: IconButton(
                      onPressed: onOpenSettings,
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      color: active == _WorkbenchSection.settings
                          ? AppTheme.accent(context)
                          : AppTheme.text2(context),
                      style: IconButton.styleFrom(
                        backgroundColor: active == _WorkbenchSection.settings
                            ? AppTheme.accentDim(context)
                            : Colors.transparent,
                        fixedSize: const Size(38, 38),
                        minimumSize: const Size(38, 38),
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowsTitleBar extends StatelessWidget {
  const _WindowsTitleBar();

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final Color border = AppTheme.border(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: SizedBox(
        height: 36,
        child: Row(
          children: <Widget>[
            Expanded(
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      const FlutterLogo(size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'javbus',
                        style: TextStyle(
                          color: AppTheme.text2(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            WindowCaptionButton.minimize(
              brightness: brightness,
              onPressed: () => windowManager.minimize(),
            ),
            FutureBuilder<bool>(
              future: windowManager.isMaximized(),
              builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
                if (snapshot.data == true) {
                  return WindowCaptionButton.unmaximize(
                    brightness: brightness,
                    onPressed: () => windowManager.unmaximize(),
                  );
                }
                return WindowCaptionButton.maximize(
                  brightness: brightness,
                  onPressed: () => windowManager.maximize(),
                );
              },
            ),
            WindowCaptionButton.close(
              brightness: brightness,
              onPressed: () => windowManager.close(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.section,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final _WorkbenchSection section;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected
        ? AppTheme.accent(context)
        : AppTheme.text2(context);

    return Tooltip(
      message: section.label,
      child: Material(
        color: selected ? AppTheme.accentDim(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 40,
            width: compact ? 50 : 88,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(section.icon, size: 18, color: color),
                    if (!compact) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        section.dockLabel,
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
                if (selected)
                  Positioned(
                    bottom: 3,
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.accent(context),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolSurface extends StatelessWidget {
  const _ToolSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppTheme.isDark(context) ? 0.20 : 0.04,
            ),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionLead extends StatelessWidget {
  const _SectionLead({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.text1(context),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(color: AppTheme.text3(context), fontSize: 12),
              ),
            ],
          ),
        ),
        _ValueBadge(text: trailing),
      ],
    );
  }
}

class _ResultIcon extends StatelessWidget {
  const _ResultIcon({required this.verified});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: AppTheme.accentDim(context),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        verified ? Icons.verified_rounded : Icons.link_rounded,
        color: AppTheme.accent(context),
        size: 20,
      ),
    );
  }
}

class _PluginMark extends StatelessWidget {
  const _PluginMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.accentDim(context)
            : AppTheme.elevated(context),
        border: Border.all(
          color: selected ? AppTheme.accent(context) : AppTheme.border(context),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.extension_rounded,
        color: selected ? AppTheme.accent(context) : AppTheme.text3(context),
        size: 20,
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final MagnetFile file;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.insert_drive_file_outlined,
            size: 16,
            color: AppTheme.text3(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.text2(context), fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            file.displaySize,
            style: TextStyle(color: AppTheme.text3(context), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _InfoStrip extends StatelessWidget {
  const _InfoStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _InlineStrip(
      icon: Icons.info_outline_rounded,
      color: AppTheme.accent(context),
      message: message,
    );
  }
}

class _LoadingStrip extends StatelessWidget {
  const _LoadingStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: <Widget>[
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: AppTheme.text2(context), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineStrip extends StatelessWidget {
  const _InlineStrip({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: AppTheme.text2(context), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: AppTheme.elevated(context),
            border: Border.all(color: AppTheme.border(context)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.all_inbox_rounded,
            color: AppTheme.text3(context),
            size: 26,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '输入关键词后开始搜索',
          style: TextStyle(
            color: AppTheme.text1(context),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '结果会按插件源返回的顺序显示，可继续加载分页或复制 magnet。',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.text3(context), fontSize: 12),
        ),
      ],
    );
  }
}

class _PluginEmptyState extends StatelessWidget {
  const _PluginEmptyState();

  @override
  Widget build(BuildContext context) {
    return _ToolSurface(
      child: Column(
        children: <Widget>[
          Icon(
            Icons.search_off_rounded,
            color: AppTheme.text3(context),
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            '没有匹配的插件',
            style: TextStyle(
              color: AppTheme.text1(context),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyChip extends StatelessWidget {
  const _TinyChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: AppTheme.text2(context), fontSize: 11),
      ),
    );
  }
}

class _ValueBadge extends StatelessWidget {
  const _ValueBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: AppTheme.text2(context),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _stableFavoriteId(String value) {
  var hash = 2166136261;
  for (final int codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

String _cleanVersion(String? value) {
  final String raw = (value ?? '').trim();
  if (raw.isEmpty) {
    return '';
  }
  return raw
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .replaceAll(RegExp(r'[^0-9.]'), '');
}

String _latestVersionFromReleaseResponse(http.Response response) {
  final String fromUrl = _versionFromReleaseUrl(response.request?.url);
  if (fromUrl.isNotEmpty) {
    return fromUrl;
  }
  final RegExp urlPattern = RegExp(
    r'https://github\.com/WEP-56/JAVBUS/releases/tag/([^"'
    '<>\s]+)',
    caseSensitive: false,
  );
  final RegExpMatch? match = urlPattern.firstMatch(response.body);
  if (match == null) {
    return '';
  }
  return _cleanVersion(match.group(1));
}

String _versionFromReleaseUrl(Uri? uri) {
  if (uri == null) {
    return '';
  }
  final List<String> segments = uri.pathSegments;
  final int tagIndex = segments.indexOf('tag');
  if (tagIndex < 0 || tagIndex + 1 >= segments.length) {
    return '';
  }
  return _cleanVersion(segments[tagIndex + 1]);
}

int _compareVersions(String left, String right) {
  final List<int> leftParts = _versionParts(left);
  final List<int> rightParts = _versionParts(right);
  final int length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (int index = 0; index < length; index += 1) {
    final int leftPart = index < leftParts.length ? leftParts[index] : 0;
    final int rightPart = index < rightParts.length ? rightParts[index] : 0;
    if (leftPart != rightPart) {
      return leftPart.compareTo(rightPart);
    }
  }
  return 0;
}

List<int> _versionParts(String version) {
  return _cleanVersion(version)
      .split('.')
      .where((String part) => part.isNotEmpty)
      .map((String part) => int.tryParse(part) ?? 0)
      .toList(growable: false);
}
