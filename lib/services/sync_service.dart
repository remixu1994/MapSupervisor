import 'dart:async';
import 'dart:io';

import '../config/supervisor_config.dart';
import '../models/monitor_record.dart';
import '../repositories/monitor_repository.dart';
import '../utils/app_log.dart';
import 'mimo_service.dart';
import 'siyuan_service.dart';

class SyncService {
  SyncService(this.repository);
  final MonitorRepository repository;
  static const retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  static const mimoRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  bool _processing = false;

  Future<MonitorRecord> syncOne(
    MonitorRecord record,
    SupervisorConfig config,
  ) async {
    var current = record.copyWith(
      syncStatus: SyncStatus.uploading,
      clearError: true,
    );
    await repository.upsert(current);
    logEvent('SYNC_PROCESS_START', {'record': current.id});
    try {
      if (current.analysisStatus != AnalysisStatus.completed) {
        current = current.copyWith(analysisStatus: AnalysisStatus.processing);
        await repository.upsert(current);
        logEvent('MIMO_ANALYSIS_START', {'record': current.id});
        final mimo = MimoService(config);
        final analysis = await analyzeMimoWithFallback(
          () => mimo.analyzeScreenshot(current.screenshotPath),
          onRetry: (retry, error, delay) {
            logEvent('MIMO_ANALYSIS_RETRY', {
              'record': current.id,
              'retry': retry,
              'delaySeconds': delay.inSeconds,
              'error': error,
            });
          },
        );
        current = current.copyWith(
          analysisStatus: AnalysisStatus.completed,
          recognizedCharacter: analysis.characterName,
          promptText: analysis.promptText,
          taskNumber: analysis.taskNumber,
          taskAction: analysis.action,
          analysisConfidence: analysis.confidence,
          rawAnalysis: analysis.rawResponse,
        );
        await repository.upsert(current);
        logEvent('MIMO_ANALYSIS_SUCCESS', {
          'record': current.id,
          'character': analysis.characterName,
          'action': analysis.action,
        });
      }
      final siyuan = SiyuanService(config);
      String? assetPath;
      if (config.uploadScreenshotToSiyuan) {
        assetPath = current.assetPath ?? await siyuan.uploadScreenshot(current);
        current = current.copyWith(assetPath: assetPath);
        await repository.upsert(current);
        logEvent('SIYUAN_SCREENSHOT_UPLOADED', {
          'record': current.id,
          'asset': assetPath,
        });
      }
      final dailyId = await siyuan.ensureFolderStructure(current.timestamp);
      final blockId = await siyuan.createMonitoringRecord(
        current,
        dailyId,
        assetPath: assetPath,
      );
      current = current.copyWith(
        syncStatus: SyncStatus.success,
        siyuanBlockId: blockId,
        clearError: true,
      );
      await repository.upsert(current);
      logEvent('SIYUAN_RECORD_CREATED', {
        'record': current.id,
        'block': blockId,
      });
      final file = File(current.screenshotPath);
      if (await file.exists()) await file.delete();
      return current;
    } catch (error) {
      if (current.analysisStatus == AnalysisStatus.processing) {
        current = current.copyWith(analysisStatus: AnalysisStatus.failed);
        logEvent('MIMO_ANALYSIS_FAILED', {
          'record': current.id,
          'error': error,
        });
      }
      current = recordAfterSyncFailure(current, error);
      await repository.upsert(current);
      logEvent('SYNC_PROCESS_FAILED', {'record': current.id, 'error': error});
      return current;
    }
  }

  Future<MonitorRecord> syncWithRetry(
    MonitorRecord record,
    SupervisorConfig config,
  ) async {
    var current = record;
    if (current.retryCount == 0) {
      current = await syncOne(current, config);
    }
    while (shouldRetry(current)) {
      final delay = retryDelayFor(current.retryCount);
      logEvent('SYNC_RETRY', {
        'record': current.id,
        'retry': current.retryCount,
        'delaySeconds': delay.inSeconds,
      });
      await Future<void>.delayed(delay);
      current = await syncOne(current, config);
    }
    return current;
  }

  Future<void> retryPending(SupervisorConfig config) async {
    if (_processing || config.validate() != null) return;
    _processing = true;
    try {
      final records = await repository.pending();
      for (final record in records) {
        final candidate = record.retryCount > 3
            ? record.copyWith(retryCount: 0)
            : record;
        if (candidate.retryCount != record.retryCount) {
          await repository.upsert(candidate);
        }
        if (!shouldRetry(candidate)) {
          continue;
        }
        await syncWithRetry(candidate, config);
      }
    } finally {
      _processing = false;
    }
  }
}

bool shouldRetry(MonitorRecord record) =>
    record.captureStatus == CaptureStatus.success &&
    record.syncStatus != SyncStatus.success &&
    record.retryCount <= 3;

Duration retryDelayFor(int completedAttempts) {
  if (completedAttempts <= 0) return Duration.zero;
  final index = (completedAttempts - 1).clamp(
    0,
    SyncService.retryDelays.length - 1,
  );
  return SyncService.retryDelays[index];
}

MonitorRecord recordAfterSyncFailure(MonitorRecord record, Object error) =>
    record.copyWith(
      syncStatus: SyncStatus.failed,
      errorMessage: error.toString(),
      retryCount: record.retryCount + 1,
    );

typedef MimoAttempt = Future<MimoAnalysis> Function();
typedef MimoDelay = Future<void> Function(Duration duration);
typedef MimoRetryCallback =
    void Function(int retry, Object error, Duration delay);

Future<MimoAnalysis> analyzeMimoWithFallback(
  MimoAttempt attempt, {
  MimoDelay? delay,
  MimoRetryCallback? onRetry,
}) async {
  Object? lastError;
  final wait = delay ?? Future<void>.delayed;
  for (
    var attemptIndex = 0;
    attemptIndex <= SyncService.mimoRetryDelays.length;
    attemptIndex++
  ) {
    try {
      return await attempt();
    } catch (error) {
      lastError = error;
      if (attemptIndex == SyncService.mimoRetryDelays.length) break;
      final retryDelay = SyncService.mimoRetryDelays[attemptIndex];
      onRetry?.call(attemptIndex + 1, error, retryDelay);
      await wait(retryDelay);
    }
  }
  return MimoAnalysis.degraded(lastError ?? '未知错误');
}
