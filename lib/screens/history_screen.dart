import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/monitor_record.dart';
import '../repositories/monitor_repository.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({required this.repository, super.key});
  final MonitorRepository repository;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<MonitorRecord>> _records;
  @override
  void initState() {
    super.initState();
    _records = widget.repository.history();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('监控历史')),
    body: FutureBuilder<List<MonitorRecord>>(
      future: _records,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final records = snapshot.data!;
        if (records.isEmpty) return const Center(child: Text('暂无监控记录'));
        return RefreshIndicator(
          onRefresh: () async {
            setState(() => _records = widget.repository.history());
            await _records;
          },
          child: ListView.builder(
            itemCount: records.length,
            itemBuilder: (context, index) {
              final record = records[index];
              return ListTile(
                title: Text(
                  DateFormat('MM-dd HH:mm:ss').format(record.timestamp),
                ),
                subtitle: Text(
                  'Capture ${_mark(record.captureStatus == CaptureStatus.success)}  Sync ${_mark(record.syncStatus == SyncStatus.success)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _RecordDetail(record: record),
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  );

  String _mark(bool success) => success ? '✓' : '✗';
}

class _RecordDetail extends StatelessWidget {
  const _RecordDetail({required this.record});
  final MonitorRecord record;
  @override
  Widget build(BuildContext context) {
    final file = File(record.screenshotPath);
    return Scaffold(
      appBar: AppBar(title: const Text('记录详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (file.existsSync()) Image.file(file),
          const SizedBox(height: 16),
          SelectableText('时间：${record.timestamp.toIso8601String()}'),
          SelectableText('截图状态：${record.captureStatus.name}'),
          SelectableText('同步状态：${record.syncStatus.name}'),
          SelectableText('分析状态：${record.analysisStatus.name}'),
          SelectableText('识别角色：${record.recognizedCharacter ?? '—'}'),
          SelectableText('绿色提示：${record.promptText ?? '—'}'),
          SelectableText('任务编号：${record.taskNumber ?? '—'}'),
          SelectableText('执行内容：${record.taskAction ?? '—'}'),
          SelectableText(
            '识别置信度：${record.analysisConfidence == null ? '—' : '${(record.analysisConfidence! * 100).toStringAsFixed(0)}%'}',
          ),
          SelectableText('SiYuan Block ID：${record.siyuanBlockId ?? '—'}'),
          SelectableText('错误：${record.errorMessage ?? '—'}'),
          const SizedBox(height: 16),
          SelectableText(record.metadataJson()),
        ],
      ),
    );
  }
}
