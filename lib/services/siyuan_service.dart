import 'dart:io';

import 'package:dio/dio.dart';
import 'package:intl/intl.dart';

import '../config/supervisor_config.dart';
import '../models/monitor_record.dart';
import '../utils/file_names.dart';

class SiyuanException implements Exception {
  const SiyuanException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SiyuanService {
  SiyuanService(this.config)
    : _dio = Dio(
        BaseOptions(
          baseUrl: config.siyuanBaseUrl.trim().replaceFirst(RegExp(r'/$'), ''),
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Authorization': 'Token ${config.siyuanToken.trim()}'},
        ),
      );

  final SupervisorConfig config;
  final Dio _dio;
  static final Map<String, Future<String>> _dailyDocumentRequests = {};

  Future<void> testConnection() async {
    await _post('/api/system/version', const <String, Object?>{});
    await _resolveTargetDocument();
  }

  Future<String> ensureFolderStructure(DateTime timestamp) async {
    final target = await _resolveTargetDocument();
    final day = dailyDocumentName(timestamp);
    final parentPath = target.hpath.endsWith('/')
        ? target.hpath.substring(0, target.hpath.length - 1)
        : target.hpath;
    final dailyPath = '$parentPath/$day';
    final requestKey = [
      config.siyuanBaseUrl.trim(),
      config.notebookId.trim(),
      dailyPath,
    ].join('|');
    final active = _dailyDocumentRequests[requestKey];
    if (active != null) return active;
    final request = _findOrCreateDailyDocument(dailyPath);
    _dailyDocumentRequests[requestKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_dailyDocumentRequests[requestKey], request)) {
        _dailyDocumentRequests.remove(requestKey);
      }
    }
  }

  Future<String> _findOrCreateDailyDocument(String dailyPath) async {
    final existing = await _post('/api/filetree/getIDsByHPath', {
      'notebook': config.notebookId.trim(),
      'path': dailyPath,
    });
    final existingId = selectExistingDocumentId(existing['data']);
    if (existingId != null) return existingId;

    final response = await _post('/api/filetree/createDocWithMd', {
      'notebook': config.notebookId.trim(),
      'path': dailyPath,
      'markdown': '',
    });
    final id = response['data'];
    if (id is! String || id.isEmpty) {
      throw const SiyuanException('SiYuan 未返回每日文档 ID');
    }
    final verified = await _post('/api/filetree/getIDsByHPath', {
      'notebook': config.notebookId.trim(),
      'path': dailyPath,
    });
    final verifiedId = selectExistingDocumentId(verified['data']);
    if (verifiedId == null) {
      throw const SiyuanException('每日文档创建后验证失败');
    }
    return verifiedId;
  }

  Future<_TargetDocument> _resolveTargetDocument() async {
    final documentId = config.targetDocumentId.trim();
    if (!RegExp(r'^\d{14}-[a-z0-9]{7}$').hasMatch(documentId)) {
      throw const SiyuanException('目标子文档 ID 格式无效');
    }
    final response = await _post('/api/query/sql', {
      'stmt':
          "SELECT box, hpath, type FROM blocks WHERE id = '$documentId' LIMIT 1",
    });
    final rows = response['data'];
    if (rows is! List || rows.isEmpty || rows.first is! Map) {
      throw SiyuanException('找不到目标子文档：$documentId');
    }
    final row = rows.first as Map;
    final notebook = row['box']?.toString() ?? '';
    final hpath = row['hpath']?.toString() ?? '';
    if (row['type']?.toString() != 'd' || hpath.isEmpty) {
      throw SiyuanException('$documentId 不是思源文档 ID');
    }
    if (notebook != config.notebookId.trim()) {
      throw SiyuanException(
        '目标子文档属于笔记本 $notebook，与配置的 ${config.notebookId.trim()} 不一致',
      );
    }
    return _TargetDocument(hpath: hpath);
  }

  Future<String> uploadScreenshot(MonitorRecord record) async {
    final file = File(record.screenshotPath);
    if (!await file.exists()) throw const SiyuanException('本地截图不存在');
    final response = await _post(
      '/api/asset/upload',
      FormData.fromMap({
        'assetsDirPath': '/assets/MapSupervisor/',
        'file[]': await MultipartFile.fromFile(
          file.path,
          filename: record.fileName,
        ),
      }),
    );
    final data = response['data'];
    if (data is Map) {
      final files = data['succFiles'];
      if (files is List && files.isNotEmpty && files.first is Map) {
        final path = (files.first as Map)['path'];
        if (path is String && path.isNotEmpty) return path;
      }
      final map = data['succMap'];
      if (map is Map && map[record.fileName] is String) {
        return map[record.fileName] as String;
      }
    }
    throw const SiyuanException('SiYuan 未返回上传后的资源路径');
  }

  String monitoringMarkdown(MonitorRecord record, {String? assetPath}) {
    final logTime = DateFormat('yyyy-M-d HH:mm').format(record.timestamp);
    final character = record.recognizedCharacter ?? '未识别';
    final number = (record.taskNumber?.trim() ?? '').replaceFirst(
      RegExp(r'^编号\s*'),
      '',
    );
    final action = record.taskAction?.trim() ?? '状态检查';
    final prompt = record.promptText?.trim() ?? '未识别到绿色提示';
    return '''$logTime  $character${number.isEmpty ? '' : '  编号$number'}  $action

- 绿色提示：$prompt
- 识别置信度：${((record.analysisConfidence ?? 0) * 100).toStringAsFixed(0)}%
${assetPath == null ? '' : '\n![screenshot]($assetPath)\n'}
''';
  }

  Future<String> createMonitoringRecord(
    MonitorRecord record,
    String dailyDocumentId, {
    String? assetPath,
  }) async {
    final response = await _post('/api/block/appendBlock', {
      'dataType': 'markdown',
      'data': monitoringMarkdown(record, assetPath: assetPath),
      'parentID': dailyDocumentId,
    });
    final data = response['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map) {
        final operations = first['doOperations'];
        if (operations is List && operations.isNotEmpty) {
          final id = (operations.first as Map)['id'];
          if (id is String) return id;
        }
      }
    }
    throw const SiyuanException('SiYuan 未返回记录块 ID');
  }

  Future<void> updateMonitoringRecord(String blockId, String markdown) async {
    await _post('/api/block/updateBlock', {
      'dataType': 'markdown',
      'data': markdown,
      'id': blockId,
    });
  }

  Future<Map<String, dynamic>> _post(String path, Object data) async {
    try {
      final response = await _dio.post<Object>(path, data: data);
      if (response.data is! Map) throw const SiyuanException('SiYuan 响应格式无效');
      final body = Map<String, dynamic>.from(response.data! as Map);
      if (body['code'] != 0) {
        throw SiyuanException('${body['msg'] ?? 'SiYuan API 请求失败'}');
      }
      return body;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw const SiyuanException('SiYuan Token 无效或没有权限（HTTP 401）');
      }
      throw SiyuanException(
        '无法连接 SiYuan${error.response?.statusCode == null ? '' : '（HTTP ${error.response?.statusCode}）'}',
      );
    }
  }
}

class _TargetDocument {
  const _TargetDocument({required this.hpath});
  final String hpath;
}

String? selectExistingDocumentId(Object? data) {
  if (data is! List) return null;
  final ids =
      data
          .whereType<String>()
          .where((id) => RegExp(r'^\d{14}-[a-z0-9]{7}$').hasMatch(id))
          .toList()
        ..sort();
  return ids.isEmpty ? null : ids.first;
}
