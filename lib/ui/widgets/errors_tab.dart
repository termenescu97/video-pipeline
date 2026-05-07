import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Errors tab inside DetailTabs (Phase F). Always visible (FR-014); the
/// label shows "(0)" when empty so the operator can scan and confirm
/// "no errors" without clicking. Files come from the parent's single
/// subscription (Phase 7 fix-commit refactor).
class ErrorsTab extends StatelessWidget {
  final List<JobFile> files;

  const ErrorsTab({super.key, required this.files});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final failed =
        files.where((f) => f.status == FileStatus.failed).toList();

    return Builder(
      builder: (context) {
        if (failed.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Insets.l),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 32, color: statusColors.success),
                  const SizedBox(height: Insets.s),
                  Text(
                    'No errors. Every file completed successfully.',
                    style: AppTextStyles.body
                        .copyWith(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.m, vertical: Insets.s),
          itemCount: failed.length,
          itemBuilder: (context, index) {
            final file = failed[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: Insets.s),
              child: Container(
                padding: const EdgeInsets.all(Insets.s),
                decoration: BoxDecoration(
                  color: statusColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: statusColors.error.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 16, color: statusColors.error),
                        const SizedBox(width: Insets.s),
                        Expanded(
                          child: Text(
                            file.fileName,
                            style: AppTextStyles.body,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          formatBytes(file.fileSize),
                          style: AppTextStyles.caption.copyWith(
                              color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    if (file.errorMessage != null) ...[
                      const SizedBox(height: Insets.xs),
                      Text(
                        file.errorMessage!,
                        style: AppTextStyles.caption.copyWith(
                          color: statusColors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

