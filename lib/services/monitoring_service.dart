import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../config/supervisor_config.dart';
import '../models/monitor_record.dart';
import '../models/monitor_status.dart';
import '../repositories/monitor_repository.dart';
import '../utils/app_log.dart';
import 'sync_service.dart';

class MonitoringService {
  MonitoringService(this.repository)
    : syncService = SyncService(repository),
      _status = const MonitorStatus();

  static const _methods = MethodChannel('com.mapsupervisor/capture');
  static const _events = EventChannel('com.mapsupervisor/capture_events');
  final MonitorRepository repository;
  final SyncService syncService;
  final _controller = StreamController<MonitorStatus>.broadcast();
  MonitorStatus _status;
  StreamSubscription<Object?>? _subscription;
  SupervisorConfig _config = SupervisorConfig.defaults;

  Stream<MonitorStatus> get statuses => _controller.stream;
  MonitorStatus get status => _status;

  Future<void> initialize(SupervisorConfig config) async {
    _config = config;
    _subscription ??= _events.receiveBroadcastStream().listen(
      _handleEvent,
      onError: (Object error) =>
          _setStatus(_status.copyWith(message: '原生监控错误：$error')),
    );
    final native = await _methods.invokeMapMethod<String, Object?>('getStatus');
    final counts = await repository.counts();
    _setStatus(
      _status.copyWith(
        isRunning: native?['running'] == true,
        permissionRequired: native?['permissionRequired'] == true,
        message: native?['message'] as String?,
        pending: counts.pending,
        failed: counts.failed,
      ),
    );
  }

  Future<void> start(SupervisorConfig config) async {
    _config = config;
    await config.save();
    unawaited(syncService.retryPending(config).then((_) => refreshCounts()));
    logEvent('MONITOR_START', {'interval': config.screenshotIntervalSeconds});
    await _methods.invokeMethod<void>('startMonitoring', {
      'intervalSeconds': config.screenshotIntervalSeconds,
    });
  }

  Future<void> stop() async {
    await _methods.invokeMethod<void>('stopMonitoring');
    logEvent('MONITOR_STOP');
    _setStatus(_status.copyWith(isRunning: false, message: '监控已停止'));
  }

  Future<void> captureNow(SupervisorConfig config) async {
    _config = config;
    await _methods.invokeMethod<void>('captureNow', {
      'intervalSeconds': config.screenshotIntervalSeconds,
    });
  }

  Future<void> refreshCounts() async {
    final counts = await repository.counts();
    _setStatus(
      _status.copyWith(pending: counts.pending, failed: counts.failed),
    );
  }

  Future<void> _handleEvent(Object? raw) async {
    if (raw is! Map) return;
    final event = Map<Object?, Object?>.from(raw);
    final type = event['type'];
    if (type == 'status') {
      final running = event['running'] == true;
      final permissionRequired = event['permissionRequired'] == true;
      final nextMillis = event['nextCaptureAt'] as int?;
      _setStatus(
        _status.copyWith(
          isRunning: running,
          permissionRequired: permissionRequired,
          message: event['message'] as String?,
          nextCapture: nextMillis == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(nextMillis),
        ),
      );
      return;
    }
    if (type == 'captured') {
      final path = event['path'] as String;
      final timestamp = DateTime.fromMillisecondsSinceEpoch(
        event['timestamp'] as int,
      );
      final recordId = const Uuid().v5(Namespace.url.value, path);
      final existing = await repository.find(recordId);
      final record = existing == null
          ? MonitorRecord(
              id: recordId,
              timestamp: timestamp,
              characterName: event['characterName'] as String,
              screenshotPath: path,
              captureStatus: CaptureStatus.success,
              syncStatus: SyncStatus.pending,
              analysisStatus: AnalysisStatus.pending,
            )
          : existing.retryCount > 3
          ? existing.copyWith(retryCount: 0)
          : existing;
      if (existing == null || record.retryCount != existing.retryCount) {
        await repository.upsert(record);
      }
      logEvent('CAPTURE_SUCCESS', {'file': record.fileName});
      _setStatus(
        _status.copyWith(
          lastCapture: timestamp,
          lastScreenshotPath: path,
          nextCapture: timestamp.add(
            Duration(seconds: _config.screenshotIntervalSeconds),
          ),
        ),
      );
      if (_config.validate() != null) {
        final counts = await repository.counts();
        _setStatus(
          _status.copyWith(
            message: '测试截图已保存在本地；配置 SiYuan 后将自动同步',
            pending: counts.pending,
            failed: counts.failed,
          ),
        );
        return;
      }
      final synced = await syncService.syncWithRetry(record, _config);
      final counts = await repository.counts();
      _setStatus(
        _status.copyWith(
          lastSync: synced.syncStatus == SyncStatus.success
              ? DateTime.now()
              : _status.lastSync,
          message: synced.syncStatus == SyncStatus.success
              ? '识别完成：${synced.recognizedCharacter ?? '未识别'} · '
                    '${synced.taskAction ?? synced.promptText ?? '状态检查'}；已写入 SiYuan'
              : '处理失败：${synced.errorMessage ?? '未知错误'}；截图已保留并等待重试',
          pending: counts.pending,
          failed: counts.failed,
        ),
      );
    } else if (type == 'captureFailed') {
      logEvent('CAPTURE_FAILED', {'error': event['message']});
      _setStatus(_status.copyWith(message: event['message'] as String?));
    }
  }

  void _setStatus(MonitorStatus value) {
    _status = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
