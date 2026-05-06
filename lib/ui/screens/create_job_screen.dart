import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../utils/format_utils.dart';
import '../widgets/drive_list.dart';

/// Screen for creating a new job with source, destination, and options.
class CreateJobScreen extends StatefulWidget {
  /// Callback for embedded mode (ShellScreen). If null, uses Navigator.pop.
  final VoidCallback? onJobCreated;

  const CreateJobScreen({super.key, this.onJobCreated});

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
  bool _loading = true;
  int? _destinationFreeSpace;
  bool _handbrakeInstalled = true;

  @override
  void initState() {
    super.initState();
    _refreshDrives();
    _loadPresets();
    _checkHandbrake();
  }

  Future<void> _refreshDrives() async {
    setState(() => _loading = true);
    final drives = await driveService.getRemovableDrives();
    setState(() {
      _drives = drives;
      _loading = false;
    });
  }

  Future<void> _loadPresets() async {
    final presets = await compressionService.getAvailablePresets();
    setState(() => _presets = presets);
  }

  Future<void> _checkHandbrake() async {
    final installed = await compressionService.isHandbrakeInstalled();
    setState(() => _handbrakeInstalled = installed);
  }

  Future<void> _updateFreeSpace(String path) async {
    final free = await driveService.getDiskFreeSpace(path);
    setState(() => _destinationFreeSpace = free > 0 ? free : null);
  }

  @override
  Widget build(BuildContext context) {
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
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
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
                  label: Text('Both'),
                  icon: Icon(Icons.sync),
                ),
              ],
              selected: {_jobType},
              onSelectionChanged: (selection) {
                setState(() => _jobType = selection.first);
              },
            ),

            const SizedBox(height: 24),

            // Source drive selection (for transfer jobs).
            if (_jobType != JobType.compression) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Source Drive',
                      style: Theme.of(context).textTheme.titleMedium),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _refreshDrives,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                DriveList(
                  drives: _drives,
                  selectedDrivePath: _selectedDrive?.path,
                  onDriveSelected: (drive) {
                    setState(() => _selectedDrive = drive);
                  },
                ),
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
                child: Text(
                  '${formatBytes(_destinationFreeSpace!)} free',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),

            const SizedBox(height: 24),

            // Compression output (for transfer+compress jobs).
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
              const SizedBox(height: 24),
            ],

            // Preset selector (for compression jobs).
            if (_jobType != JobType.transfer) ...[
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
                    .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                    .toList(),
                onChanged: (value) {
                  setState(() => _selectedPreset = value);
                },
              ),
              if (_presets.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No presets found. Check HandBrake installation.',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
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
    final controller = TextEditingController(text: path.split(r'\').last);
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
    return true;
  }

  Future<void> _createJob() async {
    try {
      await _createJobInner();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create job — $e'),
            backgroundColor: Colors.red,
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
    final videoFiles = await driveService.listVideoFiles(sourcePath);
    if (videoFiles.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No video files (.MOV, .MP4) found in the source'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Check disk space before creating.
    var totalSourceBytes = 0;
    for (final entity in videoFiles) {
      totalSourceBytes += await File(entity.path).length();
    }
    if (_destinationFreeSpace != null &&
        totalSourceBytes > _destinationFreeSpace!) {
      if (mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Insufficient Disk Space'),
            content: Text(
              'Source files (${formatBytes(totalSourceBytes)}) exceed '
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

    final newJobId = await jobDao.insertJob(
      JobsCompanion.insert(
        type: _jobType,
        status: JobStatus.queued,
        sourcePath: sourcePath,
        destinationPath: _destinationPath!,
        compressionOutputPath: Value(_compressionOutputPath),
        presetName: Value(_selectedPreset),
        autoChain: Value(_jobType == JobType.transferAndCompress),
        createdAt: DateTime.now(),
      ),
    );

    // Build file entries with proper paths.
    final destPath = _jobType == JobType.compression
        ? _destinationPath! // For compression, destination is the output folder.
        : _destinationPath!;
    var totalBytes = 0;
    final fileEntries = <JobFilesCompanion>[];
    for (final entity in videoFiles) {
      final file = File(entity.path);
      final size = await file.length();
      final fileName = p.basename(entity.path);
      totalBytes += size;
      fileEntries.add(
        JobFilesCompanion.insert(
          jobId: newJobId,
          sourceFilePath: entity.path,
          destinationFilePath: p.join(destPath, fileName),
          fileName: fileName,
          fileSize: size,
          status: FileStatus.pending,
        ),
      );
    }

    await jobFileDao.insertFiles(fileEntries);
    await jobDao.updateJobTotals(newJobId, fileEntries.length, totalBytes);

    if (mounted) {
      if (widget.onJobCreated != null) {
        widget.onJobCreated!();
      } else {
        Navigator.pop(context, true);
      }
    }
  }
}
