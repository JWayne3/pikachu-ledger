import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/models/ledger_entry.dart';
import 'package:ledger_app/screens/ledger_statistics_page.dart';

void main() {
  final entries = [
    LedgerEntry(
      type: EntryType.expense,
      amountCents: 12345,
      category: '餐饮',
      date: DateTime(2026, 10, 8),
      note: '午餐',
    ),
    LedgerEntry(
      type: EntryType.expense,
      amountCents: 5000,
      category: '交通',
      date: DateTime(2026, 10, 7),
    ),
    LedgerEntry(
      type: EntryType.income,
      amountCents: 300000,
      category: '工资',
      date: DateTime(2026, 10, 1),
    ),
  ];

  Widget statisticsPage() => MaterialApp(
    home: Scaffold(
      body: LedgerStatisticsPage(
        entries: entries,
        initialDate: DateTime(2026, 10, 9),
        monthlyBudget: null,
        onEditMonthlyBudget: () {},
        onClearMonthlyBudget: () {},
      ),
    ),
  );

  testWidgets('statistics page renders period trends and category breakdown', (
    tester,
  ) async {
    await tester.pumpWidget(statisticsPage());

    expect(find.text('周'), findsOneWidget);
    expect(find.text('月'), findsOneWidget);
    expect(find.text('年'), findsOneWidget);
    expect(find.text('2026年10月'), findsOneWidget);

    final categoryBreakdown = find.text('分类构成');
    await tester.scrollUntilVisible(
      categoryBreakdown,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('分类构成'), findsOneWidget);
    expect(find.text('餐饮'), findsAtLeastNWidgets(1));
    expect(find.text('交通'), findsAtLeastNWidgets(1));

    await tester.drag(
      find.byType(Scrollable).first,
      const Offset(0, 1200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    expect(find.text('2026年'), findsOneWidget);
  });

  testWidgets('monthly and yearly report pages render their summaries', (
    tester,
  ) async {
    await tester.pumpWidget(statisticsPage());

    final scrollable = find.byType(Scrollable).first;
    final monthlyReportButton = find.text('查看月度账单总结');
    await tester.scrollUntilVisible(
      monthlyReportButton,
      600,
      scrollable: scrollable,
    );
    await tester.tap(monthlyReportButton);
    await tester.pumpAndSettle();

    expect(find.text('2026年10月账单'), findsOneWidget);
    expect(find.text('账单结余'), findsOneWidget);
    expect(find.text('支出指标'), findsOneWidget);

    final reportScrollable = find.byType(Scrollable).first;
    for (final label in ['支出构成', '月支出对比', '记账成就']) {
      await tester.scrollUntilVisible(
        find.text(label),
        600,
        scrollable: reportScrollable,
      );
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('已连续记账'), findsOneWidget);
    expect(find.text('累计账单笔数'), findsOneWidget);

    await tester.drag(reportScrollable, const Offset(0, 1600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('年账单'));
    await tester.pumpAndSettle();
    expect(find.text('2026年账单'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('年度支出指标'),
      600,
      scrollable: reportScrollable,
    );
    expect(find.text('年度支出指标'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('年度支出对比'),
      600,
      scrollable: reportScrollable,
    );
    expect(find.text('年度支出对比'), findsOneWidget);
  });
}
