import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/models/ledger_activity_stats.dart';

void main() {
  group('LedgerActivityStats', () {
    final today = DateTime(2026, 10, 9);

    test('counts a current streak through today and yesterday', () {
      expect(
        LedgerActivityStats.currentStreak(
          [
            DateTime(2026, 10, 7, 8),
            DateTime(2026, 10, 8, 18),
            DateTime(2026, 10, 9, 9),
          ],
          today: today,
        ),
        3,
      );
    });

    test('keeps a streak alive when the latest entry was yesterday', () {
      expect(
        LedgerActivityStats.currentStreak(
          [DateTime(2026, 10, 8, 22)],
          today: today,
        ),
        1,
      );
    });

    test('ends the current streak after a full missed day', () {
      expect(
        LedgerActivityStats.currentStreak(
          [DateTime(2026, 10, 7)],
          today: today,
        ),
        0,
      );
    });

    test('ignores future dates and duplicate entries on one day', () {
      final dates = [
        DateTime(2026, 10, 8, 8),
        DateTime(2026, 10, 8, 20),
        DateTime(2026, 10, 9, 8),
        DateTime(2026, 10, 10),
      ];

      expect(
        LedgerActivityStats.currentStreak(dates, today: today),
        2,
      );
      expect(LedgerActivityStats.uniqueRecordingDays(dates), 3);
    });

    test('returns zero with no recorded days', () {
      expect(LedgerActivityStats.currentStreak([], today: today), 0);
      expect(LedgerActivityStats.uniqueRecordingDays([]), 0);
    });
  });
}
