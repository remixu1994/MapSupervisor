import 'package:flutter/services.dart';

class ScreenshotService {
  const ScreenshotService();
  static const _channel = MethodChannel('com.mapsupervisor/capture');

  Future<void> captureNow({
    required String characterName,
    required int intervalSeconds,
  }) => _channel.invokeMethod<void>('captureNow', {
    'characterName': characterName,
    'intervalSeconds': intervalSeconds,
  });
}
