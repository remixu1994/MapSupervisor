import 'package:intl/intl.dart';

String safeFileComponent(String input) {
  final cleaned = input
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  return cleaned.isEmpty ? 'unknown' : cleaned;
}

String screenshotFileName(DateTime timestamp, String character) =>
    '${DateFormat('yyyyMMdd_HHmmss').format(timestamp)}_'
    '${safeFileComponent(character)}.png';

String dailyDocumentName(DateTime timestamp) =>
    DateFormat('yyyy-MM-dd').format(timestamp);
