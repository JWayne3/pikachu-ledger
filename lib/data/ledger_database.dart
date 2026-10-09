import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/ledger_categories.dart';
import '../models/ledger_entry.dart';

class LedgerDatabase {
  LedgerDatabase._();

  static final LedgerDatabase instance = LedgerDatabase._();
  static const _databaseName = 'ledger.db';
  static const _tableName = 'entries';

  Database? _database;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;

    final root = await getDatabasesPath();
    final db = await openDatabase(
      path.join(root, _databaseName),
      version: 3,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL CHECK (type IN ('expense', 'income')),
            amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
            category TEXT NOT NULL,
            date TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT ''
          )
        ''');
        await database.execute(
          'CREATE INDEX entries_date_index ON $_tableName(date DESC)',
        );
        await database.execute('''
          CREATE TABLE monthly_budgets (
            month TEXT PRIMARY KEY,
            amount_cents INTEGER NOT NULL CHECK (amount_cents > 0)
          )
        ''');
        await _createCustomCategoriesTable(database);
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute('''
            CREATE TABLE monthly_budgets (
              month TEXT PRIMARY KEY,
            amount_cents INTEGER NOT NULL CHECK (amount_cents > 0)
          )
          ''');
        }
        if (oldVersion < 3) {
          await _createCustomCategoriesTable(database);
        }
      },
    );
    _database = db;
    return db;
  }

  Future<List<LedgerEntry>> getEntries() async {
    final db = await database;
    final rows = await db.query(_tableName, orderBy: 'date DESC, id DESC');
    return rows.map(LedgerEntry.fromMap).toList(growable: false);
  }

  Future<int> insertEntry(LedgerEntry entry) async {
    final db = await database;
    return db.insert(_tableName, entry.toMap());
  }

  Future<int> updateEntry(LedgerEntry entry) async {
    final id = entry.id;
    if (id == null) {
      throw ArgumentError('Cannot update an entry without an id.');
    }
    final db = await database;
    return db.update(
      _tableName,
      entry.toMap(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteEntry(int id) async {
    final db = await database;
    await db.delete(_tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<int?> getMonthlyBudget(DateTime month) async {
    final db = await database;
    final rows = await db.query(
      'monthly_budgets',
      columns: ['amount_cents'],
      where: 'month = ?',
      whereArgs: [_monthKey(month)],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['amount_cents'] as int;
  }

  Future<void> setMonthlyBudget(DateTime month, int amountCents) async {
    if (amountCents <= 0) throw ArgumentError.value(amountCents, 'amountCents');
    final db = await database;
    await db.insert('monthly_budgets', {
      'month': _monthKey(month),
      'amount_cents': amountCents,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearMonthlyBudget(DateTime month) async {
    final db = await database;
    await db.delete(
      'monthly_budgets',
      where: 'month = ?',
      whereArgs: [_monthKey(month)],
    );
  }

  Future<List<String>> getCustomCategories(EntryType type) async {
    final db = await database;
    final rows = await db.query(
      'custom_categories',
      columns: ['name'],
      where: 'type = ?',
      whereArgs: [type.name],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map((row) => row['name']! as String).toList(growable: false);
  }

  Future<void> addCustomCategory(EntryType type, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.runes.length > 16) {
      throw ArgumentError.value(name, 'name', '分类名称需为 1 到 16 个字符。');
    }
    final db = await database;
    await db.insert('custom_categories', {
      'type': type.name,
      'name': normalized,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeCustomCategory(EntryType type, String name) async {
    final db = await database;
    await db.delete(
      'custom_categories',
      where: 'type = ? AND name = ?',
      whereArgs: [type.name, name],
    );
  }

  Future<Map<String, Object?>> createBackupSnapshot() async {
    final db = await database;
    return {
      'format': 'ledger_app_backup',
      'version': 2,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': await db.query(_tableName, orderBy: 'date ASC, id ASC'),
      'monthlyBudgets': await db.query('monthly_budgets', orderBy: 'month ASC'),
      'customCategories': await db.query(
        'custom_categories',
        orderBy: 'type ASC, name COLLATE NOCASE ASC',
      ),
    };
  }

  Future<void> restoreBackup(Map<String, Object?> snapshot) async {
    final backupVersion = snapshot['version'];
    if (snapshot['format'] != 'ledger_app_backup' ||
        backupVersion is! int ||
        (backupVersion != 1 && backupVersion != 2)) {
      throw const FormatException('备份文件格式或版本不受支持。');
    }

    final rawEntries = snapshot['entries'];
    final rawBudgets = snapshot['monthlyBudgets'];
    final rawCategories = snapshot['customCategories'] ?? const [];
    if (rawEntries is! List || rawBudgets is! List || rawCategories is! List) {
      throw const FormatException('备份文件缺少账单或预算数据。');
    }

    final entries = rawEntries.map(_decodeBackupEntry).toList(growable: false);
    final budgets = rawBudgets.map(_decodeBackupBudget).toList(growable: false);
    final categories = rawCategories
        .map(_decodeBackupCustomCategory)
        .toList(growable: false);
    final budgetMonths = budgets.map((budget) => budget['month']).toSet();
    if (budgetMonths.length != budgets.length) {
      throw const FormatException('备份中存在重复月份的预算。');
    }

    final db = await database;
    await db.transaction((transaction) async {
      await transaction.delete(_tableName);
      await transaction.delete('monthly_budgets');
      await transaction.delete('custom_categories');
      final batch = transaction.batch();
      for (final entry in entries) {
        batch.insert(_tableName, entry.toMap());
      }
      for (final budget in budgets) {
        batch.insert('monthly_budgets', budget);
      }
      for (final category in categories) {
        batch.insert('custom_categories', category);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> importSpreadsheetData({
    required List<LedgerEntry> entries,
    required Map<String, int> monthlyBudgets,
    required Map<EntryType, Set<String>> customCategories,
  }) async {
    for (final entry in entries) {
      if (entry.amountCents <= 0 ||
          entry.category.trim().isEmpty ||
          entry.category.runes.length > 16 ||
          entry.note.runes.length > 60) {
        throw const FormatException('导入账单包含无效数据，未写入任何内容。');
      }
    }
    for (final budget in monthlyBudgets.entries) {
      if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(budget.key) ||
          budget.value <= 0) {
        throw const FormatException('导入预算包含无效数据，未写入任何内容。');
      }
    }
    final categoriesToAdd = <EntryType, Set<String>>{
      for (final type in EntryType.values)
        type: {
          ...?customCategories[type],
          for (final entry in entries)
            if (entry.type == type &&
                !LedgerCategories.builtIns(type).contains(entry.category))
              entry.category,
        },
    };
    for (final type in EntryType.values) {
      for (final category in categoriesToAdd[type]!) {
        if (category.trim().isEmpty ||
            category.runes.length > 16 ||
            LedgerCategories.builtIns(type).contains(category)) {
          throw const FormatException('导入自定义分类包含无效数据，未写入任何内容。');
        }
      }
    }

    final db = await database;
    await db.transaction((transaction) async {
      final batch = transaction.batch();
      for (final entry in entries) {
        batch.insert(_tableName, entry.toMap());
      }
      for (final budget in monthlyBudgets.entries) {
        batch.insert('monthly_budgets', {
          'month': budget.key,
          'amount_cents': budget.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final type in EntryType.values) {
        for (final category in categoriesToAdd[type]!) {
          batch.insert('custom_categories', {
            'type': type.name,
            'name': category.trim(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      await batch.commit(noResult: true);
    });
  }

  LedgerEntry _decodeBackupEntry(Object? value) {
    if (value is! Map) throw const FormatException('账单数据格式无效。');
    final typeName = value['type'];
    final amount = value['amount_cents'];
    final category = value['category'];
    final date = value['date'];
    final note = value['note'];
    if (typeName is! String ||
        !EntryType.values.any((type) => type.name == typeName) ||
        amount is! int ||
        amount <= 0 ||
        category is! String ||
        category.trim().isEmpty ||
        date is! String ||
        (note != null && note is! String)) {
      throw const FormatException('备份中包含无效的账单数据。');
    }

    DateTime parsedDate;
    try {
      parsedDate = DateTime.parse(date);
    } on FormatException {
      throw const FormatException('备份中包含无效的账单日期。');
    }

    return LedgerEntry(
      type: EntryType.values.byName(typeName),
      amountCents: amount,
      category: category,
      date: parsedDate,
      note: note as String? ?? '',
    );
  }

  Map<String, Object?> _decodeBackupBudget(Object? value) {
    if (value is! Map) throw const FormatException('预算数据格式无效。');
    final month = value['month'];
    final amount = value['amount_cents'];
    if (month is! String ||
        !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month) ||
        amount is! int ||
        amount <= 0) {
      throw const FormatException('备份中包含无效的预算数据。');
    }
    return {'month': month, 'amount_cents': amount};
  }

  Map<String, Object?> _decodeBackupCustomCategory(Object? value) {
    if (value is! Map) throw const FormatException('自定义分类数据格式无效。');
    final type = value['type'];
    final name = value['name'];
    if (type is! String ||
        !EntryType.values.any((entryType) => entryType.name == type) ||
        name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 16) {
      throw const FormatException('备份中包含无效的自定义分类。');
    }
    return {'type': type, 'name': name.trim()};
  }

  Future<void> _createCustomCategoriesTable(Database database) =>
      database.execute('''
        CREATE TABLE custom_categories (
          type TEXT NOT NULL CHECK (type IN ('expense', 'income')),
          name TEXT NOT NULL,
          PRIMARY KEY(type, name)
        )
      ''');

  static String _monthKey(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';
}
