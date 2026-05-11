import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/drive_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'skeleton_row.dart';

/// Live-updating left-column panel listing all detected removable drives.
/// Polls every 3 seconds (FR-020). Tapping a row fires [onSourceSelected]
/// so the parent can open Create Job pre-filled (FR-022).
///
/// Empty state: pulsing "Listening for SD cards…" banner (FR-021).
///
/// 017B (FR-B03/B04/B11): the panel is collapsible. When [collapsed]
/// is true it renders as a 48-px icon strip showing one mini SD-card
/// chip per detected drive plus a chevron-right toggle. Each poll
/// surfaces the current set of drive paths via [onDrivesChanged] so
/// the shell can auto-expand on new card insert.
class SourcesPanel extends StatefulWidget {
  final ValueChanged<DetectedDrive>? onSourceSelected;
  final bool collapsed;
  final VoidCallback? onToggleCollapsed;
  final ValueChanged<Set<String>>? onDrivesChanged;

  const SourcesPanel({
    super.key,
    this.onSourceSelected,
    this.collapsed = false,
    this.onToggleCollapsed,
    this.onDrivesChanged,
  });

  @override
  State<SourcesPanel> createState() => _SourcesPanelState();
}

class _SourcesPanelState extends State<SourcesPanel>
    with SingleTickerProviderStateMixin {
  Timer? _pollTimer;
  late final AnimationController _pulseController;
  List<DetectedDrive> _drives = const [];
  bool _firstPollPending = true;

  static const _pollInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _poll(); // immediate
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final drives = await driveService.getRemovableDrives();
      if (!mounted) return;
      setState(() {
        _drives = drives;
        _firstPollPending = false;
      });
      // 017B (FR-B04): hand the path set to the shell so it can detect
      // newly-inserted cards and auto-expand when collapsed.
      widget.onDrivesChanged
          ?.call(drives.map((d) => d.path).toSet());
    } catch (_) {
      // Transient error — drive unplugged mid-WMI call, PowerShell hiccup.
      // Next tick recovers; do not surface to the user.
      if (mounted) setState(() => _firstPollPending = false);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: widget.collapsed ? _buildCollapsed(scheme) : _buildExpanded(scheme),
    );
  }

  Widget _buildExpanded(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.l, Insets.l, Insets.s, Insets.s),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Sources',
                  style: AppTextStyles.title
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              IconButton(
                tooltip: 'Collapse Sources (Ctrl+1)',
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: widget.onToggleCollapsed,
              ),
            ],
          ),
        ),
        Expanded(
          child: _firstPollPending
              ? _buildLoadingState()
              : (_drives.isEmpty
                  ? _buildEmptyState(scheme)
                  : _buildDriveList()),
        ),
      ],
    );
  }

  /// 017B (FR-B03/B11): 48-px icon strip. Header chevron toggles back
  /// to expanded; per-drive icons remain visible so a card insert
  /// is still noticeable even before the auto-expand kicks in.
  Widget _buildCollapsed(ColorScheme scheme) {
    return Column(
      children: [
        IconButton(
          tooltip: 'Expand Sources (Ctrl+1)',
          icon: const Icon(Icons.chevron_right, size: 20),
          onPressed: widget.onToggleCollapsed,
        ),
        const Divider(height: 1),
        Expanded(
          child: _drives.isEmpty
              ? Center(
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (_, _) => Opacity(
                      opacity: 0.4 + 0.6 * _pulseController.value,
                      child: Icon(
                        Icons.sd_storage,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: Insets.s),
                  itemCount: _drives.length,
                  itemBuilder: (context, index) {
                    final drive = _drives[index];
                    return Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: Insets.xs),
                      child: Tooltip(
                        message:
                            '${drive.label.isEmpty ? "Removable drive" : drive.label}\n'
                            '${drive.path} · ${formatBytes(drive.freeBytes)} free',
                        child: IconButton(
                          icon: Icon(Icons.sd_card,
                              size: 22, color: scheme.onSurface),
                          onPressed: widget.onSourceSelected != null
                              ? () => widget.onSourceSelected!(drive)
                              : null,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    // Three skeleton rows during the very first poll. Once we have a result
    // (even an empty list), we switch to the empty-state pulsing banner.
    // T106: shared SkeletonRow with shimmer (replaces the static
    // colored Container "skeleton" — actual loading signal now).
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Insets.s),
      children: List.generate(
          3, (_) => const SkeletonRow(height: 60)),
    );
  }

  Widget _buildEmptyState(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.l),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, child) {
                final t = _pulseController.value;
                return Opacity(
                  opacity: 0.4 + 0.6 * t,
                  child: Icon(
                    Icons.sd_storage,
                    size: 32,
                    color: scheme.onSurfaceVariant,
                  ),
                );
              },
            ),
            const SizedBox(height: Insets.m),
            Text(
              'Listening for SD cards…',
              style: AppTextStyles.body
                  .copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriveList() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.s, vertical: Insets.s),
      itemCount: _drives.length,
      separatorBuilder: (_, idx) => const SizedBox(height: Insets.xs),
      itemBuilder: (context, index) {
        final drive = _drives[index];
        return _DriveRow(
          drive: drive,
          onTap: widget.onSourceSelected != null
              ? () => widget.onSourceSelected!(drive)
              : null,
        );
      },
    );
  }
}

class _DriveRow extends StatelessWidget {
  final DetectedDrive drive;
  final VoidCallback? onTap;

  const _DriveRow({required this.drive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final freeRatio =
        drive.totalBytes > 0 ? drive.freeBytes / drive.totalBytes : 0.0;
    final freePillColor = freeRatio < 0.05
        ? statusColors.error
        : freeRatio < 0.15
            ? statusColors.warning
            : statusColors.success;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Insets.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sd_storage, size: 18, color: scheme.onSurface),
                  const SizedBox(width: Insets.s),
                  Expanded(
                    child: Text(
                      drive.label.isEmpty ? 'Removable drive' : drive.label,
                      style: AppTextStyles.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(
                '${drive.path}  ·  ${drive.displaySize}',
                style: AppTextStyles.mono.copyWith(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Insets.s, vertical: 2),
                    decoration: BoxDecoration(
                      color: freePillColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${formatBytes(drive.freeBytes)} free',
                      style: AppTextStyles.caption.copyWith(
                        color: freePillColor,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _SkeletonDriveRow retired in T106 — replaced by the shared
// SkeletonRow widget (lib/ui/widgets/skeleton_row.dart) which actually
// shimmers and unifies the loading affordance across panels.
