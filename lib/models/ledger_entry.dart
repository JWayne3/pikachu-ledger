enum EntryType {
  expense('支出'),
  income('收入');

  const EntryType(this.label);

  final String label;
}

class LedgerEntry {
  const LedgerEntry({
    this.id,
    required this.type,
    required this.amountCents,
    required this.category,
    required this.date,
    this.note = '',
  });

  final int? id;
  final EntryType type;
  final int amountCents;
  final String category;
  final DateTime date;
  final String note;

  Map<String, Object?> toMap() => {
    'type': type.name,
    'amount_cents': amountCents,
    'category': category,
    'date': date.toIso8601String(),
    'note': note,
  };

  factory LedgerEntry.fromMap(Map<String, Object?> map) => LedgerEntry(
    id: map['id'] as int,
    type: EntryType.values.byName(map['type'] as String),
    amountCents: map['amount_cents'] as int,
    category: map['category'] as String,
    date: DateTime.parse(map['date'] as String),
    note: map['note'] as String? ?? '',
  );
}
