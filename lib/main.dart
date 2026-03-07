import 'package:flutter/material.dart';
import 'dashboard_page.dart';

void main() {
  runApp(const PowerMonitorApp());
}

class PowerMonitorApp extends StatelessWidget {
  const PowerMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Power Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DashboardPage(),
    );
  }
}
