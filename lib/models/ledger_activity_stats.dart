class LedgerActivityStats {
  const LedgerActivityStats._();

  static int uniqueRecordingDays(Iterable<DateTime> dates) => dates
      .map(_calendarDay)
      .toSet()
      .length;

  static int currentStreak(Iterable<DateTime> dates, {DateTime? today}) {
    final currentDay = _calendarDay(today ?? DateTime.now());
    final recordedDays = dates
        .map(_calendarDay)
        .where((day) => !day.isAfter(currentDay))
        .toSet();
    if (recordedDays.isEmpty) return 0;

    final latestDay = recordedDays.reduce(
      (latest, day) => day.isAfter(latest) ? day : latest,
    );
    if (currentDay.difference(latestDay).inDays > 1) return 0;

    var streak = 0;
    var day = latestDay;
    while (recordedDays.contains(day)) {
      streak++;
      day = DateTime.utc(day.year, day.month, day.day - 1);
    }
    return streak;
  }

  static DateTime _calendarDay(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day);
}
