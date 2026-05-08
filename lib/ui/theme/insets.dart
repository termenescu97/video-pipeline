/// Centralized spacing scale used in place of literal `SizedBox` / `EdgeInsets`
/// values throughout the UI. Primary scale is 4/8/12/16/24/32 (xs..xxl) for
/// desktop density.
///
/// [xxs] = 2 is reserved for tight label-to-value micro-pairings inside
/// rows (e.g., `src: HASH` stacked on `dst: HASH`) where the larger
/// xs spacing would visually break the pair. Don't reach for it for
/// general layout — if you find yourself using xxs outside a paired
/// row, the surrounding stack probably wants xs instead.
class Insets {
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double s = 8.0;
  static const double m = 12.0;
  static const double l = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
}
