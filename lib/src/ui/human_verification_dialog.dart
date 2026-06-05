import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win;

import '../app.dart';

class HumanVerificationResult {
  const HumanVerificationResult({
    required this.cookie,
    required this.html,
    required this.url,
  });

  final String cookie;
  final String html;
  final Uri? url;

  bool get hasCookie => cookie.trim().isNotEmpty;
  bool get hasHtml => html.trim().isNotEmpty;
}

class VerifiedWebViewSession {
  VerifiedWebViewSession();

  win.WebviewController? _windowsController;
  WebViewController? _androidController;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  final List<Completer<void>> _loadWaiters = <Completer<void>>[];
  final List<VoidCallback> _listeners = <VoidCallback>[];
  String _currentUrl = '';
  bool _initialized = false;
  bool _initializing = false;
  bool _loading = false;
  String? _error;

  String get currentUrl => _currentUrl;
  bool get initializing => _initializing;
  bool get loading => _loading || _initializing;
  String? get error => _error;

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  Future<HumanVerificationResult> load(Uri url) async {
    await _ensureInitialized();

    final Completer<void> waiter = Completer<void>();
    _loadWaiters.add(waiter);
    _setLoading(true);
    if (Platform.isWindows) {
      await _windowsController?.loadUrl(url.toString());
    } else {
      await _androidController?.loadRequest(url);
    }

    await waiter.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    await Future<void>.delayed(const Duration(milliseconds: 450));

    return HumanVerificationResult(
      cookie: await _readCookie() ?? '',
      html: await _readPageHtml() ?? '',
      url: Uri.tryParse(_currentUrl),
    );
  }

  Future<void> reload() async {
    if (Platform.isWindows) {
      await _windowsController?.reload();
    } else {
      await _androidController?.reload();
    }
  }

  void openDevTools() {
    if (Platform.isWindows) {
      _windowsController?.openDevTools();
    }
  }

  Future<String?> readCookie() => _readCookie();

  Future<String?> readPageHtml() => _readPageHtml();

  Widget buildWebView() {
    if (Platform.isWindows) {
      final win.WebviewController? controller = _windowsController;
      if (controller == null) {
        return const SizedBox.shrink();
      }
      return win.Webview(controller);
    }
    final WebViewController? controller = _androidController;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return WebViewWidget(controller: controller);
  }

  Future<void> dispose() async {
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _windowsController?.dispose();
    _windowsController = null;
    _androidController = null;
    _initialized = false;
    _initializing = false;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    _initializing = true;
    _error = null;
    notifyListeners();
    try {
      if (Platform.isWindows) {
        final win.WebviewController controller = win.WebviewController();
        _windowsController = controller;
        await controller.initialize();
        _subscriptions.add(
          controller.url.listen((String url) {
            _currentUrl = url;
            notifyListeners();
          }),
        );
        _subscriptions.add(
          controller.loadingState.listen((win.LoadingState state) {
            _setLoading(state == win.LoadingState.loading);
            if (state != win.LoadingState.loading) {
              _completeLoadWaiters();
            }
          }),
        );
        await controller.setUserAgent(_desktopUserAgent);
        await controller.setPopupWindowPolicy(
          win.WebviewPopupWindowPolicy.deny,
        );
      } else {
        final WebViewController controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageStarted: (String url) {
                _currentUrl = url;
                _setLoading(true);
              },
              onPageFinished: (String url) {
                _currentUrl = url;
                _setLoading(false);
                _completeLoadWaiters();
              },
              onWebResourceError: (WebResourceError error) {
                _error = error.description;
                notifyListeners();
              },
            ),
          );
        _androidController = controller;
      }
      _initialized = true;
    } on Object catch (error) {
      _error = error.toString();
      rethrow;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  void _setLoading(bool value) {
    if (_loading == value) {
      return;
    }
    _loading = value;
    notifyListeners();
  }

  void notifyListeners() {
    for (final VoidCallback listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  void _completeLoadWaiters() {
    final List<Completer<void>> waiters = List<Completer<void>>.from(
      _loadWaiters,
    );
    _loadWaiters.clear();
    for (final Completer<void> waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  Future<String?> _readCookie() async {
    if (Platform.isWindows) {
      final Object? value = await _windowsController?.executeScript(
        'document.cookie',
      );
      return _jsString(value);
    }
    final Object? value = await _androidController
        ?.runJavaScriptReturningResult('document.cookie');
    return _jsString(value);
  }

  Future<String?> _readPageHtml() async {
    const String script =
        'document.documentElement ? document.documentElement.outerHTML : ""';
    if (Platform.isWindows) {
      final Object? value = await _windowsController?.executeScript(script);
      return _jsString(value);
    }
    final Object? value = await _androidController
        ?.runJavaScriptReturningResult(script);
    return _jsString(value);
  }
}

Future<HumanVerificationResult?> showHumanVerificationDialog({
  required BuildContext context,
  required Uri url,
  required String pluginName,
  VerifiedWebViewSession? session,
}) {
  return showDialog<HumanVerificationResult>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return _HumanVerificationDialog(
        url: url,
        pluginName: pluginName,
        session: session,
      );
    },
  );
}

const String _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

String? _jsString(Object? value) {
  if (value == null) {
    return null;
  }
  final String raw = value.toString();
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded?.toString();
    } on FormatException {
      return raw.substring(1, raw.length - 1);
    }
  }
  return raw;
}

