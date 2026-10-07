import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../config/supervisor_config.dart';

class MimoException implements Exception {
  const MimoException(this.message);
  final String message;

  @override
  String toString() => message;
}

class MimoAnalysis {
  const MimoAnalysis({
    required this.characterName,
    required this.promptText,
    required this.taskNumber,
    required this.action,
    required this.confidence,
    required this.rawResponse,
  });

  final String characterName;
  final String promptText;
  final String taskNumber;
  final String action;
  final double confidence;
  final String rawResponse;

  factory MimoAnalysis.degraded(Object error) => MimoAnalysis(
    characterName: '未识别',
    promptText: '未识别到绿色提示',
    taskNumber: '',
    action: '状态检查',
    confidence: 0,
    rawResponse: 'MiMo 连续失败，已降级：$error',
  );

  factory MimoAnalysis.fromResponse(String response) {
    final start = response.indexOf('{');
    final end = response.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const MimoException('MiMo 没有返回可解析的 JSON');
    }
    try {
      final json = jsonDecode(response.substring(start, end + 1));
      if (json is! Map) throw const FormatException();
      String value(String key, String fallback) {
        final result = json[key]?.toString().trim();
        return result == null || result.isEmpty ? fallback : result;
      }

      return MimoAnalysis(
        characterName: value('characterName', '未识别'),
        promptText: value('promptText', '未识别到绿色提示'),
        taskNumber: value('taskNumber', ''),
        action: value('action', '状态检查'),
        confidence: ((json['confidence'] as num?)?.toDouble() ?? 0)
            .clamp(0, 1)
            .toDouble(),
        rawResponse: response,
      );
    } catch (_) {
      throw const MimoException('MiMo 返回的识别结果格式无效');
    }
  }
}

class MimoService {
  MimoService(SupervisorConfig config)
    : _model = config.mimoModel.trim(),
      _dio = Dio(
        BaseOptions(
          baseUrl: config.mimoBaseUrl.trim().replaceFirst(RegExp(r'/$'), ''),
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 90),
          headers: {
            'Authorization': 'Bearer ${config.mimoApiKey.trim()}',
            'Content-Type': 'application/json',
          },
        ),
      );

  final Dio _dio;
  final String _model;

  Future<MimoAnalysis> analyzeScreenshot(String screenshotPath) async {
    final file = File(screenshotPath);
    if (!await file.exists()) throw const MimoException('待识别截图不存在');
    final image = base64Encode(await file.readAsBytes());
    try {
      final response = await _dio.post<Object>(
        '/chat/completions',
        data: {
          'model': _model,
          'temperature': 0,
          'max_tokens': 512,
          'enable_thinking': false,
          'messages': [
            {
              'role': 'system',
              'content': '你是游戏监控截图识别器。只读取指定区域，不推测看不清的文字；必须仅返回一个 JSON 对象。',
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': '''识别这张《冒险岛：枫之传说》横屏截图：
1. characterName：优先读取左上角角色状态区域中的角色名称；如果该处被战斗特效遮挡，再依次检查左侧队伍列表中的高亮角色、画面中玩家角色头顶名称。忽略等级、职业、聊天文字和任务名称；多个候选不一致时以左上角为准。
2. promptText：逐字读取画面顶部偏左的绿色系统提示全文；若多行，合并为一行。
3. taskNumber：只提取绿色提示中“编号”后面的值，不要包含“编号”二字；没有则返回空字符串。
4. action：从绿色提示概括当前开始执行的操作，尽量使用原文，例如“开始执行xxx”；无法确认则写“状态检查”。
5. confidence：0 到 1 的识别置信度。
只返回：{"characterName":"...","promptText":"...","taskNumber":"...","action":"...","confidence":0.0}''',
                },
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,$image'},
                },
              ],
            },
          ],
        },
      );
      final body = response.data;
      if (body is! Map || body['choices'] is! List) {
        throw const MimoException('MiMo 响应格式无效');
      }
      final choices = body['choices'] as List;
      if (choices.isEmpty || choices.first is! Map) {
        throw const MimoException('MiMo 未返回识别结果');
      }
      final message = (choices.first as Map)['message'];
      if (message is! Map) throw const MimoException('MiMo 响应缺少消息');
      final content = message['content'];
      final text = switch (content) {
        String value => value,
        List values =>
          values
              .whereType<Map>()
              .map((part) => part['text']?.toString() ?? '')
              .join(),
        _ => '',
      };
      if (text.trim().isEmpty) throw const MimoException('MiMo 返回了空结果');
      return MimoAnalysis.fromResponse(text);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final detail = error.response?.data?.toString();
      throw MimoException(
        'MiMo 请求失败${status == null ? '' : '（HTTP $status）'}'
        '${detail == null ? '' : '：$detail'}',
      );
    }
  }
}
