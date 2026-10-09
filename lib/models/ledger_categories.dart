import 'package:flutter/material.dart';

import 'ledger_entry.dart';

class LedgerCategories {
  const LedgerCategories._();

  static const other = '其他';

  static const expense = [
    '餐饮',
    '购物',
    '日用',
    '交通',
    '蔬菜',
    '水果',
    '零食',
    '运动',
    '娱乐',
    '通讯',
    '服饰',
    '美容',
    '住房',
    '居家',
    '孩子',
    '长辈',
    '社交',
    '旅行',
    '烟酒',
    '数码',
    '汽车',
    '医疗',
    '书籍',
    '学习',
    '宠物',
    '礼金',
    '礼物',
    '办公',
    '维修',
    '捐赠',
    '彩票',
    '亲友',
    '快递',
    other,
  ];

  static const income = ['工资', '兼职', '理财', '礼金', '奖金', '报销', '经营', '退款', other];

  static List<String> builtIns(EntryType type) =>
      type == EntryType.expense ? expense : income;

  static IconData icon(String category) => switch (category) {
    '餐饮' => Icons.restaurant_outlined,
    '购物' => Icons.shopping_bag_outlined,
    '日用' => Icons.cleaning_services_outlined,
    '交通' => Icons.directions_bus_outlined,
    '蔬菜' => Icons.eco_outlined,
    '水果' => Icons.local_grocery_store_outlined,
    '零食' => Icons.cookie_outlined,
    '运动' => Icons.sports_basketball_outlined,
    '娱乐' => Icons.movie_outlined,
    '通讯' => Icons.phone_iphone_outlined,
    '服饰' => Icons.checkroom_outlined,
    '美容' => Icons.face_retouching_natural_outlined,
    '住房' || '居住' => Icons.home_outlined,
    '居家' => Icons.chair_outlined,
    '孩子' => Icons.child_care_outlined,
    '长辈' => Icons.elderly_outlined,
    '社交' => Icons.forum_outlined,
    '旅行' => Icons.flight_outlined,
    '烟酒' => Icons.wine_bar_outlined,
    '数码' => Icons.devices_other_outlined,
    '汽车' => Icons.directions_car_outlined,
    '医疗' => Icons.medical_services_outlined,
    '书籍' => Icons.menu_book_outlined,
    '学习' => Icons.school_outlined,
    '宠物' => Icons.pets_outlined,
    '礼金' => Icons.redeem_outlined,
    '礼物' => Icons.card_giftcard_outlined,
    '办公' => Icons.work_outline,
    '维修' => Icons.build_outlined,
    '捐赠' => Icons.favorite_border,
    '彩票' => Icons.confirmation_number_outlined,
    '亲友' => Icons.people_outline,
    '快递' => Icons.inventory_2_outlined,
    '工资' => Icons.account_balance_wallet_outlined,
    '兼职' => Icons.schedule_outlined,
    '理财' => Icons.trending_up_outlined,
    '奖金' => Icons.paid_outlined,
    '报销' => Icons.receipt_long_outlined,
    '经营' => Icons.storefront_outlined,
    '退款' => Icons.currency_exchange_outlined,
    other => Icons.more_horiz,
    _ => Icons.category_outlined,
  };

  static Color color(String category) {
    const palette = [
      Color(0xFFE59B30),
      Color(0xFF4C83C3),
      Color(0xFF57A989),
      Color(0xFF9A6CC1),
      Color(0xFFCB6A77),
      Color(0xFF4E9CA0),
      Color(0xFFD27440),
      Color(0xFF6789C6),
      Color(0xFF9A8A44),
      Color(0xFF6B9B69),
      Color(0xFFAA6C95),
      Color(0xFF747A8C),
    ];
    final index = category.runes.fold<int>(0, (sum, rune) => sum + rune);
    return palette[index % palette.length];
  }
}
