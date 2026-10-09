import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_app/models/ledger_entry.dart';
import 'package:ledger_app/services/ledger_excel_service.dart';

void main() {
  group('LedgerExcelService', () {
    test('exports and imports bills, budgets, and custom categories', () {
      final bytes = LedgerExcelService.encodeSnapshot({
        'entries': [
          {
            'type': 'expense',
            'amount_cents': 1234,
            'category': '餐饮',
            'date': '2026-10-09T00:00:00.000',
            'note': '午餐',
          },
          {
            'type': 'income',
            'amount_cents': 8900,
            'category': '工资',
            'date': '2026-10-10T00:00:00.000',
            'note': '',
          },
        ],
        'monthlyBudgets': [
          {'month': '2026-10', 'amount_cents': 100000},
        ],
        'customCategories': [
          {'type': 'expense', 'name': '宠物医疗'},
        ],
      });

      final imported = LedgerExcelService.decode(bytes);

      expect(imported.entries, hasLength(2));
      expect(imported.entries[0].type, EntryType.expense);
      expect(imported.entries[0].amountCents, 1234);
      expect(imported.entries[0].category, '餐饮');
      expect(imported.entries[0].date, DateTime(2026, 10, 9));
      expect(imported.entries[0].note, '午餐');
      expect(imported.entries[1].type, EntryType.income);
      expect(imported.entries[1].amountCents, 8900);
      expect(imported.monthlyBudgets, {'2026-10': 100000});
      expect(imported.customCategories[EntryType.expense], contains('宠物医疗'));
      expect(imported.issues, isEmpty);
    });

    test('finds aliased headers and reports invalid rows for preview', () {
      final workbook = Excel.createExcel();
      workbook['账单']
        ..appendRow([TextCellValue('其他账单导出')])
        ..appendRow([
          TextCellValue('记账日期'),
          TextCellValue('收支类型'),
          TextCellValue('金额（元）'),
          TextCellValue('类别'),
          TextCellValue('说明'),
        ])
        ..appendRow([
          DateCellValue.fromDateTime(DateTime(2025, 5, 12)),
          TextCellValue('支出'),
          DoubleCellValue(18.5),
          TextCellValue('购物'),
          TextCellValue('水杯'),
        ])
        ..appendRow([
          DateCellValue.fromDateTime(DateTime(2025, 5, 13)),
          TextCellValue('收入'),
          TextCellValue('金额无效'),
          TextCellValue('工资'),
          TextCellValue(''),
        ]);
      final bytes = workbook.encode()!;

      final imported = LedgerExcelService.decode(bytes);

      expect(imported.entries, hasLength(1));
      expect(imported.entries.single.amountCents, 1850);
      expect(imported.entries.single.note, '水杯');
      expect(imported.issues, hasLength(1));
      expect(imported.issues.single.row, 4);
    });
  });
}
