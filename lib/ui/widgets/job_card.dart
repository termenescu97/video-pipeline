import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import 'job_card_active.dart';
import 'job_card_done.dart';
import 'job_card_next_up.dart';
import 'job_card_queued.dart';

/// Router widget that picks the right job-card variant based on [job.status]
/// and queue context (whether this job is the "next up" hero — set by the
/// parent list when this is the first queued job and nothing is currently
/// running).
///
/// Variants:
///  - [JobCardActive]  — hero, currently running
///  - [JobCardNextUp]  — hero, first queued when nothing is running
///  - [JobCardQueued]  — slim row with drag handle
///  - [JobCardDone]    — dimmed compact row (history)
class JobCard extends StatelessWidget {
  final Job job;
  final bool isNextUp;
  final bool isExpanded;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  const JobCard({
    super.key,
    required this.job,
    this.isNextUp = false,
    this.isExpanded = false,
    this.onTap,
    this.onDelete,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    switch (job.status) {
      case JobStatus.inProgress:
        return JobCardActive(
          job: job,
          isExpanded: isExpanded,
          onTap: onTap,
          onDelete: onDelete,
        );
      case JobStatus.completed:
      case JobStatus.failed:
        return JobCardDone(
          job: job,
          isExpanded: isExpanded,
          onTap: onTap,
          onDelete: onDelete,
          onRetry: onRetry,
        );
      case JobStatus.queued:
      case JobStatus.paused:
        if (isNextUp) {
          return JobCardNextUp(
            job: job,
            isExpanded: isExpanded,
            onTap: onTap,
            onDelete: onDelete,
          );
        }
        return JobCardQueued(
          job: job,
          isExpanded: isExpanded,
          onTap: onTap,
          onDelete: onDelete,
        );
    }
  }
}
