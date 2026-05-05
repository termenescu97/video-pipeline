import 'package:flutter_test/flutter_test.dart';
import 'package:video_pipeline/app.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const VideoPipelineApp());
    expect(find.text('Video Pipeline'), findsOneWidget);
  });
}
