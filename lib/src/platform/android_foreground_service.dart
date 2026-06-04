import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void initAndroidForegroundCommunication() {
  FlutterForegroundTask.initCommunicationPort();
}

Future<void> startAndroidForegroundService() async {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'javbus_lan_transfer',
      channelName: 'JAVBUS 局域网互传',
      channelDescription: 'JAVBUS 后台运行时显示互传连接状态。',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  final NotificationPermission notificationPermission =
      await FlutterForegroundTask.checkNotificationPermission();
  if (notificationPermission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }

  final bool running = await FlutterForegroundTask.isRunningService;
  final ServiceRequestResult result = running
      ? await FlutterForegroundTask.updateService(
          notificationTitle: 'JAVBUS 正在运行',
          notificationText: '局域网互传可继续接收连接和文件。',
          callback: _androidForegroundCallback,
        )
      : await FlutterForegroundTask.startService(
          serviceId: 45656,
          serviceTypes: const <ForegroundServiceTypes>[
            ForegroundServiceTypes.dataSync,
          ],
          notificationTitle: 'JAVBUS 正在运行',
          notificationText: '局域网互传可继续接收连接和文件。',
          notificationInitialRoute: '/',
          callback: _androidForegroundCallback,
        );
  if (result is ServiceRequestFailure) {
    debugPrint('Failed to start JAVBUS foreground service: ${result.error}');
  }
}

Future<void> updateAndroidForegroundStatus({
  required bool running,
  required int peerCount,
  String? error,
}) async {
  try {
    if (!await FlutterForegroundTask.isRunningService) {
      return;
    }
    final String trimmedError = error?.trim() ?? '';
    final String text = trimmedError.isNotEmpty
        ? '局域网互传异常：$trimmedError'
        : running
        ? peerCount > 0
              ? '局域网互传在线，已发现 $peerCount 台设备。'
              : '局域网互传在线，等待局域网设备连接。'
        : '局域网互传服务未启动。';
    final ServiceRequestResult result =
        await FlutterForegroundTask.updateService(
          notificationTitle: 'JAVBUS 正在运行',
          notificationText: text,
        );
    if (result is ServiceRequestFailure) {
      debugPrint('Failed to update JAVBUS foreground status: ${result.error}');
    }
  } on Object catch (error) {
    debugPrint('Failed to update JAVBUS foreground status: $error');
  }
}

Future<void> stopAndroidForegroundService() async {
  try {
    if (await FlutterForegroundTask.isRunningService) {
      final ServiceRequestResult result =
          await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        debugPrint('Failed to stop JAVBUS foreground service: ${result.error}');
      }
    }
  } on Object catch (error) {
    debugPrint('Failed to stop JAVBUS foreground service: $error');
  }
}

@pragma('vm:entry-point')
void _androidForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_JavbusForegroundTaskHandler());
}

class _JavbusForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.updateService(
      notificationTitle: 'JAVBUS 正在运行',
      notificationText: '局域网互传可继续接收连接和文件。',
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.updateService(
      notificationTitle: 'JAVBUS 正在运行',
      notificationText: '局域网互传保持在线，点击返回应用。',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
