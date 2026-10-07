import 'dart:developer' as developer;

void logEvent(String event, [Map<String, Object?> fields = const {}]) {
  final details = fields.entries
      .where((entry) => entry.key.toLowerCase() != 'token')
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  developer.log(
    details.isEmpty ? event : '$event $details',
    name: 'MapSupervisor',
  );
}
