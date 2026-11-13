import 'package:test/test.dart';

void main() {
  group('outer [x]', () {
    group('inner', () {
      test('passes (exact)', () {
        var localValue = 40;
        localValue += 2; // BREAKPOINT
        expect(localValue, 42);
      });
      test('passes (exact) sibling', () {
        expect(2 + 2, 4);
      });
      test('fails', () {
        expect('actual', 'expected');
      });
      test('skipped', () {
        fail('a skipped body must not execute');
      }, skip: 'intentional acceptance skip');
    });
  });
}
