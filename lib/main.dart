import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/platform/android_foreground_service.dart';
import 'src/settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    initAndroidForegroundCommunication();
  }

  if (Platform.isWindows) {
    await _prepareWindowsWindow();
  }

  runApp(const MagnetFinderApp());
}

Future<void> _prepareWindowsWindow() async {
  await windowManager.ensureInitialized();
  final AppSettingsStore settingsStore = AppSettingsStore();
  final AppSettings settings = await settingsStore.load();
  final Size savedSize = Size(
    settings.windowWidth.clamp(920, 3840).toDouble(),
    settings.windowHeight.clamp(620, 2160).toDouble(),
  );
  final WindowOptions windowOptions = WindowOptions(
    size: savedSize,
    minimumSize: const Size(920, 620),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.setPreventClose(true);
  final _WindowsRuntime runtime = _WindowsRuntime(settingsStore);
  windowManager.addListener(runtime);
  trayManager.addListener(runtime);
  await runtime.initializeTray();
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class _WindowsRuntime with WindowListener, TrayListener {
  _WindowsRuntime(this._settingsStore);

  final AppSettingsStore _settingsStore;
  Timer? _timer;
  bool _forceExit = false;
  bool _handlingClose = false;

  Future<void> initializeTray() async {
    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await trayManager.setToolTip('JAVBUS 正在运行');
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(key: 'show_window', label: '显示 JAVBUS'),
          MenuItem(key: 'hide_window', label: '隐藏到托盘'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: '退出'),
        ],
      ),
    );
  }

  @override
  void onWindowResize() {
    _scheduleSave();
  }

  @override
  void onWindowResized() {
    _scheduleSave();
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        unawaited(_showWindow());
        break;
      case 'hide_window':
        unawaited(windowManager.hide());
        break;
      case 'exit_app':
        unawaited(_exitApp());
        break;
    }
  }

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    if (!Platform.isWindows || await windowManager.isMaximized()) {
      return;
    }
    final Size size = await windowManager.getSize();
    if (size.width < 920 || size.height < 620) {
      return;
    }
    final AppSettings settings = await _settingsStore.load();
    await _settingsStore.save(
      settings.copyWith(windowWidth: size.width, windowHeight: size.height),
    );
  }

  Future<void> _handleWindowClose() async {
    if (_forceExit) {
      await trayManager.destroy();
      await windowManager.destroy();
      return;
    }
    if (_handlingClose) {
      return;
    }
    _handlingClose = true;
    _timer?.cancel();
    final Future<AppSettings> settingsFuture = _settingsStore.load();
    final Future<void> saveFuture = _save().catchError((Object _) {});
    await windowManager.hide();
    try {
      final AppSettings settings = await settingsFuture;
      if (settings.windowsCloseBehavior == 'exit') {
        await _exitApp(saveWindowState: false);
      }
    } finally {
      unawaited(saveFuture);
      _handlingClose = false;
    }
  }

  Future<void> _showWindow() async {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  }

  Future<void> _exitApp({bool saveWindowState = true}) async {
    _forceExit = true;
    _timer?.cancel();
    if (saveWindowState) {
      unawaited(_save().catchError((Object _) {}));
    }
    await trayManager.destroy();
    await windowManager.destroy();
  }
}
