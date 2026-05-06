import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/constants.dart';

/// Represents a detected removable storage device.
class DetectedDrive {
  final String path;
  final String label;
  final int totalBytes;
  final int usedBytes;

  DetectedDrive({
    required this.path,
    required this.label,
    required this.totalBytes,
    required this.usedBytes,
  });

  int get freeBytes => totalBytes - usedBytes;
  String get displaySize =>
      '${(usedBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} / '
      '${(totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Detects removable storage devices (SD cards) on Windows.
///
/// On non-Windows platforms, returns an empty list (development fallback).
class DriveService {
  /// Get all currently mounted removable drives.
  Future<List<DetectedDrive>> getRemovableDrives() async {
    if (!Platform.isWindows) return [];
    return _getWindowsDrives();
  }

  Future<List<DetectedDrive>> _getWindowsDrives() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r"Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 } | "
          r"Select-Object DeviceID, VolumeName, Size, FreeSpace | "
          r"ConvertTo-Json -Compress",
    ]);

    if (result.exitCode != 0) return [];

    final output = result.stdout.toString().trim();
    if (output.isEmpty || output == 'null') return [];

    final dynamic parsed;
    try {
      parsed = jsonDecode(output);
    } catch (_) {
      return [];
    }

    // Handle single drive (object) vs multiple drives (array).
    final List<dynamic> drives = parsed is List ? parsed : [parsed];

    return drives.map((d) {
      final size = (d['Size'] as num?)?.toInt() ?? 0;
      final free = (d['FreeSpace'] as num?)?.toInt() ?? 0;
      return DetectedDrive(
        path: '${d['DeviceID']}\\',
        label: (d['VolumeName'] as String?) ?? 'Removable Disk',
        totalBytes: size,
        usedBytes: size - free,
      );
    }).toList();
  }

  /// List video files (.mov, .mp4) on a drive.
  Future<List<FileSystemEntity>> listVideoFiles(String drivePath) async {
    final dir = Directory(drivePath);
    if (!await dir.exists()) return [];

    final files = <FileSystemEntity>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (videoExtensions.contains(ext)) {
          files.add(entity);
        }
      }
    }
    return files;
  }

  /// Erase all files on a drive. Requires explicit confirmation before calling.
  Future<bool> eraseDrive(String drivePath) async {
    if (!Platform.isWindows) return false;

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Remove-Item -Path "$drivePath*" -Recurse -Force',
    ]);

    return result.exitCode == 0;
  }
}
