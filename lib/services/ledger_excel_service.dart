import 'package:excel/excel.dart';

import '../models/ledger_categories.dart';
import '../models/ledger_entry.dart';

class LedgerExcelImportIssue {
  const LedgerExcelImportIssue({
    required this.sheet,
    required this.row,
    required this.message,
  });

  final String sheet;
  final int row;
  final String message;

  @override
  String toString() => '$sheet 第 $row 行：$message';
}

class LedgerExcelImportData {
  const LedgerExcelImportData({
    required this.entries,
    required this.monthlyBudgets,
    required this.customCategories,
    required this.issues,
  });

  final List<LedgerEntry> entries;
  final Map<String, int> monthlyBudgets;
  final Map<EntryType, Set<String>> customCategories;
  final List<LedgerExcelImportIssue> issues;
}

class LedgerExcelService {
  const LedgerExcelService._();

  static const _ledgerSheet = '账单';
  static const _budgetSheet = '月预算';
  static const _categorySheet = '自定义分类';

  static List<int> encodeSnapshot(Map<String, Object?> snapshot) {
    final rawEntries = snapshot['entries'];
    final rawBudgets = snapshot['monthlyBudgets'];
    final rawCategories = snapshot['customCategories'];
    if (rawEntries is! List || rawBudgets is! List || rawCategories is! List) {
      throw const FormatException('本机账本数据格式无效，无法生成 Excel 文件。');
    }

    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != _ledgerSheet) {
      workbook.rename(defaultSheet, _ledgerSheet);
    }

    final ledger = workbook[_ledgerSheet]
      ..appendRow([
        TextCellValue('日期'),
        TextCellValue('类型'),
        TextCellValue('金额（元）'),
        TextCellValue('分类'),
        TextCellValue('备注'),
      ]);
    final entries =
        rawEntries.map((value) {
          if (value is! Map) throw const FormatException('账单数据格式无效。');
          return Map<String, Object?>.from(value);
        }).toList()..sort(
          (a, b) => (a['date'] as String).compareTo(b['date'] as String),
        );
    for (final entry in entries) {
      final type = EntryType.values.byName(entry['type']! as String);
      final date = DateTime.parse(entry['date']! as String);
      final cents = entry['amount_cents']! as int;
      ledger.appendRow([
        DateCellValue.fromDateTime(date),
        TextCellValue(type.label),
        DoubleCellValue(cents / 100),
        TextCellValue(entry['category']! as String),
        TextCellValue(entry['note'] as String? ?? ''),
      ]);
    }
    for (final entry in [
      (0, 14.0),
      (1, 12.0),
      (2, 14.0),
      (3, 18.0),
      (4, 30.0),
    ]) {
      ledger.setColumnWidth(entry.$1, entry.$2);
    }

    final budgets = workbook[_budgetSheet]
      ..appendRow([TextCellValue('月份'), TextCellValue('月预算（元）')]);
    for (final value in rawBudgets) {
      if (value is! Map) throw const FormatException('月预算数据格式无效。');
      final row = Map<String, Object?>.from(value);
      final month = (row['month']! as String).split('-');
      budgets.appendRow([
        DateCellValue(
          year: int.parse(month[0]),
          month: int.parse(month[1]),
          day: 1,
        ),
        DoubleCellValue((row['amount_cents']! as int) / 100),
      ]);
    }
    budgets.setColumnWidth(0, 16);
    budgets.setColumnWidth(1, 20);

    final categories = workbook[_categorySheet]
      ..appendRow([TextCellValue('收支类型'), TextCellValue('分类')]);
    for (final value in rawCategories) {
      if (value is! Map) throw const FormatException('自定义分类数据格式无效。');
      final row = Map<String, Object?>.from(value);
      categories.appendRow([
        TextCellValue(EntryType.values.byName(row['type']! as String).label),
        TextCellValue(row['name']! as String),
      ]);
    }
    categories.setColumnWidth(0, 16);
    categories.setColumnWidth(1, 22);

