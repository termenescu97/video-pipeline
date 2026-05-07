import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../widgets/conflict_dialog.dart';

/// Screen for creating a new job with source, destination, and options.
class CreateJobScreen extends StatefulWidget {
  /// Callback for embedded mode (ShellScreen). If null, uses Navigator.pop.
  final VoidCallback? onJobCreated;

  /// When provided, the source drive radio chip for this drive is
  /// pre-selected on first build (used when launched from SourcesPanel —
  /// FR-022).
  final DetectedDrive? preSelectedDrive;

  const CreateJobScreen({super.key, this.onJobCreated, this.preSelectedDrive});

  @override
  State<CreateJobScreen> createState() => _CreateJobScreenState();
}

class _CreateJobScreenState extends State<CreateJobScreen> {
  List<DetectedDrive> _drives = [];
  List<String> _presets = [];
  DetectedDrive? _selectedDrive;
  String? _sourcePath;
  String? _destinationPath;
  String? _compressionOutputPath;
  String? _selectedPreset;
  JobType _jobType = JobType.transfer;
  VerificationMode _verificationMode = VerificationMode.size;
  bool _loading = true;
  int? _destinationFreeSpace;
  bool _handbrakeInstalled = true;

  @override
  void initState() {
    super.initState();
    if (widget.preSelectedDrive != null) {
      _selectedDrive = widget.preSelectedDrive;
      _drives = [widget.preSelectedDrive!];
    }
    _refreshDrives();
    _loadPresets();
    _checkHandbrake();
    _loadLastUsedPaths();
  }

