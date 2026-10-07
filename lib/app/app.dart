import 'package:flutter/material.dart';

import '../repositories/monitor_repository.dart';
import '../screens/home_screen.dart';
import '../services/monitoring_service.dart';

class MapSupervisorApp extends StatefulWidget {
  const MapSupervisorApp({super.key});
  @override
  State<MapSupervisorApp> createState() => _MapSupervisorAppState();
}

class _MapSupervisorAppState extends State<MapSupervisorApp> {
  late final MonitorRepository repository;
  late final MonitoringService monitoringService;

  @override
  void initState() {
    super.initState();
    repository = MonitorRepository();
    monitoringService = MonitoringService(repository);
  }

  @override
  void dispose() {
    monitoringService.dispose();
    repository.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MapSupervisor',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315da8)),
      useMaterial3: true,
    ),
    home: HomeScreen(
      repository: repository,
      monitoringService: monitoringService,
    ),
  );
}