    final bytes = workbook.encode();
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('Excel 文件生成失败。');
    }
    return bytes;
  }

  static LedgerExcelImportData decode(List<int> bytes) {
    final Excel workbook;
    try {
      workbook = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('无法读取该文件。请选择有效的 .xlsx 工作簿。');
    }
    final sheets = workbook.tables;
    if (sheets.isEmpty) throw const FormatException('Excel 文件中没有工作表。');
    final ledgerSheet = sheets[_ledgerSheet] ?? sheets.values.first;
    final issues = <LedgerExcelImportIssue>[];
    final entries = _readEntries(ledgerSheet, issues);
    final budgets = <String, int>{};
    final categories = <EntryType, Set<String>>{
      EntryType.expense: <String>{},
      EntryType.income: <String>{},
    };

    final budgetSheet = sheets[_budgetSheet];
    if (budgetSheet != null) _readBudgets(budgetSheet, budgets, issues);
    final categorySheet = sheets[_categorySheet];
    if (categorySheet != null) {
      _readCategories(categorySheet, categories, issues);
    }
    for (final entry in entries) {
      if (!LedgerCategories.builtIns(entry.type).contains(entry.category)) {
        categories[entry.type]!.add(entry.category);
      }
    }
    for (final type in EntryType.values) {
      categories[type]!.removeWhere(
        (name) => LedgerCategories.builtIns(type).contains(name),
      );
    }

    if (entries.isEmpty &&
        budgets.isEmpty &&
        categories.values.every((set) => set.isEmpty)) {
      final details = issues.isEmpty ? '' : ' ${issues.first}';
      throw FormatException('没有找到可导入的数据。请检查表头和内容。$details');
    }
    return LedgerExcelImportData(
      entries: entries,
      monthlyBudgets: budgets,
      customCategories: categories,
      issues: issues,
    );
  }

  static List<LedgerEntry> _readEntries(
    Sheet sheet,
    List<LedgerExcelImportIssue> issues,
  ) {
    final rows = sheet.rows;
    final headerIndex = _findHeader(
      rows,
      required: const ['date', 'type', 'amount', 'category'],
    );
    if (headerIndex == null) {
      throw const FormatException('账单工作表需要包含“日期、类型、金额、分类”表头。');
    }
    final columns = _columns(rows[headerIndex]);
    final entries = <LedgerEntry>[];
    for (var index = headerIndex + 1; index < rows.length; index++) {
      final row = rows[index];
      if (row.every((cell) => _cellText(cell?.value).trim().isEmpty)) continue;
      try {
        final date = _parseDate(_valueAt(row, columns['date']!));
        final type = _parseType(_valueAt(row, columns['type']!));
        final cents = _parseAmount(_valueAt(row, columns['amount']!));
        final category = _cellText(_valueAt(row, columns['category']!)).trim();
        final noteIndex = columns['note'];
        final note = noteIndex == null
            ? ''
            : _cellText(_valueAt(row, noteIndex)).trim();
        if (category.isEmpty || category.runes.length > 16) {
          throw const FormatException('分类不能为空且最多 16 个字符。');
        }
        if (note.runes.length > 60) {
          throw const FormatException('备注最多 60 个字符。');
        }
        entries.add(
          LedgerEntry(
            type: type,
            amountCents: cents,
            category: category,
            date: date,
            note: note,
          ),
        );
      } on FormatException catch (error) {
        issues.add(
          LedgerExcelImportIssue(
            sheet: sheet.sheetName,
            row: index + 1,
            message: error.message,
          ),
        );
      }
    }
    return entries;
  }

  static void _readBudgets(
    Sheet sheet,
    Map<String, int> budgets,
    List<LedgerExcelImportIssue> issues,
  ) {
    final rows = sheet.rows;
    final headerIndex = _findHeader(rows, required: const ['month', 'amount']);
    if (headerIndex == null) {
      issues.add(
        LedgerExcelImportIssue(
          sheet: sheet.sheetName,
          row: 1,
          message: '未找到“月份、月预算”表头，已跳过此工作表。',
        ),
      );
      return;
    }
    final columns = _columns(rows[headerIndex]);
    for (var index = headerIndex + 1; index < rows.length; index++) {
      final row = rows[index];
      if (row.every((cell) => _cellText(cell?.value).trim().isEmpty)) continue;
      try {
        final month = _parseMonth(_valueAt(row, columns['month']!));
        final amount = _parseAmount(_valueAt(row, columns['amount']!));
        if (amount <= 0) throw const FormatException('月预算必须大于 0。');
        budgets[month] = amount;
      } on FormatException catch (error) {
        issues.add(
          LedgerExcelImportIssue(
            sheet: sheet.sheetName,
            row: index + 1,
            message: error.message,
          ),
        );
      }
    }
  }

  static void _readCategories(
    Sheet sheet,
    Map<EntryType, Set<String>> categories,
    List<LedgerExcelImportIssue> issues,
  ) {
    final rows = sheet.rows;
    final headerIndex = _findHeader(rows, required: const ['type', 'category']);
    if (headerIndex == null) {
      issues.add(
        LedgerExcelImportIssue(
          sheet: sheet.sheetName,
          row: 1,
          message: '未找到“收支类型、分类”表头，已跳过此工作表。',
        ),
      );
      return;
    }
    final columns = _columns(rows[headerIndex]);
    for (var index = headerIndex + 1; index < rows.length; index++) {
      final row = rows[index];
      if (row.every((cell) => _cellText(cell?.value).trim().isEmpty)) continue;
      try {
        final type = _parseType(_valueAt(row, columns['type']!));
        final name = _cellText(_valueAt(row, columns['category']!)).trim();
        if (name.isEmpty || name.runes.length > 16) {
          throw const FormatException('分类不能为空且最多 16 个字符。');
        }
        categories[type]!.add(name);
      } on FormatException catch (error) {
        issues.add(
          LedgerExcelImportIssue(
            sheet: sheet.sheetName,
            row: index + 1,
            message: error.message,
          ),
        );
      }
    }
  }

  static int? _findHeader(
    List<List<Data?>> rows, {
    required List<String> required,
  }) {
    final limit = rows.length < 20 ? rows.length : 20;
    for (var index = 0; index < limit; index++) {
      final columns = _columns(rows[index]);
      if (required.every(columns.containsKey)) return index;
    }
    return null;
  }

  static Map<String, int> _columns(List<Data?> row) {
    const aliases = <String, List<String>>{
      'date': ['日期', '记账日期', '时间', 'date', 'recorddate'],
      'type': ['类型', '收支类型', '收支', 'type', 'transactiontype'],
      'amount': ['金额', '金额元', '金额人民币', '月预算', '月预算元', 'amount', 'value'],
      'category': ['分类', '类别', 'category'],
      'note': ['备注', '说明', 'note', 'description'],
      'month': ['月份', '月', 'month', 'budgetmonth'],
    };
    final columns = <String, int>{};
    for (var index = 0; index < row.length; index++) {
      final header = _normalizeHeader(_cellText(row[index]?.value));
      if (header.isEmpty) continue;
      for (final entry in aliases.entries) {
        if (entry.value.any((alias) => _normalizeHeader(alias) == header)) {
          columns.putIfAbsent(entry.key, () => index);
        }
      }
    }
    return columns;
  }

  static String _normalizeHeader(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s()（）【】\[\]：:]'), '');

  static CellValue? _valueAt(List<Data?> row, int index) =>
      index < row.length ? row[index]?.value : null;

  static String _cellText(CellValue? value) {
    if (value == null || value is FormulaCellValue) return '';
    if (value is TextCellValue) return value.value.toString().trim();
    if (value is IntCellValue) return value.value.toString();
    if (value is DoubleCellValue) return value.value.toString();
    if (value is DateCellValue) {
      return _formatDate(value.asDateTimeLocal());
    }
    if (value is DateTimeCellValue) {
      return _formatDate(value.asDateTimeLocal());
    }
    return value.toString().trim();
  }

  static DateTime _parseDate(CellValue? value) {
    if (value is DateCellValue) return _validateDate(value.asDateTimeLocal());
    if (value is DateTimeCellValue) {
      return _validateDate(value.asDateTimeLocal());
    }
    if (value is IntCellValue || value is DoubleCellValue) {
      final serial = value is IntCellValue
          ? value.value.toDouble()
          : (value as DoubleCellValue).value;
      if (serial < 36526 || serial > 73415) {
        throw const FormatException('日期数字应为 Excel 日期格式。');
      }
      return _validateDate(
        DateTime(1899, 12, 30).add(Duration(days: serial.floor())),
      );
    }
    var text = _cellText(value).trim();
    if (text.isEmpty) throw const FormatException('日期不能为空。');
    text = text
        .replaceAll('年', '-')
        .replaceAll('月', '-')
        .replaceAll('日', '')
        .replaceAll('/', '-')
        .replaceAll('.', '-');
    final datePart = text.split(RegExp(r'[T ]')).first;
    final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(datePart);
    final parsed = match == null
        ? DateTime.tryParse(text)
        : DateTime.tryParse(
            '${match.group(1)}-${match.group(2)!.padLeft(2, '0')}-${match.group(3)!.padLeft(2, '0')}',
          );
    if (parsed == null) throw const FormatException('日期格式无效。');
    return _validateDate(parsed);
  }

  static DateTime _validateDate(DateTime date) {
    if (date.year < 2000 || date.year > 2100) {
      throw const FormatException('日期范围需在 2000 年至 2100 年之间。');
    }
    return DateTime(date.year, date.month, date.day);
  }

  static EntryType _parseType(CellValue? value) {
    final type = _cellText(value).toLowerCase().trim();
    if (type == '收入' || type == 'income') return EntryType.income;
    if (type == '支出' || type == 'expense') return EntryType.expense;
    throw const FormatException('类型只能填写“收入”或“支出”。');
  }

  static int _parseAmount(CellValue? value) {
    var text = _cellText(value)
        .replaceAll(RegExp(r'[\s,，¥￥元]'), '')
        .replaceAll(RegExp(r'(人民币|CNY|RMB)', caseSensitive: false), '');
    if (text.startsWith('.')) text = '0$text';
    final match = RegExp(r'^\+?(\d{1,9})(?:\.(\d+))?$').firstMatch(text);
    if (match == null) {
      throw const FormatException('金额须为大于 0 的数字，最多保留两位小数。');
    }
    var fraction = match.group(2) ?? '';
    if (fraction.length > 2 &&
        fraction.substring(2).contains(RegExp('[1-9]'))) {
      throw const FormatException('金额最多保留两位小数。');
    }
    fraction = fraction.padRight(2, '0').substring(0, 2);
    final units = int.parse(match.group(1)!);
    final cents = units * 100 + int.parse(fraction);
    if (cents <= 0 || units > 999999999) {
      throw const FormatException('金额超出可导入范围。');
    }
    return cents;
  }

  static String _parseMonth(CellValue? value) {
    if (value is DateCellValue) return _formatMonth(value.year, value.month);
    if (value is DateTimeCellValue) {
      return _formatMonth(value.year, value.month);
    }
    var text = _cellText(value)
        .trim()
        .replaceAll('/', '-')
        .replaceAll('年', '-');
    text = text.replaceAll('月', '').replaceAll(RegExp(r'-+$'), '');
    final match = RegExp(r'^(\d{4})-(\d{1,2})(?:-\d{1,2})?$').firstMatch(text);
    if (match == null) throw const FormatException('月份格式应为 YYYY-MM。');
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (year < 2000 || year > 2100 || month < 1 || month > 12) {
      throw const FormatException('月份无效。');
    }
    return _formatMonth(year, month);
  }

  static String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static String _formatMonth(int year, int month) =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
}
