import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme/insets.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../widgets/conflict_dialog.dart';
import '../widgets/plan_summary_panel.dart';

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

  // ── US8 plan-summary state ────────────────────────────────────────
  // The panel surfaces file count, total bytes, free-space verdict,
  // conflict count, and long-path count — all computed from a debounced
  // background scan triggered by source/destination changes (T067-T071).
  // Source-scan results are CACHED so flipping the destination doesn't
  // re-walk the source folder; only conflict + long-path passes re-run.
  Timer? _planDebounce;
  int _planScanGen = 0;
  String? _scannedSourcePath;
  List<_PlannedFile> _scannedFiles = const <_PlannedFile>[];
  int _scannedTotalBytes = 0;
  bool _planScanInProgress = false;
  int? _planFileCount;
  int? _planTotalBytes;
  int? _planConflictCount;
  int? _planLongPathCount;
  // First N long-path destinations — surfaced via the panel's "View
  // files" affordance so the operator can see *which* files are at
  // risk, not just the count (Codex Phase 10 WARN — T072 had dropped
  // this detail when the blocking AlertDialog was removed).
  List<String> _planLongPathSamples = const <String>[];

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
    _schedulePlanRecompute();
  }

  @override
  void dispose() {
    _planDebounce?.cancel();
    super.dispose();
  }

  /// Schedule a debounced plan recompute. Bumps [_planScanGen]
  /// IMMEDIATELY so any in-flight scan from a previous call self-
  /// invalidates BEFORE the new debounce window elapses (Codex Phase 10
  /// CRITICAL — without the immediate bump, a slow scan could publish
  /// stale results during the 250ms window).
  ///
  /// Called from every state change that affects the plan: jobType
  /// flip, source chip select, source-folder pick, destination pick,
  /// compression-output pick, drives refresh.
  void _schedulePlanRecompute() {
    _planScanGen++;
    _planDebounce?.cancel();
    _planDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _recomputePlanGuarded(),
    );
  }

  /// Outer guard: runs [_recomputePlan] inside a try/finally so an
  /// exception (permissions glitch, transient I/O failure) can't leave
  /// `_planScanInProgress = true` forever (Codex Phase 10 WARN). Also
  /// catches & logs so the panel keeps working through one-off errors.
  Future<void> _recomputePlanGuarded() async {
    try {
      await _recomputePlan();
    } catch (_) {
      // Swallow at the boundary — the panel renders best-effort. The
      // operator's actual submit goes through _createJobInner which
      // re-scans and surfaces real errors there.
    } finally {
      if (mounted && _planScanInProgress) {
        setState(() => _planScanInProgress = false);
      }
    }
  }

  /// Live plan recompute (T067-T071). Two passes:
  ///   1. Source scan — listVideoFiles + per-file size. Cached on
  ///      [_scannedSourcePath] so destination flips skip this pass.
  ///      Cleared on `_refreshDrives` so a card swap at the same drive
  ///      letter re-scans.
  ///   2. Destination pass — conflict count (File.exists) + long-path
  ///      count (path.length > 260) over the cached file list.
  ///
  /// Each scan captures a generation token at start and re-checks it
  /// after every await. The token is bumped synchronously by
  /// [_schedulePlanRecompute] so a new schedule call invalidates this
  /// scan IMMEDIATELY — no 250ms-window leak.
  Future<void> _recomputePlan() async {
    if (!mounted) return;
    final gen = _planScanGen;

    final isCompression = _jobType == JobType.compression;
    final sourcePath =
        isCompression ? _sourcePath : _selectedDrive?.path;

    if (sourcePath == null) {
      setState(() {
        _planScanInProgress = false;
        _planFileCount = null;
        _planTotalBytes = null;
        _planConflictCount = null;
        _planLongPathCount = null;
        _scannedSourcePath = null;
        _scannedFiles = const <_PlannedFile>[];
        _scannedTotalBytes = 0;
      });
      return;
    }

    // Always show "scanning…" once we commit to recomputing — covers
    // both the source pass AND a destination-only pass (Codex WARN —
    // a destination flip with a warm cache used to do its conflict
    // sweep silently with no progress signal).
    setState(() {
      _planScanInProgress = true;
      _planConflictCount = null;
      _planLongPathCount = null;
    });

    // Source-scan pass (cached by source path).
    if (_scannedSourcePath != sourcePath) {
      setState(() {
        _planFileCount = null;
        _planTotalBytes = null;
      });
      final scan = await driveService.listVideoFiles(sourcePath);
      if (gen != _planScanGen || !mounted) return;
      var totalBytes = 0;
      final files = <_PlannedFile>[];
      for (final entity in scan.files) {
        try {
          final size = await File(entity.path).length();
          totalBytes += size;
          files.add(_PlannedFile(
            sourcePath: entity.path,
            destinationPath: '', // populated in destination pass
            fileName: p.basename(entity.path),
            fileSize: size,
          ));
        } catch (_) {
          // Ignore individual stat errors; the file just doesn't
          // contribute to the count.
        }
      }
      if (gen != _planScanGen || !mounted) return;
      _scannedSourcePath = sourcePath;
      _scannedFiles = files;
      _scannedTotalBytes = totalBytes;
    }

    // Destination pass: build planned destinations, count conflicts +
    // long paths. Skipped when the destination isn't picked yet.
    final destinationPath = _destinationPath;
    if (destinationPath == null || _scannedFiles.isEmpty) {
      setState(() {
        _planScanInProgress = false;
        _planFileCount = _scannedFiles.length;
        _planTotalBytes = _scannedTotalBytes;
        _planConflictCount = null;
        _planLongPathCount = null;
        _planLongPathSamples = const <String>[];
      });
      return;
    }

    String effectiveDestination = destinationPath;
    if (!isCompression && _selectedDrive != null) {
      try {
        final subfolder =
            await jobQueueService.buildCardSubfolder(_selectedDrive!);
        effectiveDestination = p.join(destinationPath, subfolder);
      } catch (_) {
        // Use bare destination if subfolder computation fails — not
        // worth blocking the panel for a transient drive glitch.
      }
    }
    if (gen != _planScanGen || !mounted) return;

    var conflicts = 0;
    var longPaths = 0;
    final longPathSamples = <String>[];
    for (final f in _scannedFiles) {
      final relativePath = p.relative(f.sourcePath, from: sourcePath);
      final destFullPath = p.join(effectiveDestination, relativePath);
      if (destFullPath.length > 260) {
        longPaths++;
        if (longPathSamples.length < 10) longPathSamples.add(destFullPath);
      }
      if (await File(destFullPath).exists()) conflicts++;
      if (gen != _planScanGen || !mounted) return;
    }

    setState(() {
      _planScanInProgress = false;
      _planFileCount = _scannedFiles.length;
      _planTotalBytes = _scannedTotalBytes;
      _planConflictCount = conflicts;
      _planLongPathCount = longPaths;
      _planLongPathSamples = longPathSamples;
    });
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
      // Codex Phase 10 CRITICAL: a card swap at the same drive letter
      // would otherwise keep the previous card's plan summary because
      // the cache is keyed on path alone. Clear the cache on every
      // refresh so the next recompute re-walks the source.
      _scannedSourcePath = null;
      _scannedFiles = const <_PlannedFile>[];
      _scannedTotalBytes = 0;
    });
    _schedulePlanRecompute();
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

  /// Read the operator's default conflict-resolution preference from
  /// settings. Allowed values are validated at the DAO setter, but we
  /// also gate here defensively — any unexpected stored value falls
  /// back to 'ask' (the safe v2.3.0 behavior).
  Future<String> _readDefaultConflictResolution() async {
    final settings = await settingsDao.getSettings();
    final v = settings?.defaultConflictResolution ?? 'ask';
    return const {'ask', 'skip', 'rename'}.contains(v) ? v : 'ask';
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
        // US9 (T079): pick up operator's default verification mode.
        // The per-job SegmentedButton still allows override; this only
        // controls the initial selection.
        if (settings.defaultVerificationMode == 'sha256') {
          _verificationMode = VerificationMode.sha256;
        } else {
          _verificationMode = VerificationMode.size;
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
                    const SizedBox(width: Insets.s),
                    const Expanded(
                      child: Text(
                        'Compression requires HandBrake. '
                        'Download it at handbrake.fr. '
                        'Compression options are disabled.',
                        style: AppTextStyles.body,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Insets.l),
            ],

            // Job type selector.
            Text('Job Type', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Insets.s),
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
                  label: Text('Copy + Compress'),
                  icon: Icon(Icons.sync),
                ),
              ],
              selected: {_jobType},
              onSelectionChanged: (selection) {
                setState(() => _jobType = selection.first);
                _schedulePlanRecompute();
              },
            ),

            const SizedBox(height: Insets.xl),

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
              const SizedBox(height: Insets.s),
              if (_loading && _drives.isEmpty)
                const Center(child: CircularProgressIndicator())
              else
                _buildSourceChips(),
              const SizedBox(height: Insets.xl),
            ],

            // Source folder (compression-only jobs).
            if (_jobType == JobType.compression) ...[
              Text('Input Folder',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.s),
              _buildFolderPicker(
                currentPath: _sourcePath,
                favoriteType: FavoritePathType.source,
                onPathSelected: (path) {
                  setState(() => _sourcePath = path);
                  _schedulePlanRecompute();
                },
              ),
              const SizedBox(height: Insets.xl),
            ],

            // Destination / output folder.
            Text(
              _jobType == JobType.compression ? 'Output Folder' : 'Destination',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Insets.s),
            _buildFolderPicker(
              currentPath: _destinationPath,
              favoriteType: _jobType == JobType.compression
                  ? FavoritePathType.output
                  : FavoritePathType.destination,
              onPathSelected: (path) {
                setState(() => _destinationPath = path);
                _updateFreeSpace(path);
                _schedulePlanRecompute();
              },
            ),
            // T067-T069: free-space verdict moved into PlanSummaryPanel
            // below so all plan facts (file count, bytes, free space,
            // conflicts, long paths) live in one bordered panel above
            // the Add to Queue button. Per-section _FreeSpaceSentence
            // retired to avoid two free-space sentences on the page.

            const SizedBox(height: Insets.xl),

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
                    const SizedBox(height: Insets.s),
                    _buildFolderPicker(
                      currentPath: _compressionOutputPath,
                      favoriteType: FavoritePathType.output,
                      onPathSelected: (path) {
                        setState(() => _compressionOutputPath = path);
                        // Compression output folder doesn't change the
                        // transfer-side plan, but recompute is cheap when
                        // the source-scan cache is warm — keeps the
                        // "Add to Queue" enabling logic in sync.
                        _schedulePlanRecompute();
                      },
                    ),
                    const SizedBox(height: Insets.l),
                  ],
                  Text('Compression Preset',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Insets.s),
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
              const SizedBox(height: Insets.xl),
            ],

            // Verification mode (for transfer jobs).
            if (_jobType != JobType.compression) ...[
              Text('Verification',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.s),
              SegmentedButton<VerificationMode>(
                segments: const [
                  ButtonSegment(
                    value: VerificationMode.size,
                    label: Text('Quick'),
                    icon: Icon(Icons.speed),
                  ),
                  ButtonSegment(
                    value: VerificationMode.sha256,
                    label: Text('SHA-256'),
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
                    style: AppTextStyles.caption
                        .copyWith(color: statusColors.warning),
                  ),
                ),
              const SizedBox(height: Insets.xl),
            ],

            // US8 plan summary — live preview of what will happen if
            // the operator clicks "Add to Queue". File count, total
            // bytes, free-space verdict, conflict count, long-path
            // warning all in one panel (T067-T071).
            PlanSummaryPanel(
              scanInProgress: _planScanInProgress,
              fileCount: _planFileCount,
              totalBytes: _planTotalBytes,
              freeBytes: _destinationFreeSpace,
              conflictCount: _planConflictCount,
              longPathCount: _planLongPathCount,
              longPathSamples: _planLongPathSamples,
            ),
            const SizedBox(height: Insets.l),

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
            const SizedBox(width: Insets.s),
            Expanded(
              child: Text(
                'No removable drives detected. Click "Folder…" to pick a path.',
                style: AppTextStyles.body
                    .copyWith(color: scheme.onSurfaceVariant),
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
                _schedulePlanRecompute();
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
            label: Text('${drive.path}  ${drive.label}',
                style: AppTextStyles.mono),
            selected: _selectedDrive?.path == drive.path,
            onSelected: (_) {
              setState(() => _selectedDrive = drive);
              _schedulePlanRecompute();
            },
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
            _schedulePlanRecompute();
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
            const SizedBox(width: Insets.s),
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
        const SizedBox(height: Insets.s),
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
                const SizedBox(height: Insets.s),
                ...scanResult.skippedPaths.map((path) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $path', style: AppTextStyles.mono),
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

    // T072: long-path detection moved to PlanSummaryPanel as an inline
    // yellow note BEFORE submit — the blocking AlertDialog interrupted
    // the flow with information the operator already saw in the panel.
    // FR-028: "9 files have paths > 260 chars — Windows may reject
    // these" is surfaced upfront; the operator chooses whether to
    // proceed. No mid-flow modal.

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
    //
    // US9 (T079, Codex Phase 11 fix): if the operator set a default
    // conflict-resolution to 'skip' or 'rename' in Settings → Behavior,
    // auto-apply it ONCE without showing the dialog. 'ask' (default)
    // and 'newFolder' (requires interaction) both fall through to the
    // dialog.
    final defaultConflictRes = await _readDefaultConflictResolution();
    var resolved = planned;
    var autoApplied = false;
    while (true) {
      final conflicts = <String>[];
      for (final f in resolved) {
        if (await File(f.destinationPath).exists()) {
          conflicts.add(f.destinationPath);
        }
      }
      if (conflicts.isEmpty) break;

      // Auto-apply path: only on the FIRST conflict pass (avoid loops
      // if rename produces a new conflict immediately, which it
      // shouldn't but defense-in-depth).
      if (!autoApplied &&
          (defaultConflictRes == 'skip' ||
              defaultConflictRes == 'rename')) {
        autoApplied = true;
        final auto = defaultConflictRes == 'skip'
            ? ConflictResolution.skip
            : ConflictResolution.rename;
        resolved = _applyResolution(resolved, auto);
        if (resolved.isEmpty) {
          if (mounted) {
            final statusColors =
                Theme.of(context).extension<StatusColors>()!;
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
        // Re-loop in case rename produced any new conflicts (extremely
        // rare but the suffix scheme is best-effort).
        continue;
      }

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

// _FreeSpaceSentence retired in US8 (T067-T069). The verdict sentence
// now lives inside lib/ui/widgets/plan_summary_panel.dart (private
// _FreeSpaceLine), composed alongside file count, conflict count, and
// long-path note. This file no longer renders free-space inline.
