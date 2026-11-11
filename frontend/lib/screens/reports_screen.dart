import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  final List<Map<String, dynamic>> _reports = const [
    {
      'title': 'Monthly Production Report',
      'description': 'Yield summary for August 2026',
      'icon': Icons.calendar_month,
      'color': Color(0xFF1565C0),
    },
    {
      'title': 'Block Performance Report',
      'description': 'Compare yield across all blocks',
      'icon': Icons.bar_chart,
      'color': Color(0xFF6A1B9A),
    },
    {
      'title': 'Forecast vs Actual',
      'description': 'Model accuracy comparison',
      'icon': Icons.compare_arrows,
      'color': Color(0xFF00695C),
    },
    {
      'title': 'Anomaly Report',
      'description': 'Underperforming blocks detected',
      'icon': Icons.warning_amber,
      'color': Color(0xFFE65100),
    },
    {
      'title': 'Export CSV',
      'description': 'Download all production data',
      'icon': Icons.download,
      'color': Color(0xFF2E7D32),
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _reports.length,
        itemBuilder: (context, index) {
          final report = _reports[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (report['color'] as Color).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  report['icon'] as IconData,
                  color: report['color'] as Color,
                ),
              ),
              title: Text(
                report['title'],
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(report['description']),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('${report['title']} — coming soon!'),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}