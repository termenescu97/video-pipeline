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
  /// Run a PowerShell command safely. Returns null if PowerShell is
  /// unavailable, throws an unexpected error, or exits non-zero.
  Future<ProcessResult?> _runPowerShell(List<String> args) async {
    try {
      final result = await Process.run('powershell', ['-NoProfile', ...args]);
      if (result.exitCode != 0) return null;
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Get all currently mounted removable drives.
  Future<List<DetectedDrive>> getRemovableDrives() async {
    if (!Platform.isWindows) return [];
    return _getWindowsDrives();
  }

  Future<List<DetectedDrive>> _getWindowsDrives() async {
    final result = await _runPowerShell([
      '-Command',
      r"Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 } | "
          r"Select-Object DeviceID, VolumeName, Size, FreeSpace | "
          r"ConvertTo-Json -Compress",
    ]);

    if (result == null) return [];

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
    final result = await _runPowerShell([
      '-Command',
      r'Get-PSDrive -Name $args[0] | Select-Object -ExpandProperty Free',
      driveLetter,
    ]);

    if (result == null) return -1;
    return int.tryParse(result.stdout.toString().trim()) ?? -1;
  }

  /// Get drive identity info for verification before erase.
  ///
  /// Returns label, total size, and physical disk serial number (when
  /// available). Serial number is the strongest physical identifier and is
  /// used to detect card swaps during a confirmation dialog.
  Future<({String label, int totalBytes, String? serialNumber})?>
      getDriveIdentity(String drivePath) async {
    if (!Platform.isWindows) return null;

    // Take "E:" from "E:\\" — matches Win32_LogicalDisk.DeviceID.
    final deviceId = drivePath.substring(0, 2);

    final result = await _runPowerShell([
      '-Command',
      // Trace the WMI association chain: LogicalDisk -> Partition -> DiskDrive
      // to get the physical disk's SerialNumber. SerialNumber is null on
      // some card readers; callers must handle that case.
      r'''
$drive = $args[0]
$logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = '$drive'"
if (-not $logical) { return }
$partition = $logical | Get-CimAssociatedInstance -Association Win32_LogicalDiskToPartition | Select-Object -First 1
$disk = if ($partition) { $partition | Get-CimAssociatedInstance -Association Win32_DiskDriveToDiskPartition | Select-Object -First 1 } else { $null }
@{
  VolumeName = $logical.VolumeName
  Size = $logical.Size
  SerialNumber = if ($disk) { $disk.SerialNumber } else { $null }
} | ConvertTo-Json -Compress
''',
      deviceId,
    ]);

    if (result == null) return null;
    final output = result.stdout.toString().trim();
    if (output.isEmpty || output == 'null') return null;

    try {
      final data = jsonDecode(output);
      final rawSerial = data['SerialNumber'] as String?;
      final serial = rawSerial?.trim();
      return (
        label: (data['VolumeName'] as String?) ?? 'Unknown',
        totalBytes: (data['Size'] as num?)?.toInt() ?? 0,
        serialNumber: (serial == null || serial.isEmpty) ? null : serial,
      );
    } catch (_) {
      return null;
    }
  }

  /// Erase all files on a drive. Requires explicit confirmation before calling.
  Future<bool> eraseDrive(String drivePath) async {
    if (!Platform.isWindows) return false;

    // Validate drive path even though we now pass it via $args[0] —
    // belt-and-suspenders against accidentally erasing a non-drive path.
    if (!RegExp(r'^[A-Za-z]:\\$').hasMatch(drivePath)) return false;

    // Pass the drive path as $args[0] (PowerShell positional arg) and use
    // -LiteralPath so the value is treated as a literal string, never as
    // a glob pattern. Enumerate children with -Force (include hidden /
    // system files like volume metadata) and delete recursively.
    final result = await _runPowerShell([
      '-Command',
      r'Get-ChildItem -LiteralPath $args[0] -Force | Remove-Item -Recurse -Force',
      drivePath,
    ]);

    return result != null;
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
