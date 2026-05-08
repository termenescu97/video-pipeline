import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../database/database.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../services/update_service.dart';
import '../../utils/instance_lock.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import '../widgets/confirmation_dialog.dart';

/// US9 — Settings as a side-navigation surface (T075-T080).
///
/// Five sections, all selectable via a left [NavigationRail]:
///   - Notifications  — Slack URL, "Test now", live test result + pill
///   - Operator       — name field with "Saved ✓" indicator
///   - Behavior       — default verification + conflict resolution
///   - Diagnostics    — Prep Test Cards, log path, instance lock,
///                      HandBrake detection
///   - About          — version, "Check for updates", release notes link
///
/// The previous single-column layout grew to ~240 lines and mixed
/// every concern into one scroll surface. The side nav scales: future
/// preferences slot into the right section without further structural
/// changes (the spec called this out as the success criterion).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedIndex = 0;

  /// Lifted from _NotificationsSection (Codex Phase 11 review WARN —
  /// state was lost on every nav between sections; spec says it
  /// persists "until app launch"). Owned here, passed down so the
  /// connection pill survives section switches.
  bool? _slackLastTestOk;
  DateTime? _slackLastTestAt;

  void _setSlackTestResult(bool ok, DateTime at) {
    setState(() {
      _slackLastTestOk = ok;
      _slackLastTestAt = at;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) =>
                setState(() => _selectedIndex = i),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.notifications_outlined),
                selectedIcon: Icon(Icons.notifications),
                label: Text('Notifications'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: Text('Operator'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.tune),
                selectedIcon: Icon(Icons.tune),
                label: Text('Behavior'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.medical_information_outlined),
                selectedIcon: Icon(Icons.medical_information),
                label: Text('Diagnostics'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.info_outline),
                selectedIcon: Icon(Icons.info),
                label: Text('About'),
              ),
            ],
          ),
          VerticalDivider(
              thickness: 1, width: 1, color: scheme.outlineVariant),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Insets.l),
              child: _buildSection(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection() {
    switch (_selectedIndex) {
      case 0:
        return _NotificationsSection(
          lastTestOk: _slackLastTestOk,
          lastTestAt: _slackLastTestAt,
          onTestResult: _setSlackTestResult,
        );
      case 1:
        return const _OperatorSection();
      case 2:
        return const _BehaviorSection();
      case 3:
        return const _DiagnosticsSection();
      case 4:
        return const _AboutSection();
    }
    return const SizedBox.shrink();
  }
}

// ── Notifications ───────────────────────────────────────────────────

/// T076: Slack webhook configuration with debounced auto-save, an
/// explicit "Test now" button, and an in-memory last-test result line.
/// The connection-state pill (Connected / Failed / Untested) reflects
/// the most recent test in this session — last-test result resets on
/// app restart by design (no schema change, no false confidence
/// from a stale persisted "OK" if the webhook has since been revoked).
class _NotificationsSection extends StatefulWidget {
  /// Last-test state owned by [_SettingsScreenState] so it survives
  /// nav between sections (Codex Phase 11 review WARN). null = never
  /// tested this session.
  final bool? lastTestOk;
  final DateTime? lastTestAt;
  final void Function(bool ok, DateTime at) onTestResult;

  const _NotificationsSection({
    required this.lastTestOk,
    required this.lastTestAt,
    required this.onTestResult,
  });

  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> {
  final _webhookController = TextEditingController();
  Timer? _debounceTimer;
  bool _testingWebhook = false;
  bool _saved = false;
  Timer? _savedHideTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await settingsDao.getSettings();
    if (!mounted) return;
    _webhookController.text = settings?.slackWebhookUrl ?? '';
    setState(() {});
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _savedHideTimer?.cancel();
    _webhookController.dispose();
    super.dispose();
  }

