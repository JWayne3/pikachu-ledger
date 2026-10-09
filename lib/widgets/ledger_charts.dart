import 'dart:math' as math;

import 'package:flutter/material.dart';

class LedgerChartPoint {
  const LedgerChartPoint({required this.label, required this.value});

  final String label;
  final int value;
}

class LedgerTrendChart extends StatelessWidget {
  const LedgerTrendChart({
    required this.points,
    required this.color,
    this.height = 190,
    super.key,
  });

  final List<LedgerChartPoint> points;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _LedgerTrendPainter(points: points, color: color),
    ),
  );
}

class LedgerBarChart extends StatelessWidget {
  const LedgerBarChart({
    required this.points,
    required this.color,
    this.height = 210,
    super.key,
  });

  final List<LedgerChartPoint> points;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _LedgerBarPainter(points: points, color: color),
    ),
  );
}

class LedgerDonutChart extends StatelessWidget {
  const LedgerDonutChart({
    required this.values,
    required this.colorFor,
    this.centerLabel = '',
    this.centerValue = '',
    this.size = 164,
    super.key,
  });

  final Map<String, int> values;
  final Color Function(String category) colorFor;
  final String centerLabel;
  final String centerValue;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _LedgerDonutPainter(values: values, colorFor: colorFor),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (centerLabel.isNotEmpty)
              Text(
                centerLabel,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            if (centerValue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    centerValue,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _LedgerTrendPainter extends CustomPainter {
  _LedgerTrendPainter({required this.points, required this.color});

  final List<LedgerChartPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 8.0;
    const right = 8.0;
    const top = 10.0;
    const bottom = 30.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left + 1, size.width - right),
      math.max(top + 1, size.height - bottom),
    );
    final gridPaint = Paint()
      ..color = const Color(0xFFE7E7E7)
      ..strokeWidth = 1;
    for (var line = 0; line <= 3; line++) {
      final y = plot.top + plot.height * line / 3;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    if (points.isEmpty) {
      _drawText(canvas, '还没有可展示的数据', Offset(plot.left, plot.center.dy - 8));
      return;
    }

    final maxValue = math.max(
      1,
      points.map((point) => point.value).reduce(math.max),
    );
    final xStep = points.length <= 1 ? 0.0 : plot.width / (points.length - 1);
    final locations = <Offset>[
      for (var index = 0; index < points.length; index++)
        Offset(
          points.length == 1 ? plot.center.dx : plot.left + xStep * index,
          plot.bottom - (points[index].value / maxValue) * plot.height * 0.88,
        ),
    ];
    final linePath = Path()..moveTo(locations.first.dx, locations.first.dy);
    for (final point in locations.skip(1)) {
      linePath.lineTo(point.dx, point.dy);
    }
    final fillPath = Path.from(linePath)
      ..lineTo(locations.last.dx, plot.bottom)
      ..lineTo(locations.first.dx, plot.bottom)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.32),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(plot),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (final point in locations) {
      canvas.drawCircle(point, 4, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
        3,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }

    final labelStep = points.length <= 7 ? 1 : (points.length / 6).ceil();
    for (var index = 0; index < points.length; index++) {
      if (index % labelStep != 0 && index != points.length - 1) continue;
      final painter = _textPainter(points[index].label);
      final x = (locations[index].dx - painter.width / 2).clamp(
        0.0,
        size.width - painter.width,
      );
      painter.paint(canvas, Offset(x, plot.bottom + 8));
    }
  }

  @override
  bool shouldRepaint(covariant _LedgerTrendPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _LedgerBarPainter extends CustomPainter {
  _LedgerBarPainter({required this.points, required this.color});

  final List<LedgerChartPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 8.0;
    const right = 8.0;
    const top = 24.0;
    const bottom = 30.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left + 1, size.width - right),
      math.max(top + 1, size.height - bottom),
    );
    final gridPaint = Paint()
      ..color = const Color(0xFFE7E7E7)
      ..strokeWidth = 1;
    for (var line = 0; line <= 3; line++) {
      final y = plot.top + plot.height * line / 3;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    if (points.isEmpty) return;
    final maxValue = math.max(
      1,
      points.map((point) => point.value).reduce(math.max),
    );
    final slot = plot.width / points.length;
    final barWidth = math.min(34.0, slot * 0.56);
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final barHeight = (point.value / maxValue) * plot.height * 0.84;
      final centerX = plot.left + slot * (index + 0.5);
      final barRect = Rect.fromLTWH(
        centerX - barWidth / 2,
        plot.bottom - barHeight,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(barRect, const Radius.circular(6)),
        Paint()..color = color.withValues(alpha: 0.85),
      );
      final valueLabel = _textPainter(_compactMoney(point.value));
      valueLabel.paint(
        canvas,
        Offset(
          centerX - valueLabel.width / 2,
          barRect.top - valueLabel.height - 4,
        ),
      );
      final label = _textPainter(point.label);
      label.paint(canvas, Offset(centerX - label.width / 2, plot.bottom + 8));
    }
  }

  @override
  bool shouldRepaint(covariant _LedgerBarPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

class _LedgerDonutPainter extends CustomPainter {
  _LedgerDonutPainter({required this.values, required this.colorFor});

  final Map<String, int> values;
  final Color Function(String category) colorFor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final total = values.values.fold<int>(0, (sum, value) => sum + value);
    if (total <= 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2,
        false,
        Paint()
          ..color = const Color(0xFFE7E7E7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 21,
      );
      return;
    }
    var start = -math.pi / 2;
    for (final entry in values.entries.where((entry) => entry.value > 0)) {
      final sweep = math.pi * 2 * entry.value / total;
      canvas.drawArc(
        rect,
        start,
        math.max(0, sweep - 0.018),
        false,
        Paint()
          ..color = colorFor(entry.key)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 21
          ..strokeCap = StrokeCap.butt,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _LedgerDonutPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.colorFor != colorFor;
}

void _drawText(Canvas canvas, String text, Offset offset) {
  _textPainter(text).paint(canvas, offset);
}

TextPainter _textPainter(String text) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(fontSize: 10, color: Color(0xFF7C817D)),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter;
}

String _compactMoney(int cents) {
  final amount = cents / 100;
  if (amount >= 10000) return '${(amount / 10000).toStringAsFixed(1)}万';
  if (amount >= 1000) return '${(amount / 1000).toStringAsFixed(1)}千';
  return amount.toStringAsFixed(0);
}