class _HumanVerificationDialog extends StatefulWidget {
  const _HumanVerificationDialog({
    required this.url,
    required this.pluginName,
    required this.session,
  });

  final Uri url;
  final String pluginName;
  final VerifiedWebViewSession? session;

  @override
  State<_HumanVerificationDialog> createState() =>
      _HumanVerificationDialogState();
}

class _HumanVerificationDialogState extends State<_HumanVerificationDialog> {
  late final VerifiedWebViewSession _session;
  late final bool _ownsSession;

  @override
  void initState() {
    super.initState();
    _ownsSession = widget.session == null;
    _session = widget.session ?? VerifiedWebViewSession();
    _session.addListener(_onSessionChanged);
    _load();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    if (_ownsSession) {
      unawaited(_session.dispose());
    }
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    try {
      await _session.load(widget.url);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            appSnack('${error.code}: ${error.message ?? error.details ?? ''}'),
          );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(appSnack(error.toString()));
      }
    }
  }

  Future<void> _finish() async {
    final String? cookie = await _session.readCookie();
    final String? html = await _session.readPageHtml();
    if (!mounted) {
      return;
    }
    if ((cookie == null || cookie.trim().isEmpty) &&
        (html == null || html.trim().isEmpty)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(appSnack('还没有读到可用 Cookie，请完成验证后再点一次。'));
      return;
    }
    Navigator.of(context).pop(
      HumanVerificationResult(
        cookie: cookie ?? '',
        html: html ?? '',
        url: Uri.tryParse(_session.currentUrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool compact = MediaQuery.sizeOf(context).width < 760;
    return Dialog(
      insetPadding: EdgeInsets.all(compact ? 14 : 28),
      backgroundColor: AppTheme.surface(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 820),
        child: SizedBox(
          width: compact ? double.infinity : 1040,
          height: compact ? 680 : 760,
          child: Column(
            children: <Widget>[
              _DialogHeader(
                pluginName: widget.pluginName,
                currentUrl: _session.currentUrl.isEmpty
                    ? widget.url.toString()
                    : _session.currentUrl,
                loading: _session.loading,
                onClose: () => Navigator.of(context).pop(),
              ),
              Expanded(child: _buildBody()),
              _DialogFooter(
                onReload: _reload,
                onOpenDevTools: Platform.isWindows
                    ? () => _session.openDevTools()
                    : null,
                onFinish: _session.initializing ? null : _finish,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_session.initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_session.error != null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: SelectableText(
          _session.error!,
          style: TextStyle(color: AppTheme.text2(context)),
        ),
      );
    }
    return _session.buildWebView();
  }

  Future<void> _reload() async {
    await _session.reload();
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.pluginName,
    required this.currentUrl,
    required this.loading,
    required this.onClose,
  });

  final String pluginName;
  final String currentUrl;
  final bool loading;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border(context))),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.verified_user_rounded, color: AppTheme.accent(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$pluginName 人机验证',
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  currentUrl,
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
          if (loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

class _DialogFooter extends StatelessWidget {
  const _DialogFooter({
    required this.onReload,
    required this.onOpenDevTools,
    required this.onFinish,
  });

  final VoidCallback onReload;
  final VoidCallback? onOpenDevTools;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.border(context))),
      ),
      child: Row(
        children: <Widget>[
          OutlinedButton.icon(
            onPressed: onReload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('刷新'),
          ),
          if (onOpenDevTools != null) ...<Widget>[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onOpenDevTools,
              icon: const Icon(Icons.developer_mode_rounded),
              label: const Text('DevTools'),
            ),
          ],
          const Spacer(),
          FilledButton.icon(
            onPressed: onFinish,
            icon: const Icon(Icons.check_rounded),
            label: const Text('我已完成验证'),
          ),
        ],
      ),
    );
  }
}
