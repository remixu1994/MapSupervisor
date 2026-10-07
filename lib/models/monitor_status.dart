class MonitorStatus {
  const MonitorStatus({
    this.isRunning = false,
    this.permissionRequired = false,
    this.message,
    this.lastCapture,
    this.lastSync,
    this.nextCapture,
    this.pending = 0,
    this.failed = 0,
    this.lastScreenshotPath,
  });

  final bool isRunning;
  final bool permissionRequired;
  final String? message;
  final DateTime? lastCapture;
  final DateTime? lastSync;
  final DateTime? nextCapture;
  final int pending;
  final int failed;
  final String? lastScreenshotPath;

  MonitorStatus copyWith({
    bool? isRunning,
    bool? permissionRequired,
    String? message,
    DateTime? lastCapture,
    DateTime? lastSync,
    DateTime? nextCapture,
    int? pending,
    int? failed,
    String? lastScreenshotPath,
  }) => MonitorStatus(
    isRunning: isRunning ?? this.isRunning,
    permissionRequired: permissionRequired ?? this.permissionRequired,
    message: message ?? this.message,
    lastCapture: lastCapture ?? this.lastCapture,
    lastSync: lastSync ?? this.lastSync,
    nextCapture: nextCapture ?? this.nextCapture,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    lastScreenshotPath: lastScreenshotPath ?? this.lastScreenshotPath,
  );
}
