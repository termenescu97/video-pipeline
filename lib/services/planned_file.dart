/// 017 (R-A9, T024): consolidated planned-file shape used during preflight,
/// conflict resolution, and job creation. Replaces the duplicated `_PlannedFile`
/// classes that previously lived in both `JobQueueService` and
/// `CreateJobScreen` (a v2.4.0 load-bearing convention CLAUDE.md flagged for
/// consolidation).
///
/// Immutable: all fields are `final`. Updates produced via [copyWith] —
/// supports rename (new `destinationPath`) and post-preflight overwrite-
/// approval stamping (`wasOverwriteApproved=true`) without mutating the
/// original instance. Codex M7: contract test in `test/contract/`
/// fails fast on any divergence.
class PlannedFile {
  /// Absolute path on the source filesystem (SD card / NAS / external HDD).
  final String sourcePath;

  /// Absolute path under the operator-chosen destination root. Includes the
  /// per-card subfolder and the relative path preserved from the source's
  /// drive root (013: prevents cross-card collisions).
  final String destinationPath;

  /// Display name for UI rendering, derived from [sourcePath] basename.
  final String fileName;

  /// Size in bytes (read at preflight; used for free-space verdict and
  /// for post-copy size verification).
  final int fileSize;

  /// 015: stamped `true` by `CreateJobScreen._applyResolution` when the
  /// operator chose `Overwrite` AND this file's destination existed at
  /// preflight time. The executor honors the flag absolutely (delete
  /// dest pre-robocopy regardless of size) — see Codex H2 / R-A1.
  /// Default `false` is the safe baseline.
  final bool wasOverwriteApproved;

  const PlannedFile({
    required this.sourcePath,
    required this.destinationPath,
    required this.fileName,
    required this.fileSize,
    this.wasOverwriteApproved = false,
  });

  /// Returns a new instance with selected fields overridden. Used by:
  /// - rename suffix generation (new `destinationPath`)
  /// - post-preflight overwrite stamping (`wasOverwriteApproved=true`)
  PlannedFile copyWith({
    String? destinationPath,
    bool? wasOverwriteApproved,
  }) {
    return PlannedFile(
      sourcePath: sourcePath,
      destinationPath: destinationPath ?? this.destinationPath,
      fileName: fileName,
      fileSize: fileSize,
      wasOverwriteApproved: wasOverwriteApproved ?? this.wasOverwriteApproved,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlannedFile &&
          sourcePath == other.sourcePath &&
          destinationPath == other.destinationPath &&
          fileName == other.fileName &&
          fileSize == other.fileSize &&
          wasOverwriteApproved == other.wasOverwriteApproved;

  @override
  int get hashCode => Object.hash(
        sourcePath,
        destinationPath,
        fileName,
        fileSize,
        wasOverwriteApproved,
      );

  @override
  String toString() =>
      'PlannedFile(source=$sourcePath, dest=$destinationPath, '
      'fileName=$fileName, size=$fileSize, '
      'overwriteApproved=$wasOverwriteApproved)';
}
