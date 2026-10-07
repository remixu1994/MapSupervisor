import 'dart:convert';

enum CaptureStatus { pending, success, failed }

enum SyncStatus { pending, uploading, success, failed }

enum AnalysisStatus { pending, processing, completed, failed }

class MonitorRecord {
  const MonitorRecord({
    required this.id,
    required this.timestamp,
    required this.characterName,
    required this.screenshotPath,
    required this.captureStatus,
    required this.syncStatus,
    required this.analysisStatus,
    this.siyuanBlockId,
    this.assetPath,
    this.errorMessage,
    this.retryCount = 0,
    this.recognizedCharacter,
    this.promptText,
    this.taskNumber,
    this.taskAction,
    this.analysisConfidence,
    this.rawAnalysis,
  });

  final String id;
  final DateTime timestamp;
  final String characterName;
  final String screenshotPath;
  final CaptureStatus captureStatus;
  final SyncStatus syncStatus;
  final AnalysisStatus analysisStatus;
  final String? siyuanBlockId;
  final String? assetPath;
  final String? errorMessage;
  final int retryCount;
  final String? recognizedCharacter;
  final String? promptText;
  final String? taskNumber;
  final String? taskAction;
  final double? analysisConfidence;
  final String? rawAnalysis;

  String get fileName => screenshotPath.replaceAll('\\', '/').split('/').last;

  MonitorRecord copyWith({
    CaptureStatus? captureStatus,
    SyncStatus? syncStatus,
    AnalysisStatus? analysisStatus,
    String? siyuanBlockId,
    String? assetPath,
    String? errorMessage,
    bool clearError = false,
    int? retryCount,
    String? recognizedCharacter,
    String? promptText,
    String? taskNumber,
    String? taskAction,
    double? analysisConfidence,
    String? rawAnalysis,
  }) => MonitorRecord(
    id: id,
    timestamp: timestamp,
    characterName: characterName,
    screenshotPath: screenshotPath,
    captureStatus: captureStatus ?? this.captureStatus,
    syncStatus: syncStatus ?? this.syncStatus,
    analysisStatus: analysisStatus ?? this.analysisStatus,
    siyuanBlockId: siyuanBlockId ?? this.siyuanBlockId,
    assetPath: assetPath ?? this.assetPath,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    retryCount: retryCount ?? this.retryCount,
    recognizedCharacter: recognizedCharacter ?? this.recognizedCharacter,
    promptText: promptText ?? this.promptText,
    taskNumber: taskNumber ?? this.taskNumber,
    taskAction: taskAction ?? this.taskAction,
    analysisConfidence: analysisConfidence ?? this.analysisConfidence,
    rawAnalysis: rawAnalysis ?? this.rawAnalysis,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'character_name': characterName,
    'screenshot_path': screenshotPath,
    'capture_status': captureStatus.name,
    'sync_status': syncStatus.name,
    'analysis_status': analysisStatus.name,
    'siyuan_block_id': siyuanBlockId,
    'asset_path': assetPath,
    'error_message': errorMessage,
    'retry_count': retryCount,
    'recognized_character': recognizedCharacter,
    'prompt_text': promptText,
    'task_number': taskNumber,
    'task_action': taskAction,
    'analysis_confidence': analysisConfidence,
    'raw_analysis': rawAnalysis,
  };

  factory MonitorRecord.fromMap(Map<String, Object?> map) => MonitorRecord(
    id: map['id']! as String,
    timestamp: DateTime.parse(map['timestamp']! as String),
    characterName: map['character_name']! as String,
    screenshotPath: map['screenshot_path']! as String,
    captureStatus: CaptureStatus.values.byName(
      map['capture_status']! as String,
    ),
    syncStatus: SyncStatus.values.byName(map['sync_status']! as String),
    analysisStatus: AnalysisStatus.values.byName(
      map['analysis_status']! as String,
    ),
    siyuanBlockId: map['siyuan_block_id'] as String?,
    assetPath: map['asset_path'] as String?,
    errorMessage: map['error_message'] as String?,
    retryCount: (map['retry_count'] as int?) ?? 0,
    recognizedCharacter: map['recognized_character'] as String?,
    promptText: map['prompt_text'] as String?,
    taskNumber: map['task_number'] as String?,
    taskAction: map['task_action'] as String?,
    analysisConfidence: (map['analysis_confidence'] as num?)?.toDouble(),
    rawAnalysis: map['raw_analysis'] as String?,
  );

  Map<String, Object?> metadata({SyncStatus? sync}) => {
    'schemaVersion': 1,
    'recordId': id,
    'timestamp': timestamp.toIso8601String(),
    'character': characterName,
    'device': 'android',
    'application': 'MapSupervisor',
    'capture': {'status': captureStatus.name, 'fileName': fileName},
    'sync': {'status': (sync ?? syncStatus).name},
    'analysis': {
      'status': analysisStatus.name,
      if (recognizedCharacter != null) 'character': recognizedCharacter,
      if (promptText != null) 'promptText': promptText,
      if (taskNumber != null) 'taskNumber': taskNumber,
      if (taskAction != null) 'action': taskAction,
      if (analysisConfidence != null) 'confidence': analysisConfidence,
    },
  };

  String metadataJson({SyncStatus? sync}) =>
      const JsonEncoder.withIndent('  ').convert(metadata(sync: sync));
}
