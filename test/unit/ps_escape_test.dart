import 'package:flutter_test/flutter_test.dart';

import 'package:video_pipeline/utils/ps_escape.dart';

void main() {
  group('escapePsLiteral (FR-001)', () {
    test('passes through ASCII alphanumerics + standard separators', () {
      expect(escapePsLiteral('foo'), 'foo');
      expect(escapePsLiteral('E:\\Studio Termene\\file.MOV'),
          'E:\\Studio Termene\\file.MOV');
      expect(escapePsLiteral('H:\\DCIM\\154_0430\\MVI_0089.MP4'),
          'H:\\DCIM\\154_0430\\MVI_0089.MP4');
    });

    test('doubles ASCII apostrophes (the only PS-special char in literals)',
        () {
      expect(escapePsLiteral("Tibi's reels.mp4"), "Tibi''s reels.mp4");
      expect(escapePsLiteral("'leading"), "''leading");
      expect(escapePsLiteral("trailing'"), "trailing''");
      expect(escapePsLiteral("''"), "''''");
      expect(escapePsLiteral("a'b'c"), "a''b''c");
    });

    test('passes through PS-meaningful chars (safe inside single-quoted literal)',
        () {
      // Inside a PS single-quoted string, NONE of these are special.
      expect(escapePsLiteral(r'IMG_[001].MP4'), r'IMG_[001].MP4');
      expect(escapePsLiteral(r'Ep. 60-63 *.MP4'), r'Ep. 60-63 *.MP4');
      expect(escapePsLiteral('file?.MP4'), 'file?.MP4');
      expect(escapePsLiteral(r'back`tick.MP4'), r'back`tick.MP4');
      expect(escapePsLiteral(r'dollar$.MP4'), r'dollar$.MP4');
      expect(escapePsLiteral('semi;colon.MP4'), 'semi;colon.MP4');
      expect(escapePsLiteral('amp&ersand.MP4'), 'amp&ersand.MP4');
    });

    test('passes through Unicode smart quotes (U+2018, U+2019)', () {
      // PowerShell only recognizes ASCII U+0027 (') as the literal delimiter.
      // Smart quotes pass through unchanged.
      expect(escapePsLiteral('Tibi’s reels.mp4'), 'Tibi’s reels.mp4');
      expect(escapePsLiteral('‘quoted’.mp4'),
          '‘quoted’.mp4');
    });

    test('passes through paths longer than Windows MAX_PATH (260 chars)', () {
      final longPath =
          r'E:\Studio Termene\Brut - To compress\test\Canon_Reels_H\DCIM\154_0430\very_long_filename_with_padding'
          .padRight(280, 'x');
      expect(longPath.length, greaterThan(260));
      expect(escapePsLiteral(longPath), longPath);
    });

    test('handles empty string (caller responsibility to validate upstream)',
        () {
      // escapePsLiteral itself is total; emptiness is a caller-side concern.
      expect(escapePsLiteral(''), '');
    });

    test('handles paths with non-BMP code points (emoji in filename)', () {
      // Emojis use surrogate pairs in UTF-16. .replaceAll on Dart's String
      // operates on UTF-16 code units; the apostrophe is a single code unit
      // so surrogate pairs are unaffected.
      const emoji = '\u{1F4F7}'; // 📷 camera emoji
      expect(escapePsLiteral('photo_$emoji-2026.JPG'),
          'photo_$emoji-2026.JPG');
      expect(escapePsLiteral("photo_$emoji's_2026.JPG"),
          "photo_$emoji''s_2026.JPG");
    });
  });
}
