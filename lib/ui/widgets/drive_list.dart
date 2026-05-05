import 'package:flutter/material.dart';

import '../../services/drive_service.dart';

/// Displays a list of detected removable drives with selection support.
class DriveList extends StatelessWidget {
  final List<DetectedDrive> drives;
  final String? selectedDrivePath;
  final ValueChanged<DetectedDrive>? onDriveSelected;

  const DriveList({
    super.key,
    required this.drives,
    this.selectedDrivePath,
    this.onDriveSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (drives.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.sd_storage_outlined, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('No removable drives detected'),
              Text(
                'Insert SD cards and refresh',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: drives.map((drive) {
        final isSelected = drive.path == selectedDrivePath;
        return Card(
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: ListTile(
            leading: const Icon(Icons.sd_storage),
            title: Text(drive.label),
            subtitle: Text('${drive.path} — ${drive.displaySize}'),
            trailing: isSelected
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
            onTap: () => onDriveSelected?.call(drive),
          ),
        );
      }).toList(),
    );
  }
}
