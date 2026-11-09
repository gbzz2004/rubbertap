import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart';
import 'rain_alerts.dart';

import 'screens/dashboard_screen.dart';
import 'screens/production_log_screen.dart';
import 'screens/gis_screen.dart';
import 'screens/forecast_screen.dart';
import 'screens/weather_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://aettvojcgrpqrvwlrure.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFldHR2b2pjZ3JwcXJ2d2xydXJlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg3NTM2MjUsImV4cCI6MjEwNDMyOTYyNX0.0xI3C-f0QU83ZYO0X9vqB2-cXP88GZAX1qcfCr2HVkY',
  );

  // Rain alerts must never stop the app from starting
  try {
    await RainAlertService.init();
    if (await RainAlertService.isEnabled()) {
      await RainAlertService.startBackgroundChecks();
    }
  } catch (_) {}

  runApp(const RubberTapApp());
}

final supabase = Supabase.instance.client;

class RubberTapApp extends StatelessWidget {
  const RubberTapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RubberTap',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const DashboardScreen(),
    const ProductionLogScreen(),
    const GisScreen(),
    const ForecastScreen(),
    const WeatherScreen(),
  ];

  final List<NavigationDestination> _destinations = const [
    NavigationDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: 'Dashboard',
    ),
    NavigationDestination(
      icon: Icon(Icons.edit_note_outlined),
      selectedIcon: Icon(Icons.edit_note),
      label: 'Production',
    ),
    NavigationDestination(
      icon: Icon(Icons.map_outlined),
      selectedIcon: Icon(Icons.map),
      label: 'GIS Map',
    ),
    NavigationDestination(
      icon: Icon(Icons.auto_graph_outlined),
      selectedIcon: Icon(Icons.auto_graph),
      label: 'Forecast',
    ),
    NavigationDestination(
      icon: Icon(Icons.wb_sunny_outlined),
      selectedIcon: Icon(Icons.wb_sunny),
      label: 'Weather',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _screens[_currentIndex],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFF2E7D32).withValues(alpha: 0.1),
        destinations: _destinations,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }
}