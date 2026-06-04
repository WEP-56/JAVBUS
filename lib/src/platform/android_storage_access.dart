import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

class AndroidStorageAccess {
  const AndroidStorageAccess._();

  static Future<bool> ensurePublicDirectoryAccess() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final PermissionStatus current =
        await Permission.manageExternalStorage.status;
    if (current.isGranted) {
      return true;
    }
    final PermissionStatus requested = await Permission.manageExternalStorage
        .request();
    return requested.isGranted;
  }
}
