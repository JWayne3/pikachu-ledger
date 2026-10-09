import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/ledger_activity_stats.dart';
import '../models/ledger_categories.dart';
import '../models/ledger_entry.dart';
import '../services/tap_sound_service.dart';
import '../widgets/ledger_charts.dart';

enum LedgerPeriod { week, month, year }

class LedgerStatisticsPage extends StatefulWidget {
  const LedgerStatisticsPage({
    required this.entries,
    required this.initialDate,
    required this.monthlyBudget,
    required this.onEditMonthlyBudget,
    required this.onClearMonthlyBudget,
    super.key,
  });

  final List<LedgerEntry> entries;
  final DateTime initialDate;
  final int? monthlyBudget;
  final VoidCallback onEditMonthlyBudget;
  final VoidCallback onClearMonthlyBudget;

  @override
  State<LedgerStatisticsPage> createState() => _LedgerStatisticsPageState();
}

class _LedgerStatisticsPageState extends State<LedgerStatisticsPage> {
  LedgerPeriod _period = LedgerPeriod.month;
  EntryType _type = EntryType.expense;
  late DateTime _anchor = DateTime(
    widget.initialDate.year,
    widget.initialDate.month,
    widget.initialDate.day,
  );

  DateTime get _start {
    switch (_period) {
      case LedgerPeriod.week:
        final date = DateTime(_anchor.year, _anchor.month, _anchor.day);
        return date.subtract(Duration(days: date.weekday - 1));
      case LedgerPeriod.month:
        return DateTime(_anchor.year, _anchor.month);
      case LedgerPeriod.year:
        return DateTime(_anchor.year);
    }
  }

  DateTime get _end => switch (_period) {
    LedgerPeriod.week => _start.add(const Duration(days: 7)),
    LedgerPeriod.month => DateTime(_start.year, _start.month + 1),
    LedgerPeriod.year => DateTime(_start.year + 1),
  };

  List<LedgerEntry> get _periodEntries => widget.entries
      .where(
        (entry) => !entry.date.isBefore(_start) && entry.date.isBefore(_end),
      )
      .toList(growable: false);

  int _total(Iterable<LedgerEntry> entries, EntryType type) => entries
      .where((entry) => entry.type == type)
      .fold(0, (sum, entry) => sum + entry.amountCents);

