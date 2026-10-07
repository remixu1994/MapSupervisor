import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:map_supervisor/config/supervisor_config.dart';
import 'package:map_supervisor/models/monitor_record.dart';
import 'package:map_supervisor/services/siyuan_service.dart';
import 'package:map_supervisor/services/sync_service.dart';
import 'package:map_supervisor/services/mimo_service.dart';
import 'package:map_supervisor/utils/file_names.dart';

void main() {
  final timestamp = DateTime(2026, 9, 26, 15, 35, 1);
  final record = MonitorRecord(
    id: 'cb4907e0-2c00-4ca6-97d6-8df06defde34',
    timestamp: timestamp,
    characterName: '夜雨',
    screenshotPath: '/tmp/20260926_153501_夜雨.png',
    captureStatus: CaptureStatus.success,
    syncStatus: SyncStatus.pending,
    analysisStatus: AnalysisStatus.pending,
  );

  test('MonitorRecord database serialization round-trips', () {
    final restored = MonitorRecord.fromMap(record.toMap());
    expect(restored.id, record.id);
    expect(restored.timestamp, record.timestamp);
    expect(restored.characterName, '夜雨');
    expect(restored.captureStatus, CaptureStatus.success);
    expect(restored.syncStatus, SyncStatus.pending);
    expect(restored.analysisStatus, AnalysisStatus.pending);
  });

  test('versioned metadata is machine readable', () {
    final metadata = jsonDecode(record.metadataJson()) as Map<String, dynamic>;
    expect(metadata['schemaVersion'], 1);
    expect(metadata['recordId'], record.id);
    expect((metadata['analysis'] as Map)['status'], 'pending');
    expect((metadata['capture'] as Map)['fileName'], '20260926_153501_夜雨.png');
  });

  test('SiYuan monitoring markdown contains only the compact text log', () {
    const config = SupervisorConfig(
      siyuanBaseUrl: 'http://localhost:6806',
      siyuanToken: 'test',
      notebookId: '20250305001716-bvpgdom',
      targetDocumentId: '20261006220439-6oea414',
      characterName: '夜雨',
      screenshotIntervalSeconds: 60,
      mimoBaseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
      mimoApiKey: 'tp-test',
      mimoModel: 'mimo-v2.5',
      uploadScreenshotToSiyuan: false,
    );
    final analyzed = record.copyWith(
      analysisStatus: AnalysisStatus.completed,
      recognizedCharacter: '月丶奶妈',
      promptText: '编号123 开始执行日常任务',
      taskNumber: '123',
      taskAction: '开始执行日常任务',
      analysisConfidence: 0.93,
    );
    final analyzedMarkdown = SiyuanService(config).monitoringMarkdown(analyzed);
    expect(
      analyzedMarkdown,
      contains('2026-9-26 15:35  月丶奶妈  编号123  开始执行日常任务'),
    );
    expect(analyzedMarkdown, contains('绿色提示：编号123 开始执行日常任务'));
    expect(analyzedMarkdown, contains('识别置信度：93%'));
    expect(analyzedMarkdown, isNot(contains('![screenshot]')));
    expect(analyzedMarkdown, isNot(contains('```json')));
    expect(analyzedMarkdown, isNot(contains('schemaVersion')));

    final markdownWithScreenshot = SiyuanService(
      config.copyWith(uploadScreenshotToSiyuan: true),
    ).monitoringMarkdown(analyzed, assetPath: 'assets/example.png');
    expect(
      markdownWithScreenshot,
      contains('![screenshot](assets/example.png)'),
    );
    expect(markdownWithScreenshot, isNot(contains('```json')));
  });

  test('MiMo JSON response is parsed into structured fields', () {
    final analysis = MimoAnalysis.fromResponse('''```json
{"characterName":"月丶奶妈","promptText":"编号123 开始执行日常任务","taskNumber":"123","action":"开始执行日常任务","confidence":0.93}
```''');
    expect(analysis.characterName, '月丶奶妈');
    expect(analysis.taskNumber, '123');
    expect(analysis.action, '开始执行日常任务');
    expect(analysis.confidence, 0.93);
  });

  test('MiMo retries three times then degrades without failing sync', () async {
    var attempts = 0;
    final delays = <Duration>[];
    final analysis = await analyzeMimoWithFallback(() async {
      attempts += 1;
      throw const MimoException('MiMo 返回了空结果');
    }, delay: (duration) async => delays.add(duration));

    expect(attempts, 4);
    expect(delays, SyncService.mimoRetryDelays);
    expect(analysis.characterName, '未识别');
    expect(analysis.promptText, '未识别到绿色提示');
    expect(analysis.action, '状态检查');
    expect(analysis.confidence, 0);
    expect(analysis.rawResponse, contains('已降级'));
  });

  test('MiMo retry stops as soon as a later attempt succeeds', () async {
    var attempts = 0;
    final analysis = await analyzeMimoWithFallback(() async {
      attempts += 1;
      if (attempts < 3) throw const MimoException('temporary');
      return MimoAnalysis.fromResponse(
        '{"characterName":"月月健身","promptText":"宠物发动了热力增益。",'
        '"taskNumber":"","action":"宠物发动了热力增益","confidence":0.95}',
      );
    }, delay: (_) async {});

    expect(attempts, 3);
    expect(analysis.characterName, '月月健身');
    expect(analysis.confidence, 0.95);
  });

  test('existing daily note selection is stable and reuses the oldest ID', () {
    expect(
      selectExistingDocumentId([
        '20261006150000-bbbbbbb',
        '20261006140000-aaaaaaa',
      ]),
      '20261006140000-aaaaaaa',
    );
    expect(selectExistingDocumentId([]), isNull);
  });

  test('file and daily document names are sanitized and stable', () {
    expect(
      screenshotFileName(DateTime(2026, 9, 26, 15, 35, 1), '夜雨/主号'),
      '20260926_153501_夜雨_主号.png',
    );
    expect(dailyDocumentName(DateTime(2026, 9, 26)), '2026-09-26');
  });

  test('retry transition increments attempts and stops after three', () {
    final first = recordAfterSyncFailure(record, 'offline');
    expect(first.syncStatus, SyncStatus.failed);
    expect(first.retryCount, 1);
    expect(first.errorMessage, 'offline');
    expect(shouldRetry(first), isTrue);
    expect(retryDelayFor(1), const Duration(seconds: 5));
    expect(retryDelayFor(2), const Duration(seconds: 30));
    final third = first.copyWith(retryCount: 3);
    expect(shouldRetry(third), isTrue);
    expect(retryDelayFor(3), const Duration(seconds: 60));
    expect(shouldRetry(first.copyWith(retryCount: 4)), isFalse);
  });

  test('JSON config export and import round-trips every user setting', () {
    const config = SupervisorConfig(
      siyuanBaseUrl: 'https://siyuan.example.com/',
      siyuanToken: 'siyuan-secret',
      notebookId: '20250305001716-bvpgdom',
      targetDocumentId: '20261006230439-yzzw5z9',
      characterName: SupervisorConfig.defaultCharacterName,
      screenshotIntervalSeconds: 25 * 60,
      mimoBaseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
      mimoApiKey: 'tp-secret',
      mimoModel: 'mimo-v2.5',
      uploadScreenshotToSiyuan: true,
    );

    final restored = SupervisorConfig.fromJsonString(config.toJsonString());

    expect(restored.siyuanBaseUrl, config.siyuanBaseUrl);
    expect(restored.siyuanToken, config.siyuanToken);
    expect(restored.notebookId, config.notebookId);
    expect(restored.targetDocumentId, config.targetDocumentId);
    expect(restored.screenshotIntervalSeconds, 25 * 60);
    expect(restored.mimoBaseUrl, config.mimoBaseUrl);
    expect(restored.mimoApiKey, config.mimoApiKey);
    expect(restored.mimoModel, config.mimoModel);
    expect(restored.uploadScreenshotToSiyuan, isTrue);
  });

  test('JSON config import rejects unsupported schemas', () {
    expect(
      () => SupervisorConfig.fromJsonString('{"schemaVersion":99}'),
      throwsFormatException,
    );
  });
}
