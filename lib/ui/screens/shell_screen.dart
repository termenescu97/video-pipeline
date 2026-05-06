import 'package:flutter/material.dart';

import 'create_job_screen.dart';
import 'job_detail_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// Master-detail shell: queue list on the left, detail/create on the right.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int? _selectedJobId;
  bool _showCreateJob = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video Pipeline'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          // Left panel: queue list.
          SizedBox(
            width: 360,
            child: HomeScreen(
              onJobSelected: (jobId) {
                setState(() {
                  _selectedJobId = jobId;
                  _showCreateJob = false;
                });
              },
              onCreateJob: () {
                setState(() {
                  _selectedJobId = null;
                  _showCreateJob = true;
                });
              },
            ),
          ),
          const VerticalDivider(width: 1),
          // Right panel: detail or create.
          Expanded(
            child: _buildRightPanel(),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPanel() {
    if (_showCreateJob) {
      return CreateJobScreen(
        onJobCreated: () {
          setState(() => _showCreateJob = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Job added to queue')),
          );
        },
      );
    }

    if (_selectedJobId != null) {
      return JobDetailScreen(
        key: ValueKey(_selectedJobId),
        jobId: _selectedJobId!,
      );
    }

    // Empty state.
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app, size: 48, color: Colors.grey),
          SizedBox(height: 16),
          Text('Select a job or create a new one',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
