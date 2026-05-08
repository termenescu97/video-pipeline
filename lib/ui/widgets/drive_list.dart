import 'package:flutter/material.dart';

import '../../services/drive_service.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

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
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.sd_storage_outlined,
                  size: 48, color: Colors.grey),
              const SizedBox(height: Insets.s),
              const Text('No removable drives detected'),
              Text(
                'Insert SD cards and refresh',
                style: AppTextStyles.caption.copyWith(color: Colors.grey),
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
                ? Icon(Icons.check_circle,
                    color: Theme.of(context).extension<StatusColors>()!.success)
                : null,
            onTap: () => onDriveSelected?.call(drive),
          ),
        );
      }).toList(),
    );
  }
}
