import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('outer [x]', () {
    group('inner', () {
      testWidgets('passes (exact)', (tester) async {
        var localValue = 40;
        localValue += 2; // BREAKPOINT
        await tester.pumpWidget(
          Text('$localValue', textDirection: TextDirection.ltr),
        );
        expect(find.text('42'), findsOneWidget);
      });
      testWidgets('passes (exact) sibling', (tester) async {
        await tester.pumpWidget(const SizedBox());
        expect(find.byType(SizedBox), findsOneWidget);
      });
      testWidgets('fails', (tester) async {
        await tester.pumpWidget(const SizedBox());
        expect(find.text('missing'), findsOneWidget);
      });
      testWidgets('skipped', (tester) async {
        fail('a skipped body must not execute');
      }, skip: true);
    });
  });
}
