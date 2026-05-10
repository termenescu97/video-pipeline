import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../utils/constants.dart';
import '../utils/format_utils.dart';
import '../utils/ps_escape.dart';
import 'log_service.dart';

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
  /// Optional logger for PowerShell helper failures (final-review fix
  /// #8). Without it, every disk identity / free-space / erase /
  /// prep-cards probe that fails collapses silently to `null`.
  final LogService? _logService;

  DriveService({LogService? logService}) : _logService = logService;

  /// Run a PowerShell command safely. Returns null if PowerShell is
  /// unavailable, throws an unexpected error, or exits non-zero.
  ///
  /// [tag] is a short label written to the log on failure so post-mortem
  /// can tell which call site failed (identity vs free-space vs erase).
  /// 019 T032 (FR-020, US8): runtime length-3 argv invariant guard.
  /// Codex round-27a P2 fix: Dart `assert` is stripped from
  /// `flutter build windows --release`, so a debug-only assert
  /// provides zero production protection. Use `if (...) throw` so the
  /// check fires in release builds too.
  ///
  /// The invariant: every PS subprocess call MUST pass exactly
  /// `['-NoProfile', '-Command', script]` to PowerShell. The 017A
  /// length-3 argv root cause was that `-Command` silently drops
  /// trailing argv elements; `$args[0]` was never populated, so
  /// operator-supplied paths were dropped on the floor. Re-opening
  /// this hole at any helper site re-creates the v2.4.0 cascade.
  ///
  /// Extracted as a standalone `@visibleForTesting` function so unit
  /// tests can verify the throw fires without spawning a real
  /// PowerShell subprocess.
  @visibleForTesting
  static void checkPsArgvShape(List<String> args, String tag) =>
      _checkPsArgvShape(args, tag);

  static void _checkPsArgvShape(List<String> args, String tag) {
    if (args.length != 2 || args[0] != '-Command') {
      throw StateError(
        'PS argv invariant violated in $tag: args after -NoProfile must be '
        "exactly ['-Command', script]. Got: $args. See 017A length-3 argv "
        'invariant in CLAUDE.md.',
      );
    }
  }

  Future<ProcessResult?> _runPowerShell(
    List<String> args, {
    required String tag,
  }) async {
    // Codex round-27a P2 fix: Dart `assert` is stripped from
    // `flutter build windows --release`, so a debug-only assert
    // provides zero production protection. Use `if (...) throw` so the
    // check fires in release builds too.
    //
    // The invariant: every PS subprocess call MUST pass exactly
    // `['-NoProfile', '-Command', script]` to PowerShell. The 017A
    // length-3 argv root cause was that `-Command` silently drops
    // trailing argv elements; `$args[0]` was never populated, so
    // operator-supplied paths were dropped on the floor. Re-opening
    // this hole at any helper site re-creates the v2.4.0 cascade.
    _checkPsArgvShape(args, tag);
    try {
      final result = await Process.run('powershell', ['-NoProfile', ...args]);
      if (result.exitCode != 0) {
        // Final-review fix #8: write a log line for every non-zero
        // PowerShell exit so erase / identity / disk probes that fail
        // leave a paper trail. The stderr field is captured by
        // Process.run; first 200 chars give us the cause without
        // dumping a screenful.
        final stderr = result.stderr.toString().trim();
        _logService?.error(
          'PowerShell helper "$tag" exit=${result.exitCode}'
          '${stderr.isEmpty ? '' : ' — stderr: ${stderr.substring(0, stderr.length.clamp(0, 200))}'}',
        );
        return null;
      }
      return result;
    } catch (e, st) {
      _logService?.error(
        'PowerShell helper "$tag" threw: $e\n'
        '${st.toString().split('\n').take(3).join('\n')}',
      );
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
    ], tag: 'getRemovableDrives');

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
  ///
  /// 017 (FR-013): path-shape validation upfront. Returns -1 (sentinel) on:
  ///   - empty path (programmer error upstream),
  ///   - UNC path (`\\nas01\share\...`) — surfaces a warning, no UNC
  ///     support in v2.5; v3.0 NAS feature adds Win32 GetDiskFreeSpaceEx,
  ///   - malformed drive-letter prefix (must match `^[A-Za-z]:`).
  ///
  /// Long-path warning (>260 chars): logged once at preflight; does NOT
  /// block the caller's job creation.
  Future<int> getDiskFreeSpace(String dirPath) async {
    if (!Platform.isWindows) return -1;
    if (dirPath.isEmpty) {
      _logService?.warning(
        'getDiskFreeSpace called with empty path — caller bug; returning -1',
      );
      return -1;
    }
    if (dirPath.startsWith(r'\\')) {
      _logService?.warning(
        'free space check skipped for UNC path "$dirPath"; '
        'v3.0 NAS feature adds support',
      );
      return -1;
    }
    if (dirPath.length > 260) {
      _logService?.warning(
        'path exceeds Windows MAX_PATH (260 chars) — PS 5.1 may fail '
        'without \\\\?\\ prefix: "$dirPath" (${dirPath.length} chars)',
      );
      // continue — only a warning, not a hard fail
    }
    if (!RegExp(r'^[A-Za-z]:').hasMatch(dirPath)) {
      _logService?.warning(
        'getDiskFreeSpace: path "$dirPath" does not start with a valid '
        'drive letter (e.g. E:); returning -1',
      );
      return -1;
    }

    final driveLetter = dirPath[0]; // validated single ASCII letter
    final result = await _runPowerShell([
      '-Command',
      // 017 (R-A1): drive letter is guaranteed [A-Za-z]; safe to inline.
      // No trailing-argv positional pattern — that was the v2.4.0 root cause.
      'Get-PSDrive -Name $driveLetter | Select-Object -ExpandProperty Free',
    ], tag: 'getDiskFreeSpace($driveLetter)');

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
    if (drivePath.length < 2) return null;
    final deviceId = drivePath.substring(0, 2);
    if (!RegExp(r'^[A-Za-z]:$').hasMatch(deviceId)) return null;

    // 017 (R-A1): inline the validated DeviceID via single-quoted literal +
    // escapePsLiteral (defense-in-depth — deviceId is already regex-validated
    // to ASCII alpha + ':' so it cannot contain '). No trailing-argv pattern.
    final escapedDevice = escapePsLiteral(deviceId);
    final result = await _runPowerShell([
      '-Command',
      // Trace the WMI association chain: LogicalDisk -> Partition -> DiskDrive
      // to get the physical disk's SerialNumber. SerialNumber is null on
      // some card readers; callers must handle that case.
      '''
\$logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = '$escapedDevice'"
if (-not \$logical) { return }
\$partition = \$logical | Get-CimAssociatedInstance -Association Win32_LogicalDiskToPartition | Select-Object -First 1
\$disk = if (\$partition) { \$partition | Get-CimAssociatedInstance -Association Win32_DiskDriveToDiskPartition | Select-Object -First 1 } else { \$null }
@{
  VolumeName = \$logical.VolumeName
  Size = \$logical.Size
  SerialNumber = if (\$disk) { \$disk.SerialNumber } else { \$null }
} | ConvertTo-Json -Compress
''',
    ], tag: 'getDriveIdentity($deviceId)');

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

    // Validate drive path tightly — belt-and-suspenders against
    // accidentally erasing a non-drive path. Regex matches `X:\` shape.
    if (!RegExp(r'^[A-Za-z]:\\$').hasMatch(drivePath)) return false;

    // 017 (R-A1): inline the validated drive path via single-quoted
    // -LiteralPath. Even though the regex above guarantees no apostrophes,
    // escapePsLiteral is defense-in-depth (in case validation ever loosens).
    final result = await _runPowerShell([
      '-Command',
      "Get-ChildItem -LiteralPath '${escapePsLiteral(drivePath)}' -Force | Remove-Item -Recurse -Force",
    ], tag: 'eraseDrive($drivePath)');

    return result != null;
  }

  /// Prep test cards by copying test video files to DCIM/100TEST/ on
  /// each drive.
  ///
  /// [expectedSerials] is a `path → serial` map captured at typed-
  /// confirmation time. Before deleting `DCIM/100TEST` on a card, the
  /// drive's current SerialNumber is fetched and compared against
  /// the expected one (final-review fix #10). If the serial changed
  /// (card swap mid-confirm) or cannot be re-read, the card is
  /// skipped with an explanatory error — same identity-gate the
  /// erase flow uses. A `null` expected serial means "could not read
  /// at confirm time" and disables the gate for that card; pass an
  /// empty map to skip the gate entirely (back-compat).
  Future<({int cardsPrepped, int filesCopied, List<String> errors})>
      prepTestCards(
    String sourceFolder,
    List<DetectedDrive> drives, {
    Map<String, String?> expectedSerials = const {},
  }) async {
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
        // Final-review fix #10: re-verify card identity before any
        // destructive action. If we recorded a serial at confirm time
        // and it doesn't match now, refuse to prep — the operator may
        // have swapped this slot's card between confirming and the
        // file picker returning. Mirrors the eraseDrive serial gate.
        final expected = expectedSerials[drive.path];
        if (expected != null) {
          final current = await getDriveIdentity(drive.path);
          if (current == null || current.serialNumber == null) {
            errors.add(
              '${drive.label} (${drive.path}): could not re-read drive '
              'identity — skipping (was the card removed?)',
            );
            continue;
          }
          if (current.serialNumber != expected) {
            errors.add(
              '${drive.label} (${drive.path}): drive serial changed '
              'since confirmation — skipping (card swap detected)',
            );
            _logService?.warning(
              'prepTestCards aborted for ${drive.path}: '
              'expected serial $expected, found ${current.serialNumber}',
            );
            continue;
          }
        }

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