  Future<void> _refreshDrives() async {
    setState(() => _loading = true);
    final drives = await driveService.getRemovableDrives();
    if (!mounted) return;
    final preSelectedVanished = _selectedDrive != null &&
        widget.preSelectedDrive?.path == _selectedDrive!.path &&
        !drives.any((d) => d.path == _selectedDrive!.path);
    setState(() {
      _drives = drives;
      _loading = false;
      // If the operator pre-selected a drive that's no longer detected, drop
      // the selection so the form doesn't reference a vanished drive.
      if (_selectedDrive != null &&
          !drives.any((d) => d.path == _selectedDrive!.path)) {
        _selectedDrive = null;
      }
    });
    if (preSelectedVanished) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Pre-selected drive is no longer detected. Pick a source manually.'),
            duration: Duration(seconds: 4)),
      );
    }
  }

  Future<void> _loadPresets() async {
    final presets = await compressionService.getAvailablePresets();
    if (!mounted) return;
    setState(() => _presets = presets);
  }

  Future<void> _checkHandbrake() async {
    final installed = await compressionService.isHandbrakeInstalled();
    if (!mounted) return;
    setState(() => _handbrakeInstalled = installed);
  }

  Future<void> _loadLastUsedPaths() async {
    final settings = await settingsDao.getSettings();
    if (!mounted) return;
    if (settings != null) {
      setState(() {
        if (settings.lastUsedDestination.isNotEmpty) {
          _destinationPath = settings.lastUsedDestination;
        }
        if (settings.lastUsedOutput.isNotEmpty) {
          _compressionOutputPath = settings.lastUsedOutput;
        }
      });
    }
  }

  Future<void> _updateFreeSpace(String path) async {
    final free = await driveService.getDiskFreeSpace(path);
    if (!mounted) return;
    setState(() => _destinationFreeSpace = free > 0 ? free : null);
  }

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    return Scaffold(
      appBar: widget.onJobCreated == null
          ? AppBar(title: const Text('Create Job'))
          : null,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // HandBrake not installed banner.
            if (!_handbrakeInstalled) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: statusColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColors.warning),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber, color: statusColors.warning),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Compression requires HandBrake. '
                        'Download it at handbrake.fr. '
                        'Compression options are disabled.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Job type selector.
            Text('Job Type', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<JobType>(
              segments: const [
                ButtonSegment(
                  value: JobType.transfer,
                  label: Text('Transfer'),
                  icon: Icon(Icons.file_copy),
                ),
                ButtonSegment(
                  value: JobType.compression,
                  label: Text('Compress'),
                  icon: Icon(Icons.compress),
                ),
                ButtonSegment(
                  value: JobType.transferAndCompress,
                  label: Text('Copy & Compress'),
                  icon: Icon(Icons.sync),
                ),
              ],
              selected: {_jobType},
              onSelectionChanged: (selection) {
                setState(() => _jobType = selection.first);
              },
            ),

            const SizedBox(height: 24),

            // Source drive selection (for transfer jobs) — inline radio chips.
            if (_jobType != JobType.compression) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('From',
                      style: Theme.of(context).textTheme.titleMedium),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _refreshDrives,
                    tooltip: 'Re-scan drives',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loading && _drives.isEmpty)
                const Center(child: CircularProgressIndicator())
              else
                _buildSourceChips(),
              const SizedBox(height: 24),
            ],

            // Source folder (compression-only jobs).
            if (_jobType == JobType.compression) ...[
              Text('Input Folder',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _buildFolderPicker(
                currentPath: _sourcePath,
                favoriteType: FavoritePathType.source,
                onPathSelected: (path) {
                  setState(() => _sourcePath = path);
                },
              ),
              const SizedBox(height: 24),
            ],

            // Destination / output folder.
            Text(
              _jobType == JobType.compression ? 'Output Folder' : 'Destination',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _buildFolderPicker(
              currentPath: _destinationPath,
              favoriteType: _jobType == JobType.compression
                  ? FavoritePathType.output
                  : FavoritePathType.destination,
              onPathSelected: (path) {
                setState(() => _destinationPath = path);
                _updateFreeSpace(path);
              },
            ),
            if (_destinationFreeSpace != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _FreeSpaceSentence(
                  freeBytes: _destinationFreeSpace!,
                  // Plan summary panel (US8) feeds back the planned-bytes;
                  // for now we only have free-space without plan totals, so
                  // we render a simple "plenty/cutting close" verdict
                  // without the won't-fit case.
                  plannedBytes: null,
                ),
              ),

            const SizedBox(height: 24),

            // Compression options — collapsed by default (FR-025).
            // Only the common case (Transfer to a known destination) needs
            // to be visible; compression configuration is progressive
            // disclosure.
            if (_jobType != JobType.transfer) ...[
              ExpansionTile(
                initiallyExpanded:
                    _jobType == JobType.compression || _selectedPreset != null,
                title: const Text('Compression options'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  if (_jobType == JobType.transferAndCompress) ...[
                    Text('Compression Output',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _buildFolderPicker(
                      currentPath: _compressionOutputPath,
                      favoriteType: FavoritePathType.output,
                      onPathSelected: (path) {
                        setState(() => _compressionOutputPath = path);
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text('Compression Preset',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedPreset,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Select a HandBrake preset',
                    ),
                    items: _presets
                        .map((p) =>
                            DropdownMenuItem(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (value) {
                      setState(() => _selectedPreset = value);
                    },
                  ),
                  if (_presets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'No presets found. Check HandBrake installation.',
                        style: TextStyle(
                            color: statusColors.warning, fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],

            // Verification mode (for transfer jobs).
            if (_jobType != JobType.compression) ...[
              Text('Verification',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<VerificationMode>(
                segments: const [
                  ButtonSegment(
                    value: VerificationMode.size,
                    label: Text('Quick (size)'),
                    icon: Icon(Icons.speed),
                  ),
                  ButtonSegment(
                    value: VerificationMode.sha256,
                    label: Text('Full (SHA-256)'),
                    icon: Icon(Icons.verified_user),
                  ),
                ],
                selected: {_verificationMode},
                onSelectionChanged: (selection) {
                  setState(() => _verificationMode = selection.first);
                },
              ),
              if (_verificationMode == VerificationMode.sha256)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'SHA-256 hashing adds ~8 min per 50 GB file',
                    style: TextStyle(color: statusColors.warning, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 24),
            ],

            // Create button.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _canCreate() ? _createJob : null,
                icon: const Icon(Icons.add),
                label: const Text('Add to Queue'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceChips() {
    final scheme = Theme.of(context).colorScheme;
    if (_drives.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.sd_storage,
                size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No removable drives detected. Click "Folder…" to pick a path.',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Folder…'),
              onPressed: () => _pickFolder((path) {
                setState(() {
                  // Pseudo-drive for folder source: build a one-off
                  // DetectedDrive so the rest of the form treats it
                  // uniformly.
                  _selectedDrive = DetectedDrive(
                    path: path,
                    label: p.basename(path),
                    totalBytes: 0,
                    usedBytes: 0,
                  );
                });
              }),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final drive in _drives)
          ChoiceChip(
            avatar: const Icon(Icons.sd_storage, size: 16),
            label: Text('${drive.path}  ${drive.label}'),
            selected: _selectedDrive?.path == drive.path,
            onSelected: (_) => setState(() => _selectedDrive = drive),
          ),
        ActionChip(
          avatar: const Icon(Icons.folder_open, size: 16),
          label: const Text('Folder…'),
          onPressed: () => _pickFolder((path) {
            setState(() {
              _selectedDrive = DetectedDrive(
                path: path,
                label: p.basename(path),
                totalBytes: 0,
                usedBytes: 0,
              );
            });
          }),
        ),
      ],
    );
  }

  Widget _buildFolderPicker({
    required String? currentPath,
    required FavoritePathType favoriteType,
    required ValueChanged<String> onPathSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Current selection.
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  currentPath ?? 'No folder selected',
                  style: TextStyle(
                    color: currentPath != null ? null : Colors.grey,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: () => _pickFolder(onPathSelected),
            ),
            IconButton(
              icon: const Icon(Icons.star_border),
              tooltip: 'Save as favorite',
              onPressed: currentPath != null
                  ? () => _saveAsFavorite(currentPath, favoriteType)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Favorites dropdown.
        StreamBuilder<List<FavoritePath>>(
          stream: favoritePathDao.watchFavoritesByType(favoriteType),
          builder: (context, snapshot) {
            final favorites = snapshot.data ?? [];
            if (favorites.isEmpty) return const SizedBox.shrink();

            return Wrap(
              spacing: 8,
              children: favorites.map((fav) {
                return ActionChip(
                  avatar: const Icon(Icons.star, size: 16),
                  label: Text(fav.label),
                  onPressed: () {
                    onPathSelected(fav.path);
                    favoritePathDao.markUsed(fav.id);
                  },
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Future<void> _pickFolder(ValueChanged<String> onSelected) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      onSelected(result);
    }
  }

  Future<void> _saveAsFavorite(String path, FavoritePathType type) async {
    final controller = TextEditingController(text: p.basename(path));
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Favorite'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Label'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (label != null && label.isNotEmpty) {
      await favoritePathDao.insertFavorite(
        FavoritePathsCompanion.insert(
          path: path,
          label: label,
          type: type,
          lastUsedAt: DateTime.now(),
          createdAt: DateTime.now(),
        ),
      );
    }
  }

  bool _canCreate() {
    if (_jobType == JobType.compression) {
      return _sourcePath != null && _destinationPath != null;
    }
    if (_selectedDrive == null) return false;
    if (_destinationPath == null) return false;
    if (_jobType == JobType.transferAndCompress &&
        _compressionOutputPath == null) {
      return false;
    }
    if (_jobType != JobType.transfer && _selectedPreset == null) return false;
    return true;
  }

  Future<void> _createJob() async {
    try {
      await _createJobInner();
    } catch (e) {
      if (mounted) {
        final statusColors = Theme.of(context).extension<StatusColors>()!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create job — $e'),
            backgroundColor: statusColors.error,
          ),
        );
      }
    }
  }

  Future<void> _createJobInner() async {
    final sourcePath = _jobType == JobType.compression
        ? _sourcePath!
        : _selectedDrive!.path;

    // Enumerate video files from source.
    final scanResult = await driveService.listVideoFiles(sourcePath);
    final videoFiles = scanResult.files;

    // Show skipped paths dialog if any errors occurred.
    if (scanResult.skippedPaths.isNotEmpty && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Some paths were inaccessible'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('The following paths could not be scanned:'),
                const SizedBox(height: 8),
                ...scanResult.skippedPaths.map((path) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $path',
                          style: const TextStyle(fontSize: 13)),
                    )),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }

    if (videoFiles.isEmpty) {
      if (mounted) {
        final statusColors = Theme.of(context).extension<StatusColors>()!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No video files (.MOV, .MP4) found in the source'),
            backgroundColor: statusColors.warning,
          ),
        );
      }
      return;
    }

    // For single-job transfer/copy from a drive root, prepend a per-card
    // subfolder (`label_driveletter`) so two cards with the same DCIM
    // structure cannot collide if the operator runs the same destination
    // twice. Compression jobs (folder source) do not get a subfolder.
    String effectiveDestination = _destinationPath!;
    if (_jobType != JobType.compression && _selectedDrive != null) {
      final subfolder =
          await jobQueueService.buildCardSubfolder(_selectedDrive!);
      effectiveDestination = p.join(_destinationPath!, subfolder);
    }

    // Check for paths exceeding Windows MAX_PATH (260 chars).
    final longPaths = <String>[];
    for (final entity in videoFiles) {
      final relativePath = p.relative(entity.path, from: sourcePath);
      final destFullPath = p.join(effectiveDestination, relativePath);
      if (destFullPath.length > 260) {
        longPaths.add(destFullPath);
      }
    }
    if (longPaths.isNotEmpty && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Long file paths detected'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${longPaths.length} file(s) have destination paths exceeding 260 characters, '
                    'which may cause failures on Windows:'),
                const SizedBox(height: 8),
                ...longPaths.take(10).map((path) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $path',
                          style: const TextStyle(fontSize: 11)),
                    )),
                if (longPaths.length > 10)
                  Text('... and ${longPaths.length - 10} more',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }

    // Build planned file list with sizes.
    final planned = <_PlannedFile>[];
    var totalBytes = 0;
    for (final entity in videoFiles) {
      final size = await File(entity.path).length();
      totalBytes += size;
      final relativePath = p.relative(entity.path, from: sourcePath);
      planned.add(_PlannedFile(
        sourcePath: entity.path,
        destinationPath: p.join(effectiveDestination, relativePath),
        fileName: p.basename(entity.path),
        fileSize: size,
      ));
    }

    // Check disk space before creating.
    if (_destinationFreeSpace != null &&
        totalBytes > _destinationFreeSpace!) {
      if (mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Insufficient Disk Space'),
            content: Text(
              'Source files (${formatBytes(totalBytes)}) exceed '
              'available space (${formatBytes(_destinationFreeSpace!)}).\n\n'
              'Proceed anyway?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Proceed Anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }

    // Conflict detection — check whether any planned destination already
    // exists, and if so let the operator choose how to resolve. Repeats
    // until the operator picks an actionable resolution (skip, rename,
    // overwrite) or aborts.
    var resolved = planned;
    while (true) {
      final conflicts = <String>[];
      for (final f in resolved) {
        if (await File(f.destinationPath).exists()) {
          conflicts.add(f.destinationPath);
        }
      }
      if (conflicts.isEmpty) break;

      if (!mounted) return;
      final choice =
          await ConflictResolutionDialog.show(context, conflicts);
      if (choice == null || choice == ConflictResolution.cancel) return;

      if (choice == ConflictResolution.newFolder) {
        final newPath = await FilePicker.platform.getDirectoryPath();
        if (newPath == null) return;
        setState(() => _destinationPath = newPath);
        // Re-build planned destinations with the new folder.
        final newDest = (_jobType != JobType.compression &&
                _selectedDrive != null)
            ? p.join(newPath,
                await jobQueueService.buildCardSubfolder(_selectedDrive!))
            : newPath;
        // Keep the job-row destination in sync with the file paths.
        // Without this, the persisted job points at the OLD folder
        // while its files point at the NEW one, breaking chained
        // compression's relative-path computation.
        effectiveDestination = newDest;
        resolved = [
          for (final f in planned)
            f.copyWith(
              destinationPath: p.join(
                newDest,
                p.relative(f.sourcePath, from: sourcePath),
              ),
            ),
        ];
        continue;
      }

      // Apply skip / rename / overwrite.
      resolved = _applyResolution(resolved, choice);
      if (resolved.isEmpty) {
        // Skip-all — nothing to transfer. Don't create a phantom job.
        if (mounted) {
          final statusColors = Theme.of(context).extension<StatusColors>()!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'All files already exist at destination — no files to transfer.',
              ),
              backgroundColor: statusColors.warning,
            ),
          );
        }
        return;
      }
      break;
    }

    // Recompute totals after resolution (rename doesn't change bytes; skip does).
    final resolvedTotalBytes =
        resolved.fold<int>(0, (sum, f) => sum + f.fileSize);

    // Read operator name from settings.
    final settings = await settingsDao.getSettings();
    final operatorName = settings?.operatorName;

    // Atomic creation: job + files + totals in one transaction. sortOrder
    // places the new job at the end of the active queue.
    final baseOrder = await jobDao.getMaxSortOrder();
    await jobDao.createJobWithFiles(
      job: JobsCompanion.insert(
        type: _jobType,
        status: JobStatus.queued,
        sourcePath: sourcePath,
        destinationPath: effectiveDestination,
        compressionOutputPath: Value(_compressionOutputPath),
        presetName: Value(_selectedPreset),
        autoChain: Value(_jobType == JobType.transferAndCompress),
        operatorName: Value(
            operatorName != null && operatorName.isNotEmpty ? operatorName : null),
        verificationMode: Value(_jobType != JobType.compression
            ? _verificationMode
            : VerificationMode.size),
        sortOrder: Value(baseOrder + 1),
        createdAt: DateTime.now(),
      ),
      buildFiles: (newJobId) => resolved
          .map((f) => JobFilesCompanion.insert(
                jobId: newJobId,
                sourceFilePath: f.sourcePath,
                destinationFilePath: f.destinationPath,
                fileName: f.fileName,
                fileSize: f.fileSize,
                status: FileStatus.pending,
              ))
          .toList(),
      totalBytes: resolvedTotalBytes,
    );

    // Save last-used paths for next session.
    settingsDao.setLastUsedDestination(_destinationPath!);
    if (_compressionOutputPath != null) {
      settingsDao.setLastUsedOutput(_compressionOutputPath!);
    }

    if (mounted) {
      if (widget.onJobCreated != null) {
        widget.onJobCreated!();
      } else {
        Navigator.pop(context, true);
      }
    }
  }

  /// Apply a conflict resolution to a planned file list. Mirrors the
  /// equivalent helper in [JobQueueService]; kept local to avoid
  /// exposing private types across the service boundary.
  List<_PlannedFile> _applyResolution(
      List<_PlannedFile> files, ConflictResolution resolution) {
    if (resolution == ConflictResolution.overwrite) return files;
    final kept = <_PlannedFile>[];
    for (final f in files) {
      final exists = File(f.destinationPath).existsSync();
      if (!exists) {
        kept.add(f);
        continue;
      }
      if (resolution == ConflictResolution.skip) continue;
      if (resolution == ConflictResolution.rename) {
        kept.add(f.copyWith(destinationPath: _suffixed(f.destinationPath)));
      }
    }
    return kept;
  }

  String _suffixed(String path) {
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    var i = 1;
    while (true) {
      final candidate = p.join(dir, '${stem}_$i$ext');
      if (!File(candidate).existsSync()) return candidate;
      i++;
    }
  }
}

/// Internal: a single planned destination prior to job creation.
class _PlannedFile {
  final String sourcePath;
  final String destinationPath;
  final String fileName;
  final int fileSize;

  const _PlannedFile({
    required this.sourcePath,
    required this.destinationPath,
    required this.fileName,
    required this.fileSize,
  });

  _PlannedFile copyWith({String? destinationPath}) => _PlannedFile(
        sourcePath: sourcePath,
        destinationPath: destinationPath ?? this.destinationPath,
        fileName: fileName,
        fileSize: fileSize,
      );
}

/// Verdict-style free-space sentence (FR-027). Composes the right phrasing
/// based on absolute free bytes and (when available) planned-bytes total.
class _FreeSpaceSentence extends StatelessWidget {
  final int freeBytes;
  final int? plannedBytes;

  const _FreeSpaceSentence({required this.freeBytes, this.plannedBytes});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final freeText = formatBytes(freeBytes);

    String sentence;
    Color color = scheme.onSurfaceVariant;

    if (plannedBytes != null && plannedBytes! > freeBytes) {
      final shortBy = plannedBytes! - freeBytes;
      sentence =
          "$freeText free — won't fit, you have ${formatBytes(plannedBytes!)} to copy (${formatBytes(shortBy)} short)";
      color = statusColors.error;
    } else if (plannedBytes != null && plannedBytes! > freeBytes * 0.9) {
      sentence =
          '$freeText free — cutting it close (planned ${formatBytes(plannedBytes!)})';
      color = statusColors.warning;
    } else if (freeBytes > 1024 * 1024 * 1024 * 1024) {
      sentence = '$freeText free — plenty of room';
    } else {
      sentence = '$freeText free';
    }

    return Text(
      sentence,
      style: TextStyle(color: color, fontSize: 12),
    );
  }
}