  @override
  void didUpdateWidget(covariant LedgerStatisticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialDate != widget.initialDate) {
      _anchor = DateTime(
        widget.initialDate.year,
        widget.initialDate.month,
        widget.initialDate.day,
      );
    }
  }

  void _movePeriod(int amount) {
    setState(() {
      _anchor = switch (_period) {
        LedgerPeriod.week => _anchor.add(Duration(days: amount * 7)),
        LedgerPeriod.month => DateTime(_anchor.year, _anchor.month + amount, 1),
        LedgerPeriod.year => DateTime(_anchor.year + amount, _anchor.month, 1),
      };
    });
  }

  List<LedgerChartPoint> _trendPoints(EntryType type) {
    final data = _periodEntries.where((entry) => entry.type == type);
    final values = <int, int>{};
    if (_period == LedgerPeriod.year) {
      for (final entry in data) {
        values.update(
          entry.date.month,
          (amount) => amount + entry.amountCents,
          ifAbsent: () => entry.amountCents,
        );
      }
      return List.generate(12, (index) {
        final month = index + 1;
        return LedgerChartPoint(label: '$month月', value: values[month] ?? 0);
      });
    }

    final days = _period == LedgerPeriod.week
        ? 7
        : _end.difference(_start).inDays;
    for (final entry in data) {
      final index = DateTime(
        entry.date.year,
        entry.date.month,
        entry.date.day,
      ).difference(_start).inDays;
      values.update(
        index,
        (amount) => amount + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    return List.generate(days, (index) {
      final day = _start.add(Duration(days: index));
      final label = _period == LedgerPeriod.week
          ? const ['一', '二', '三', '四', '五', '六', '日'][day.weekday - 1]
          : day.day.toString().padLeft(2, '0');
      return LedgerChartPoint(label: label, value: values[index] ?? 0);
    });
  }

  Map<String, int> _categoryTotals(EntryType type) {
    final result = <String, int>{};
    for (final entry in _periodEntries.where((entry) => entry.type == type)) {
      result.update(
        entry.category,
        (value) => value + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    return result;
  }

  String get _periodLabel => switch (_period) {
    LedgerPeriod.week =>
      '${_dateLabel(_start)} – ${_dateLabel(_end.subtract(const Duration(days: 1)))}',
    LedgerPeriod.month => '${_start.year}年${_start.month}月',
    LedgerPeriod.year => '${_start.year}年',
  };

  @override
  Widget build(BuildContext context) {
    final income = _total(_periodEntries, EntryType.income);
    final expense = _total(_periodEntries, EntryType.expense);
    final amount = _total(_periodEntries, _type);
    final activeDays = _periodEntries
        .where((entry) => entry.type == _type)
        .map((entry) => _dayKey(entry.date))
        .toSet()
        .length;
    final average = activeDays == 0 ? 0 : (amount / activeDays).round();
    final categoryTotals = _categoryTotals(_type);
    final sortedCategories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final showBudget =
        _period == LedgerPeriod.month &&
        _start.year == widget.initialDate.year &&
        _start.month == widget.initialDate.month;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _periodSelector(),
        const SizedBox(height: 8),
        _periodNavigator(),
        const SizedBox(height: 12),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  DropdownButton<EntryType>(
                    value: _type,
                    underline: const SizedBox.shrink(),
                    items: EntryType.values
                        .map(
                          (type) => DropdownMenuItem(
                            value: type,
                            child: Text(type.label),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (type) {
                      if (type != null) {
                        TapSoundService.playSelectionDing();
                        setState(() => _type = type);
                      }
                    },
                  ),
                  const Spacer(),
                  Text(
                    '${_periodEntries.length} 笔账单',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
              Text(
                _money(amount),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '日均 ${_money(average)} · $activeDays 天有${_type.label}',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
              ),
              const SizedBox(height: 12),
              LedgerTrendChart(
                points: _trendPoints(_type),
                color: _type == EntryType.expense
                    ? const Color(0xFFE2AC00)
                    : const Color(0xFF318365),
              ),
            ],
          ),
        ),
        if (showBudget) ...[const SizedBox(height: 10), _budgetCard(expense)],
        const SizedBox(height: 12),
        _periodTotalsCard(income, expense),
        const SizedBox(height: 12),
        _categoryCard(sortedCategories, amount),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: TapSoundService.withUiClick(
            () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LedgerPeriodReportPage(
                  entries: widget.entries,
                  initialDate: _anchor,
                  initialPeriod: _period == LedgerPeriod.year
                      ? LedgerPeriod.year
                      : LedgerPeriod.month,
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.insights_outlined),
          label: Text(_period == LedgerPeriod.year ? '查看年度账单总结' : '查看月度账单总结'),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
        ),
      ],
    );
  }

  Widget _periodSelector() => SegmentedButton<LedgerPeriod>(
    segments: const [
      ButtonSegment(value: LedgerPeriod.week, label: Text('周')),
      ButtonSegment(value: LedgerPeriod.month, label: Text('月')),
      ButtonSegment(value: LedgerPeriod.year, label: Text('年')),
    ],
    selected: {_period},
    onSelectionChanged: TapSoundService.withUiClickValue(
      (selection) => setState(() => _period = selection.first),
    ),
  );

  Widget _periodNavigator() => Row(
    children: [
      IconButton(
        tooltip: '上一${_period.label}',
        onPressed: TapSoundService.withUiClick(() => _movePeriod(-1)),
        icon: const Icon(Icons.chevron_left),
      ),
      Expanded(
        child: Center(
          child: Text(
            _periodLabel,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      IconButton(
        tooltip: '下一${_period.label}',
        onPressed: TapSoundService.withUiClick(() => _movePeriod(1)),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  Widget _periodTotalsCard(int income, int expense) => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('收支概览', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _amountRow('收入', income, const Color(0xFF318365)),
        const SizedBox(height: 8),
        _amountRow('支出', expense, const Color(0xFFE2AC00)),
        const Divider(height: 22),
        _amountRow('结余', income - expense, const Color(0xFF4A514D)),
      ],
    ),
  );

  Widget _categoryCard(List<MapEntry<String, int>> categories, int total) {
    if (categories.isEmpty) {
      return _card(
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 22),
          child: Center(child: Text('这个时段还没有收支分类数据')),
        ),
      );
    }
    final values = Map<String, int>.fromEntries(categories);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('分类构成', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              LedgerDonutChart(
                values: values,
                colorFor: LedgerCategories.color,
                centerLabel: _type.label,
                centerValue: _money(total),
                size: 142,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  children: categories
                      .take(6)
                      .map((entry) {
                        final ratio = total == 0 ? 0.0 : entry.value / total;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: LedgerCategories.color(entry.key),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  entry.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              Text(
                                '${(ratio * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        );
                      })
                      .toList(growable: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Divider(),
          for (final entry in categories)
            _categoryRow(entry.key, entry.value, total),
        ],
      ),
    );
  }

  Widget _budgetCard(int expense) => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('月预算', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: TapSoundService.withUiClick(
                widget.onEditMonthlyBudget,
              ),
              child: Text(widget.monthlyBudget == null ? '设置' : '调整'),
            ),
            if (widget.monthlyBudget != null)
              IconButton(
                tooltip: '清除预算',
                onPressed: TapSoundService.withUiClick(
                  widget.onClearMonthlyBudget,
                ),
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
        if (widget.monthlyBudget == null)
          Text(
            '设置预算后，可查看本月支出进度。',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          )
        else ...[
          Text('${_money(expense)} / ${_money(widget.monthlyBudget!)}'),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: (expense / widget.monthlyBudget!).clamp(0.0, 1.0),
              minHeight: 8,
              color: expense > widget.monthlyBudget!
                  ? Colors.red
                  : const Color(0xFF318365),
              backgroundColor: const Color(0xFFECECEC),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            expense > widget.monthlyBudget!
                ? '已超出 ${_money(expense - widget.monthlyBudget!)}'
                : '还可支出 ${_money(widget.monthlyBudget! - expense)}',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ],
    ),
  );

  Widget _amountRow(String label, int amount, Color color) => Row(
    children: [
      Expanded(
        child: Text(label, style: TextStyle(color: Colors.grey.shade700)),
      ),
      Text(
        _money(amount),
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget _categoryRow(String category, int value, int total) {
    final ratio = total == 0 ? 0.0 : value / total;
    final color = LedgerCategories.color(category);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Icon(LedgerCategories.icon(category), size: 19, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(category)),
              Text(
                '${(ratio * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: Colors.grey.shade600),
              ),
              const SizedBox(width: 12),
              Text(
                _money(value),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class LedgerPeriodReportPage extends StatefulWidget {
  const LedgerPeriodReportPage({
    required this.entries,
    required this.initialDate,
    required this.initialPeriod,
    super.key,
  });

  final List<LedgerEntry> entries;
  final DateTime initialDate;
  final LedgerPeriod initialPeriod;

  @override
  State<LedgerPeriodReportPage> createState() => _LedgerPeriodReportPageState();
}

class _LedgerPeriodReportPageState extends State<LedgerPeriodReportPage> {
  late LedgerPeriod _period = widget.initialPeriod;
  late DateTime _anchor = widget.initialDate;

  DateTime get _start => _period == LedgerPeriod.year
      ? DateTime(_anchor.year)
      : DateTime(_anchor.year, _anchor.month);
  DateTime get _end => _period == LedgerPeriod.year
      ? DateTime(_start.year + 1)
      : DateTime(_start.year, _start.month + 1);
  DateTime get _previousStart => _period == LedgerPeriod.year
      ? DateTime(_start.year - 1)
      : DateTime(_start.year, _start.month - 1);
  DateTime get _previousEnd => _start;

  List<LedgerEntry> _within(DateTime start, DateTime end) => widget.entries
      .where((entry) => !entry.date.isBefore(start) && entry.date.isBefore(end))
      .toList(growable: false);

  List<LedgerEntry> get _entries => _within(_start, _end);
  List<LedgerEntry> get _previousEntries =>
      _within(_previousStart, _previousEnd);

  int _total(Iterable<LedgerEntry> entries, EntryType type) => entries
      .where((entry) => entry.type == type)
      .fold(0, (sum, entry) => sum + entry.amountCents);

  Map<String, int> _categoryTotals(Iterable<LedgerEntry> entries) {
    final values = <String, int>{};
    for (final entry in entries.where(
      (item) => item.type == EntryType.expense,
    )) {
      values.update(
        entry.category,
        (amount) => amount + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    return values;
  }

  Map<DateTime, int> _dailyExpense(Iterable<LedgerEntry> entries) {
    final values = <DateTime, int>{};
    for (final entry in entries.where(
      (item) => item.type == EntryType.expense,
    )) {
      final day = DateTime(entry.date.year, entry.date.month, entry.date.day);
      values.update(
        day,
        (amount) => amount + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    return values;
  }

  List<LedgerChartPoint> _comparisonPoints() {
    if (_period == LedgerPeriod.year) {
      return List.generate(6, (index) {
        final year = _start.year - 5 + index;
        final entries = _within(DateTime(year), DateTime(year + 1));
        return LedgerChartPoint(
          label: '${year.toString().substring(2)}年',
          value: _total(entries, EntryType.expense),
        );
      });
    }
    return List.generate(6, (index) {
      final month = DateTime(_start.year, _start.month - 5 + index);
      final entries = _within(month, DateTime(month.year, month.month + 1));
      return LedgerChartPoint(
        label: '${month.month}月',
        value: _total(entries, EntryType.expense),
      );
    });
  }

  List<LedgerChartPoint> _dailyPoints() {
    final days = _end.difference(_start).inDays;
    final values = _dailyExpense(_entries);
    return List.generate(days, (index) {
      final date = _start.add(Duration(days: index));
      return LedgerChartPoint(
        label: date.day.toString().padLeft(2, '0'),
        value: values[date] ?? 0,
      );
    });
  }

  List<LedgerChartPoint> _monthlyPoints() {
    final values = <int, int>{};
    for (final entry in _entries.where(
      (item) => item.type == EntryType.expense,
    )) {
      values.update(
        entry.date.month,
        (amount) => amount + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    return List.generate(12, (index) {
      final month = index + 1;
      return LedgerChartPoint(label: '$month月', value: values[month] ?? 0);
    });
  }

  List<LedgerEntry> get _topExpenses {
    final result =
        _entries.where((entry) => entry.type == EntryType.expense).toList()
          ..sort((a, b) => b.amountCents.compareTo(a.amountCents));
    return result.take(5).toList(growable: false);
  }

  void _move(int amount) {
    setState(() {
      _anchor = _period == LedgerPeriod.year
          ? DateTime(_anchor.year + amount, 1)
          : DateTime(_anchor.year, _anchor.month + amount, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final income = _total(_entries, EntryType.income);
    final expense = _total(_entries, EntryType.expense);
    final priorIncome = _total(_previousEntries, EntryType.income);
    final priorExpense = _total(_previousEntries, EntryType.expense);
    final categoryTotals = _categoryTotals(_entries);
    final categories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final balance = income - expense;
    final priorBalance = priorIncome - priorExpense;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _period == LedgerPeriod.year
              ? '${_start.year}年账单'
              : '${_start.year}年${_start.month}月账单',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          SegmentedButton<LedgerPeriod>(
            segments: const [
              ButtonSegment(value: LedgerPeriod.month, label: Text('月账单')),
              ButtonSegment(value: LedgerPeriod.year, label: Text('年账单')),
            ],
            selected: {_period},
            onSelectionChanged: TapSoundService.withUiClickValue(
              (selection) => setState(() => _period = selection.first),
            ),
          ),
          const SizedBox(height: 8),
          _reportNavigator(),
          const SizedBox(height: 10),
          _balanceCard(balance, priorBalance, income, expense),
          const SizedBox(height: 12),
          _metricCard(),
          const SizedBox(height: 12),
          _card(
            title: '支出构成',
            child: categories.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text('这个时段还没有支出记录'),
                    ),
                  )
                : Column(
                    children: [
                      Row(
                        children: [
                          LedgerDonutChart(
                            values: categoryTotals,
                            colorFor: LedgerCategories.color,
                            centerLabel: '总支出',
                            centerValue: _money(expense),
                            size: 168,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _categoryLegend(categories.take(5), expense),
                          ),
                        ],
                      ),
                      const Divider(),
                      for (final item in categories)
                        _categoryAmountRow(item.key, item.value, expense),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _card(
            title: _period == LedgerPeriod.month ? '支出趋势' : '月支出趋势',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_period == LedgerPeriod.month)
                  _dailyMetricRow()
                else
                  _yearMetricRow(),
                const SizedBox(height: 12),
                LedgerTrendChart(
                  points: _period == LedgerPeriod.month
                      ? _dailyPoints()
                      : _monthlyPoints(),
                  color: const Color(0xFFE2AC00),
                  height: 208,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            title: _period == LedgerPeriod.month ? '月支出对比' : '年度支出对比',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LedgerBarChart(
                  points: _comparisonPoints(),
                  color: const Color(0xFFFFD34E),
                  height: 220,
                ),
                const SizedBox(height: 8),
                Text(
                  _period == LedgerPeriod.month
                      ? '${_start.month}月对比上月变化最大的分类'
                      : '${_start.year}年对比上一年变化最大的分类',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
                const SizedBox(height: 8),
                ..._categoryChanges().map(_categoryChangeRow),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            title: '本期大额支出',
            trailing: '${_topExpenses.length} 笔',
            child: _topExpenses.isEmpty
                ? const Text('这个时段还没有支出记录')
                : Column(
                    children: [
                      for (var index = 0; index < _topExpenses.length; index++)
                        _expenseEntryRow(index + 1, _topExpenses[index]),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _achievementCard(),
        ],
      ),
    );
  }

  Widget _reportNavigator() => Row(
    children: [
      IconButton(
        onPressed: TapSoundService.withUiClick(() => _move(-1)),
        icon: const Icon(Icons.chevron_left),
      ),
      Expanded(
        child: Center(
          child: Text(
            _period == LedgerPeriod.year
                ? '${_start.year}年'
                : '${_start.year}年${_start.month}月',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      IconButton(
        onPressed: TapSoundService.withUiClick(() => _move(1)),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  Widget _balanceCard(int balance, int priorBalance, int income, int expense) =>
      _card(
        title: '账单结余',
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _bigMetric('本期结余', balance, const Color(0xFF302607)),
                ),
                Expanded(child: _bigMetric('上期结余', priorBalance, Colors.grey)),
              ],
            ),
            const SizedBox(height: 18),
            _amountBar(
              '支出',
              expense,
              income + expense,
              const Color(0xFFFFD34E),
            ),
            const SizedBox(height: 9),
            _amountBar('收入', income, income + expense, const Color(0xFF75B99A)),
          ],
        ),
      );

  Widget _metricCard() {
    final expenses = _dailyExpense(_entries);
    if (_period == LedgerPeriod.month) {
      final maxDay = expenses.entries.isEmpty
          ? null
          : expenses.entries.reduce((a, b) => a.value >= b.value ? a : b);
      final dayCount = _end.difference(_start).inDays;
      final average = dayCount == 0
          ? 0
          : (_total(_entries, EntryType.expense) / dayCount).round();
      return _card(
        title: '支出指标',
        child: Row(
          children: [
            Expanded(
              child: _kpi(
                '单日支出最高',
                maxDay?.value ?? 0,
                maxDay == null
                    ? '暂无记录'
                    : '${maxDay.key.month}月${maxDay.key.day}日',
              ),
            ),
            Expanded(child: _kpi('日均支出', average, '按自然日计算')),
            Expanded(
              child: _kpi('本月支出', _total(_entries, EntryType.expense), ''),
            ),
          ],
        ),
      );
    }
    final monthly = _monthlyPoints();
    final peak = monthly.reduce((a, b) => a.value >= b.value ? a : b);
    final average = (_total(_entries, EntryType.expense) / 12).round();
    return _card(
      title: '年度支出指标',
      child: Row(
        children: [
          Expanded(child: _kpi('支出最高月份', peak.value, peak.label)),
          Expanded(child: _kpi('月均支出', average, '按 12 个月计算')),
          Expanded(
            child: _kpi('年度支出', _total(_entries, EntryType.expense), ''),
          ),
        ],
      ),
    );
  }

  Widget _dailyMetricRow() {
    final daily = _dailyExpense(_entries);
    final peak = daily.entries.isEmpty
        ? null
        : daily.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final average =
        _total(_entries, EntryType.expense) / _end.difference(_start).inDays;
    return Row(
      children: [
        Expanded(
          child: _metricValue(
            '单日最高',
            peak?.value ?? 0,
            peak == null ? '暂无' : '${peak.key.month}月${peak.key.day}日',
          ),
        ),
        Expanded(child: _metricValue('日均支出', average.round(), '按自然日计算')),
        Expanded(
          child: _metricValue('本月支出', _total(_entries, EntryType.expense), ''),
        ),
      ],
    );
  }

  Widget _yearMetricRow() => Row(
    children: [
      Expanded(
        child: _metricValue('年支出', _total(_entries, EntryType.expense), ''),
      ),
      Expanded(
        child: _metricValue(
          '月均支出',
          (_total(_entries, EntryType.expense) / 12).round(),
          '',
        ),
      ),
      Expanded(
        child: _metricValue('年收入', _total(_entries, EntryType.income), ''),
      ),
    ],
  );

  List<_CategoryChange> _categoryChanges() {
    final current = _categoryTotals(_entries);
    final previous = _categoryTotals(_previousEntries);
    final all = {...current.keys, ...previous.keys};
    final changes =
        all
            .map(
              (category) => _CategoryChange(
                category: category,
                amount: (current[category] ?? 0) - (previous[category] ?? 0),
              ),
            )
            .where((item) => item.amount != 0)
            .toList()
          ..sort((a, b) => b.amount.abs().compareTo(a.amount.abs()));
    return changes.take(3).toList(growable: false);
  }

  Widget _categoryChangeRow(_CategoryChange change) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      radius: 17,
      backgroundColor: LedgerCategories.color(change.category)
          .withValues(alpha: 0.14),
      child: Icon(
        LedgerCategories.icon(change.category),
        size: 18,
        color: LedgerCategories.color(change.category),
      ),
    ),
    title: Text(change.category),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          change.amount > 0 ? Icons.arrow_upward : Icons.arrow_downward,
          size: 18,
          color: change.amount > 0
              ? Colors.red.shade600
              : Colors.green.shade600,
        ),
        const SizedBox(width: 4),
        Text(
          '${change.amount > 0 ? '增加' : '减少'} ${_money(change.amount.abs())}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  Widget _categoryLegend(
    Iterable<MapEntry<String, int>> categories,
    int total,
  ) => Column(
    children: [
      for (final item in categories)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: LedgerCategories.color(item.key),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.key,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Text(
                '${(item.value * 100 / total).toStringAsFixed(1)}%',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _categoryAmountRow(String category, int amount, int total) => Row(
    children: [
      Expanded(child: Text(category)),
      Text(
        '${(amount * 100 / math.max(total, 1)).toStringAsFixed(1)}%',
        style: TextStyle(color: Colors.grey.shade600),
      ),
      const SizedBox(width: 12),
      Text(_money(amount), style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );

  Widget _kpi(String label, int amount, String footnote) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            _money(amount),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        if (footnote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              footnote,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
            ),
          ),
      ],
    ),
  );

  Widget _metricValue(String label, int cents, String footnote) =>
      _kpi(label, cents, footnote);

  Widget _bigMetric(String label, int amount, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      const SizedBox(height: 6),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          _money(amount),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    ],
  );

  Widget _amountBar(String label, int amount, int denominator, Color color) =>
      Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: LinearProgressIndicator(
                value: denominator == 0 ? 0 : amount / denominator,
                minHeight: 10,
                color: color,
                backgroundColor: color.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _money(amount),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      );

  Widget _expenseEntryRow(int rank, LedgerEntry entry) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          child: Text('$rank', style: TextStyle(color: Colors.grey.shade600)),
        ),
        CircleAvatar(
          radius: 18,
          backgroundColor: LedgerCategories.color(entry.category)
              .withValues(alpha: 0.14),
          child: Icon(
            LedgerCategories.icon(entry.category),
            size: 18,
            color: LedgerCategories.color(entry.category),
          ),
        ),
      ],
    ),
    title: Text(
      entry.note.isEmpty ? entry.category : entry.note,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      '${entry.category} · ${entry.date.month}月${entry.date.day}日',
    ),
    trailing: Text(
      '−${_money(entry.amountCents)}',
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
  );

  Widget _achievementCard() {
    final dates = widget.entries.map((entry) => entry.date);
    final currentStreak = LedgerActivityStats.currentStreak(dates);
    final recordedDays = LedgerActivityStats.uniqueRecordingDays(dates);
    return _card(
      title: '记账成就',
      child: Row(
        children: [
          Expanded(child: _achievement('$currentStreak天', '已连续记账')),
          Expanded(child: _achievement('$recordedDays天', '累计记账天数')),
          Expanded(child: _achievement('${widget.entries.length}笔', '累计账单笔数')),
        ],
      ),
    );
  }

  Widget _achievement(String value, String label) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
      ),
    ],
  );

  Widget _card({
    required String title,
    required Widget child,
    String? trailing,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _CategoryChange {
  const _CategoryChange({required this.category, required this.amount});

  final String category;
  final int amount;
}

String _dayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _dateLabel(DateTime date) => '${date.month}月${date.day}日';

String _money(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';

extension on LedgerPeriod {
  String get label => switch (this) {
    LedgerPeriod.week => '周',
    LedgerPeriod.month => '月',
    LedgerPeriod.year => '年',
  };
}