  void _onWebhookChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      await settingsDao.setSlackWebhookUrl(value);
      if (!mounted) return;
      setState(() => _saved = true);
      _savedHideTimer?.cancel();
      _savedHideTimer = Timer(
        const Duration(seconds: 2),
        () {
          if (mounted) setState(() => _saved = false);
        },
      );
    });
  }

  Future<void> _testWebhook() async {
    setState(() => _testingWebhook = true);
    final ok = await slackService.sendTestNotification();
    if (!mounted) return;
    setState(() => _testingWebhook = false);
    // Persist via the parent so the result survives nav between
    // settings sections (Codex Phase 11 review WARN).
    widget.onTestResult(ok, DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(title: 'Slack Notifications', pill: _connectionPill()),
          const SizedBox(height: Insets.s),
          Text(
            'Webhook URL is sent in the clear to hooks.slack.com. '
            'Test posts a single short message to confirm the URL works.',
            style: AppTextStyles.caption.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.m),
          TextField(
            controller: _webhookController,
            decoration: InputDecoration(
              labelText: 'Webhook URL',
              hintText: 'https://hooks.slack.com/services/...',
              border: const OutlineInputBorder(),
              suffixIcon: _saved
                  ? Padding(
                      padding: const EdgeInsets.only(right: Insets.s),
                      child: Icon(
                        Icons.check_circle,
                        color:
                            Theme.of(context).extension<StatusColors>()!.success,
                      ),
                    )
                  : null,
            ),
            onChanged: _onWebhookChanged,
          ),
          const SizedBox(height: Insets.m),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _testingWebhook ? null : _testWebhook,
                icon: _testingWebhook
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 16),
                label: const Text('Test now'),
              ),
              const SizedBox(width: Insets.m),
              if (widget.lastTestAt != null)
                Text(_lastTestText(),
                    style: AppTextStyles.caption.copyWith(
                      color: widget.lastTestOk == true
                          ? Theme.of(context)
                              .extension<StatusColors>()!
                              .success
                          : Theme.of(context)
                              .extension<StatusColors>()!
                              .error,
                    )),
            ],
          ),
        ],
      ),
    );
  }

  String _lastTestText() {
    final at = widget.lastTestAt;
    if (at == null) return '';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return widget.lastTestOk == true
        ? 'Last test: OK $hh:$mm'
        : 'Last test: failed at $hh:$mm';
  }

  Widget _connectionPill() {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (widget.lastTestOk) {
      true => ('Connected', statusColors.success),
      false => ('Failed', statusColors.error),
      null => ('Untested', scheme.onSurfaceVariant),
    };
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Insets.s, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: AppTextStyles.caption.copyWith(color: color)),
    );
  }
}

// ── Operator ────────────────────────────────────────────────────────

/// T077: operator name field with debounced save and a brief "Saved ✓"
/// indicator that fades after 2 seconds. The name appears in Slack
/// messages and CSV exports — silent debounced saves (the v2.3.0
/// behavior) left operators wondering if their typing was even
/// captured.
class _OperatorSection extends StatefulWidget {
  const _OperatorSection();

  @override
  State<_OperatorSection> createState() => _OperatorSectionState();
}

class _OperatorSectionState extends State<_OperatorSection> {
  final _controller = TextEditingController();
  Timer? _debounceTimer;
  bool _saved = false;
  Timer? _savedHideTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await settingsDao.getSettings();
    if (!mounted) return;
    _controller.text = settings?.operatorName ?? '';
    setState(() {});
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _savedHideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      await settingsDao.setOperatorName(value);
      if (!mounted) return;
      setState(() => _saved = true);
      _savedHideTimer?.cancel();
      _savedHideTimer = Timer(
        const Duration(seconds: 2),
        () {
          if (mounted) setState(() => _saved = false);
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: 'Operator'),
          const SizedBox(height: Insets.s),
          Text(
            'Stamped on Slack messages, job records, and CSV exports.',
            style: AppTextStyles.caption.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.m),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: 'Operator Name',
              hintText: 'Your name',
              border: const OutlineInputBorder(),
              suffixIcon: _saved
                  ? Padding(
                      padding: const EdgeInsets.only(right: Insets.s),
                      child: Icon(Icons.check_circle,
                          color: statusColors.success),
                    )
                  : null,
            ),
            onChanged: _onChanged,
          ),
        ],
      ),
    );
  }
}

// ── Behavior ────────────────────────────────────────────────────────

