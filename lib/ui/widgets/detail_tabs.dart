import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../theme/insets.dart';
import 'audit_tab.dart';
import 'errors_tab.dart';
import 'files_tab.dart';

/// Inline detail container shown inside expanded job cards (FR-013).
/// Three always-visible tabs (FR-014): Files (count) / Audit / Errors (count).
/// The Errors tab label shows "Errors (N)" including "(0)" when empty so
/// operators can scan-confirm "no errors" without clicking.
///
/// Owns a SINGLE `watchFilesForJob` subscription and passes the resolved
/// `List<JobFile>` to each tab — avoids duplicate streams across the three
/// tab views (review-fix from Phase 7's Codex review).
///
/// Variant policy:
///   - Active / Queued / Next-up cards open with the Files tab selected.
///   - Done cards open with the Audit tab selected (history-friendly).
class DetailTabs extends StatelessWidget {
  final Job job;
  final int initialTabIndex;

  const DetailTabs({
    super.key,
    required this.job,
    this.initialTabIndex = 0,
  });

  /// Convenience constructor: Done cards default to Audit (index 1).
  const DetailTabs.forDone({super.key, required this.job})
      : initialTabIndex = 1;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<JobFile>>(
      stream: jobFileDao.watchFilesForJob(job.id),
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <JobFile>[];
        final failedCount =
            files.where((f) => f.status == FileStatus.failed).length;
        final totalCount = files.length;

        return DefaultTabController(
          length: 3,
          initialIndex: initialTabIndex,
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                        color: scheme.outlineVariant, width: 1),
                  ),
                ),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding: const EdgeInsets.symmetric(
                      horizontal: Insets.m),
                  tabs: [
                    Tab(text: 'Files ($totalCount)'),
                    const Tab(text: 'Audit'),
                    Tab(text: 'Errors ($failedCount)'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    FilesTab(files: files),
                    AuditTab(job: job, files: files),
                    ErrorsTab(files: files),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
