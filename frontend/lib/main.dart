import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme.dart';
import 'settings_store.dart';
import 'rain_alerts.dart';
import 'update_check.dart';

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
    await RainAlertService.syncBackgroundChecks();
  } catch (_) {}

  // Saved settings (Dark mode), before the first screen is drawn
  await AppPrefs.load();

  runApp(const RubberTapApp());
}

final supabase = Supabase.instance.client;

class RubberTapApp extends StatelessWidget {
  const RubberTapApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The colours are plain values, not theme lookups, so when Dark mode
    // changes the theme is rebuilt and the screens are created again (the
    // key below). The open tab is remembered across that.
    return ValueListenableBuilder<bool>(
      valueListenable: AppPrefs.darkMode,
      builder: (context, dark, _) {
        AppColors.dark = dark;
        return MaterialApp(
          title: 'RubberTap',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: MainScreen(key: ValueKey<bool>(dark)),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // Static: kept when the screens are rebuilt for a Dark mode change
  static int _currentIndex = 0;
  static bool _startChecksDone = false;

  @override
  void initState() {
    super.initState();
    if (_startChecksDone) return; // once per app start, not per rebuild
    _startChecksDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // First start only: Android's own "Allow notifications?" prompt.
      // Rain alerts follow that choice (changed later in phone Settings).
      try {
        await RainAlertService.askOnceAndSync();
      } catch (_) {}
      // Once per app start: offer a newer version if one has been published
      if (mounted) checkForUpdate(context);
    });
  }

  final List<Widget> _screens = [
    const DashboardScreen(),
    const ProductionLogScreen(),
    const GisScreen(),
    const ForecastScreen(),
    const WeatherScreen(),
  ];

  final List<NavigationDestination> _destinations = [
    const NavigationDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: 'Dashboard',
    ),
    const NavigationDestination(
      icon: Icon(Icons.edit_note_outlined),
      selectedIcon: Icon(Icons.edit_note),
      label: 'Production',
    ),
    const NavigationDestination(
      icon: Icon(Icons.map_outlined),
      selectedIcon: Icon(Icons.map),
      label: 'GIS Map',
    ),
    const NavigationDestination(
      icon: Icon(Icons.auto_graph_outlined),
      selectedIcon: Icon(Icons.auto_graph),
      label: 'Forecast',
    ),
    const NavigationDestination(
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
        // Unchanged in light mode; dark mode needs a dark bar
        backgroundColor: AppColors.dark ? AppColors.surface : Colors.white,
        indicatorColor: AppColors.dark
            ? AppColors.forest.withValues(alpha: 0.22)
            : const Color(0xFF2E7D32).withValues(alpha: 0.1),
        destinations: _destinations,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }
}