/// T079: persistent operator-level defaults. New jobs pick these up
/// in CreateJobScreen; the operator can still override per-job.
///
/// `default conflict resolution` is forward-compatible: today only
/// `'ask'` is wired into the create flow (matching v2.3.0). Storing
/// `'skip'` / `'rename'` / `'newFolder'` now means the future
/// auto-apply path can consume them without another migration.
/// `'overwrite'` is intentionally NOT a settable default —
/// Constitution Principle I: silent overwrites would bypass the
/// human-in-the-loop gate.
class _BehaviorSection extends StatelessWidget {
  const _BehaviorSection();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppSetting?>(
      stream: settingsDao.watchSettings(),
      builder: (context, snapshot) {
        final settings = snapshot.data;
        if (settings == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(title: 'Behavior'),
              const SizedBox(height: Insets.s),
              Text(
                'Defaults applied to new jobs. Per-job overrides remain '
                'available in Create Job.',
                style: AppTextStyles.caption.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.l),
              _LabeledDropdown<String>(
                label: 'Default verification',
                value: settings.defaultVerificationMode,
                items: const [
                  ('size', 'Quick (size match)'),
                  ('sha256', 'Full SHA-256'),
                ],
                onChanged: (v) {
                  if (v != null) {
                    settingsDao.setDefaultVerificationMode(v);
                  }
                },
              ),
              const SizedBox(height: Insets.l),
              _LabeledDropdown<String>(
                // 'newFolder' is intentionally NOT here — it requires
                // interactive folder picking and degrades to 'ask' at
                // runtime, so storing it would be a silently-wrong UX
                // promise (Codex Phase 11 review WARN). 'overwrite' is
                // omitted under Principle I — silent overwrite must
                // require typed confirm at point of use.
                label: 'Default conflict handling',
                value: const {'ask', 'skip', 'rename'}
                        .contains(settings.defaultConflictResolution)
                    ? settings.defaultConflictResolution
                    : 'ask',
                items: const [
                  ('ask', 'Ask each time (recommended)'),
                  ('skip', 'Skip files that already exist'),
                  ('rename', 'Rename new files (_1, _2, …)'),
                ],
                onChanged: (v) {
                  if (v != null) {
                    settingsDao.setDefaultConflictResolution(v);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Diagnostics ─────────────────────────────────────────────────────

/// T078: operator-facing diagnostic panel. Surfaces the four pieces
/// of system state most useful when a job misbehaves: the persistent
/// log file, the single-instance lock, HandBrake detection, and the
/// Prep Test Cards utility (relocated from its v2.3.0 home next to
/// Notifications).
class _DiagnosticsSection extends StatefulWidget {
  const _DiagnosticsSection();

  @override
  State<_DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<_DiagnosticsSection> {
  bool? _handbrakeInstalled;
  InstanceLockDiagnostic? _lockDiagnostic;

  /// In-flight Prep Test Cards run. Disables the button and surfaces
  /// a progress indicator so multi-card copies don't appear frozen
  /// (Codex Phase 11 review CRITICAL — Principle V).
  bool _preppingCards = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final installed = await compressionService.isHandbrakeInstalled();
    final lock = await instanceLock.diagnostic();
    if (!mounted) return;
    setState(() {
      _handbrakeInstalled = installed;
      _lockDiagnostic = lock;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: 'Diagnostics'),
          const SizedBox(height: Insets.l),

          // Log file
          _DiagRow(
            label: 'Log file',
            value: logService.logPath.isEmpty
                ? '(not initialized)'
                : logService.logPath,
            valueIsMono: true,
            trailing: TextButton.icon(
              onPressed: logService.logPath.isEmpty ? null : _revealLogFile,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('Reveal in Explorer'),
            ),
          ),

          const Divider(height: Insets.xl),

          // Instance lock — when not held, surface the recorded PID
          // so the operator knows which process is holding it (Codex
          // Phase 11 review WARN — "Not held" alone gave no actionable
          // signal).
          _DiagRow(
            label: 'Single-instance lock',
            value: _instanceLockValue(_lockDiagnostic),
            mutedNote: _lockDiagnostic?.lockFilePath,
          ),

          const Divider(height: Insets.xl),

          // HandBrake
          _DiagRow(
            label: 'HandBrake CLI',
            value: _handbrakeInstalled == null
                ? 'Detecting…'
                : _handbrakeInstalled!
                    ? 'Installed and on PATH'
                    : 'Not detected — compression jobs will be disabled',
            valueColor: _handbrakeInstalled == false
                ? Theme.of(context).extension<StatusColors>()!.warning
                : null,
          ),

          const Divider(height: Insets.xl),

          // Prep Test Cards (moved from Notifications-adjacent space)
          if (Platform.isWindows) ...[
            const _SectionTitle(title: 'Prep Test Cards'),
            const SizedBox(height: Insets.s),
            Text(
              'Copies test video files to all inserted SD cards under '
              'DCIM/100TEST/. Existing 100TEST/ folders are replaced; '
              'other files are untouched.',
              style: AppTextStyles.caption.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.m),
            FilledButton.tonalIcon(
              onPressed: _preppingCards ? null : _prepTestCards,
              icon: _preppingCards
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.science_outlined, size: 16),
              label: Text(_preppingCards
                  ? 'Prepping cards…'
                  : 'Prep Test Cards'),
            ),
          ],
        ],
      ),
    );
  }

  String _instanceLockValue(InstanceLockDiagnostic? d) {
    if (d == null) return 'Loading…';
    if (d.heldByThisProcess) {
      return 'Held by this process (PID ${d.currentPid})';
    }
    final other = d.recordedPid;
    if (other != null) {
      return 'Held by another process (PID $other) — startup would fail';
    }
    return 'Not held by this process — startup would fail';
  }

  Future<void> _revealLogFile() async {
    final path = logService.logPath;
    if (path.isEmpty) return;
    try {
      // Windows-only — `explorer /select,<path>` highlights the file.
      // The "/select," space is intentional per Explorer's CLI grammar.
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else {
        // Mac dev environment: open the containing folder.
        await Process.run('open', ['-R', path]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not reveal log file: $e')),
      );
    }
  }

  /// Mirrors the v2.3.0 _prepTestCards logic — moved to Diagnostics
  /// where it conceptually belongs (it's a QA tool, not a notification
  /// preference).
  Future<void> _prepTestCards() async {
    final drives = await driveService.getRemovableDrives();
    if (!mounted) return;
    if (drives.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No removable drives detected')),
      );
      return;
    }

    // T101 / Phase 14 typed-confirm migration: Prep Test Cards
    // replaces DCIM/100TEST/ on every detected card. Destructive
    // (one folder per card) but not catastrophic (other files
    // untouched), so it gets the standard typed gate.
    final confirmed = await ConfirmationDialog.showDestructive(
      context: context,
      title: 'Prep Test Cards',
      message: 'This will create DCIM/100TEST/ on ${drives.length} card(s) '
          'with test video files.\n\n'
          'Existing DCIM/100TEST/ folders will be replaced.\n'
          'Other files on the cards will NOT be affected.',
      confirmLabel: 'Prep Cards',
      typedConfirmation: 'prep',
    );
    if (!confirmed || !mounted) return;

    final sourceFolder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder with test video files',
    );
    if (sourceFolder == null) return;

    if (!mounted) return;
    setState(() => _preppingCards = true);
    try {
      final result =
          await driveService.prepTestCards(sourceFolder, drives);
      if (!mounted) return;
      await _showPrepResult(result, drives);
    } finally {
      if (mounted) setState(() => _preppingCards = false);
    }
  }

  Future<void> _showPrepResult(
    ({int cardsPrepped, int filesCopied, List<String> errors}) result,
    List<DetectedDrive> drives,
  ) async {
    if (!mounted) return;

    if (result.filesCopied == 0 && result.errors.isEmpty) {
      final statusColors = Theme.of(context).extension<StatusColors>()!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'No video files (.MOV, .MP4) found in the selected folder'),
          backgroundColor: statusColors.warning,
        ),
      );
      return;
    }

    final filesPerCard = drives.isNotEmpty && result.cardsPrepped > 0
        ? result.filesCopied ~/ result.cardsPrepped
        : 0;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final statusColors = Theme.of(context).extension<StatusColors>()!;
        return AlertDialog(
          title: const Text('Test Cards Prepped'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Prepped ${result.cardsPrepped} card(s) with $filesPerCard test file(s) each.'),
              Text('Total files copied: ${result.filesCopied}'),
              if (result.errors.isNotEmpty) ...[
                const SizedBox(height: Insets.s),
                Text('Errors:', style: TextStyle(color: statusColors.error)),
                ...result.errors.map((e) => Text('• $e',
                    style: TextStyle(
                        fontSize: 12, color: statusColors.error))),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
}

// ── About ───────────────────────────────────────────────────────────

/// T080: app version (single-sourced from pubspec via package_info_plus),
/// "Check for updates" button (existing UpdateService logic), and a
/// link to the GitHub releases page. Version drift between the
/// displayed string and the binary was a v2.3.0 confusion source —
/// PackageInfo.fromPlatform() is the authoritative read.
class _AboutSection extends StatefulWidget {
  const _AboutSection();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  PackageInfo? _info;
  bool _checking = false;
  String? _checkResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: 'About'),
          const SizedBox(height: Insets.l),
          _DiagRow(
            label: 'Application',
            value: _info == null
                ? 'Loading…'
                : '${_info!.appName} ${_info!.version}+${_info!.buildNumber}',
          ),
          const Divider(height: Insets.xl),
          StreamBuilder<AppSetting?>(
            stream: settingsDao.watchSettings(),
            builder: (context, snapshot) {
              final s = snapshot.data;
              return SwitchListTile(
                title: const Text('Check for updates on launch'),
                subtitle: const Text(
                    'Prompts when a new version is available — never auto-installs'),
                value: s?.checkUpdatesOnLaunch ?? true,
                onChanged: (v) => settingsDao.setCheckUpdatesOnLaunch(v),
                contentPadding: EdgeInsets.zero,
              );
            },
          ),
          const SizedBox(height: Insets.m),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _checking ? null : _checkNow,
                icon: _checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('Check for updates'),
              ),
              const SizedBox(width: Insets.m),
              if (_checkResult != null)
                Expanded(
                  child: Text(
                    _checkResult!,
                    style: AppTextStyles.caption.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Insets.l),
          TextButton.icon(
            onPressed: _openReleasesPage,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('View release notes on GitHub'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    // Local instance — UpdateService is dependency-free apart from
    // Dio, which it owns. No reason to wire a global for an
    // operator-triggered, low-frequency check.
    final result = await UpdateService().checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkResult = result.updateAvailable
          ? 'Update available: ${result.latestVersion}'
          : 'You are on the latest version';
    });
  }

  /// Opens the GitHub releases page in the system default browser.
  /// Uses Process.run rather than the url_launcher package so we don't
  /// pull in a Flutter plugin for one operator-initiated tap. The
  /// command set is per-platform.
  Future<void> _openReleasesPage() async {
    const url = 'https://github.com/termenescu97/video-pipeline/releases';
    try {
      if (Platform.isWindows) {
        // `start` is a cmd builtin — invoking via cmd ensures URL
        // arguments are parsed correctly. The empty "" is the window
        // title argument that Windows requires when start is given a
        // URL containing &/? characters.
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open browser: $e')),
      );
    }
  }
}

// ── Shared section primitives ───────────────────────────────────────

/// Small section heading used by every panel — keeps title spacing
/// uniform across sections without re-declaring TextStyle each time.
class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? pill;
  const _SectionTitle({required this.title, this.pill});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: AppTextStyles.headline),
        if (pill != null) ...[
          const SizedBox(width: Insets.s),
          pill!,
        ],
      ],
    );
  }
}

