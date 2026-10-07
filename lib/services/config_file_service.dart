import 'package:flutter/services.dart';

class ConfigFileService {
  const ConfigFileService();

  static const _channel = MethodChannel('com.mapsupervisor/capture');

  Future<String?> importJson() =>
      _channel.invokeMethod<String>('importConfigJson');

  Future<bool> exportJson(String json) async =>
      await _channel.invokeMethod<bool>('exportConfigJson', {
        'json': json,
        'fileName': 'MapSupervisor-config.json',
      }) ??
      false;
}
