import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/format_utils.dart';

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
  String get displaySize => '${formatBytes(usedBytes)} / ${formatBytes(totalBytes)}';
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
  /// Returns found files and any paths that were skipped due to errors.
  Future<({List<FileSystemEntity> files, List<String> skippedPaths})>
      listVideoFiles(String drivePath) async {
    final dir = Directory(drivePath);
    if (!await dir.exists()) {
      return (files: <FileSystemEntity>[], skippedPaths: <String>[]);
    }

    final files = <FileSystemEntity>[];
    final skippedPaths = <String>[];
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (videoExtensions.contains(ext)) {
            files.add(entity);
          }
        }
      }
    } on FileSystemException catch (e) {
      skippedPaths.add(e.path ?? drivePath);
    }
    return (files: files, skippedPaths: skippedPaths);
  }

  /// Get free space in bytes for a given path's drive.
  Future<int> getDiskFreeSpace(String dirPath) async {
    if (!Platform.isWindows) return -1;

    final driveLetter = dirPath.substring(0, 1);
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-PSDrive -Name $driveLetter | Select-Object -ExpandProperty Free',
    ]);

    if (result.exitCode != 0) return -1;
    return int.tryParse(result.stdout.toString().trim()) ?? -1;
  }

  /// Get drive identity info for verification before erase.
  Future<({String label, int totalBytes})?> getDriveIdentity(
      String drivePath) async {
    if (!Platform.isWindows) return null;

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r"Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DeviceID -eq '"
          "${drivePath.substring(0, 2)}"
          r"' } | Select-Object VolumeName, Size | ConvertTo-Json -Compress",
    ]);

    if (result.exitCode != 0) return null;
    final output = result.stdout.toString().trim();
    if (output.isEmpty || output == 'null') return null;

    try {
      final data = jsonDecode(output);
      return (
        label: (data['VolumeName'] as String?) ?? 'Unknown',
        totalBytes: (data['Size'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Erase all files on a drive. Requires explicit confirmation before calling.
  Future<bool> eraseDrive(String drivePath) async {
    if (!Platform.isWindows) return false;

    // Validate drive path to prevent command injection.
    if (!RegExp(r'^[A-Za-z]:\\$').hasMatch(drivePath)) return false;

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Remove-Item -Path "$drivePath*" -Recurse -Force',
    ]);

    return result.exitCode == 0;
  }

  /// Prep test cards by copying test video files to DCIM/100TEST/ on each drive.
  Future<({int cardsPrepped, int filesCopied, List<String> errors})>
      prepTestCards(String sourceFolder, List<DetectedDrive> drives) async {
    // Find video files in source folder.
    final sourceDir = Directory(sourceFolder);
    if (!await sourceDir.exists()) {
      return (cardsPrepped: 0, filesCopied: 0, errors: ['Source folder not found: $sourceFolder']);
    }

    final testFiles = <File>[];
    await for (final entity in sourceDir.list(recursive: true)) {
      if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (videoExtensions.contains(ext)) {
          testFiles.add(entity);
        }
      }
    }

    var cardsPrepped = 0;
    var filesCopied = 0;
    final errors = <String>[];

    for (final drive in drives) {
      try {
        final testDir = Directory(p.join(drive.path, 'DCIM', '100TEST'));

        // Clean existing test folder.
        if (await testDir.exists()) {
          await testDir.delete(recursive: true);
        }
        await testDir.create(recursive: true);

        // Copy test files.
        for (final file in testFiles) {
          final destPath = p.join(testDir.path, p.basename(file.path));
          await file.copy(destPath);
          filesCopied++;
        }
        cardsPrepped++;
      } catch (e) {
        errors.add('${drive.label} (${drive.path}): $e');
      }
    }

    return (cardsPrepped: cardsPrepped, filesCopied: filesCopied, errors: errors);
  }
}