/// Diagnostic row primitive: label on the left, value on the right
/// (mono-font for paths/PIDs when [valueIsMono]), optional [trailing]
/// (e.g., "Reveal in Explorer" button), optional [mutedNote] under
/// the value (e.g., the lock-file path).
class _DiagRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;
  final String? mutedNote;
  final bool valueIsMono;
  final Color? valueColor;

  const _DiagRow({
    required this.label,
    required this.value,
    this.trailing,
    this.mutedNote,
    this.valueIsMono = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(label,
              style: AppTextStyles.body.copyWith(
                color: scheme.onSurfaceVariant,
              )),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: (valueIsMono ? AppTextStyles.mono : AppTextStyles.body)
                    .copyWith(color: valueColor),
              ),
              if (mutedNote != null && mutedNote!.isNotEmpty) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  mutedNote!,
                  style: AppTextStyles.caption.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: Insets.m),
          trailing!,
        ],
      ],
    );
  }
}

/// Compact labeled dropdown for the Behavior section. Presents tuples
/// of `(value, label)` so storage values stay short ('size', 'sha256')
/// while the operator sees friendly labels ('Quick (size match)').
class _LabeledDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T?> onChanged;

  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 240,
          child: Text(label, style: AppTextStyles.body),
        ),
        Expanded(
          child: DropdownButtonFormField<T>(
            initialValue: value,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                  horizontal: 12, vertical: 12),
            ),
            items: items
                .map((e) => DropdownMenuItem<T>(
                      value: e.$1,
                      child: Text(e.$2),
                    ))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
