import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// HandBrake-not-installed warning banner (T107, FR-050). Self-checks
/// HandBrake availability via [compressionService.isHandbrakeInstalled]
/// and renders nothing when HandBrake IS available — so callers can
/// drop it into any column without conditionals.
///
/// Two homes:
///   - HomeScreen's `_WarningBannerSlot` (T108) — primary surface,
///     visible the moment the operator launches the app
///   - CreateJobScreen — original v2.3.0 location, still surfaced
///     near the compression options for proximate context
///
/// Both embeds share THIS widget so the message and styling stay
/// in sync.
class HandBrakeBanner extends StatefulWidget {
  /// `compact: true` strips the surrounding padding/border for use
  /// in HomeScreen's banner slot (where adjacent banners stack
  /// flush). `false` (default) renders with rounded border for use
  /// inside CreateJobScreen's form.
  final bool compact;

  const HandBrakeBanner({super.key, this.compact = false});

  @override
  State<HandBrakeBanner> createState() => _HandBrakeBannerState();
}

/// Process-wide cache of the HandBrake availability probe. Each
/// [HandBrakeBanner] mount used to spawn its own subprocess in
/// initState — fine when only CreateJobScreen had one, but Phase 14
/// added a second mount in HomeScreen's warning slot, doubling the
/// cold-start cost. The first banner that mounts kicks off the probe;
/// every subsequent banner awaits the same Future. Result is cached
/// for the life of the process — installing HandBrake mid-session
/// requires a restart to clear the banner (acceptable: HandBrake
/// installs are rare and operators don't switch them mid-shoot).
Future<bool>? _cachedHandbrakeProbe;

Future<bool> _probeHandbrakeOnce() {
  return _cachedHandbrakeProbe ??= compressionService.isHandbrakeInstalled();
}

class _HandBrakeBannerState extends State<HandBrakeBanner> {
  bool? _installed;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final installed = await _probeHandbrakeOnce();
    if (!mounted) return;
    setState(() => _installed = installed);
  }

  @override
  Widget build(BuildContext context) {
    // Render nothing while we don't know yet, OR when HandBrake is
    // installed. The banner appears only on the bad path.
    if (_installed == null || _installed == true) {
      return const SizedBox.shrink();
    }
    final statusColors = Theme.of(context).extension<StatusColors>()!;

    if (widget.compact) {
      // Slot variant: full-width strip flush with adjacent banners.
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: statusColors.warning.withValues(alpha: 0.15),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                color: statusColors.warning, size: 18),
            const SizedBox(width: Insets.s),
            Expanded(
              child: Text(
                'HandBrake not detected — compression jobs are disabled. '
                'Install from handbrake.fr.',
                style: AppTextStyles.caption
                    .copyWith(color: statusColors.warning),
              ),
            ),
          ],
        ),
      );
    }

    // CreateJobScreen variant: bordered card with full message.
    return Container(
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
    );
  }
}
