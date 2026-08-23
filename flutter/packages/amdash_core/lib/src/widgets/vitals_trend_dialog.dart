import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/patient.dart';
import '../models/vitals_history_entry.dart';
import '../theme/app_theme.dart';

/// One line on a [showVitalsTrendDialog] chart — most vitals need only one
/// (e.g. Heart Rate), but Blood Pressure is a compound "120/80" string, so
/// it's charted as two series (Systolic/Diastolic) through the same dialog.
class VitalSeries {
  const VitalSeries({required this.label, required this.selector, this.color});

  final String label;

  /// Returns `null` for an entry that didn't record this value (e.g. GCS
  /// wasn't taken, or the raw field is the 'Unknown' string sentinel) —
  /// filtered out before charting rather than plotted as zero.
  final num? Function(PatientVitals vitals) selector;

  /// Defaults to [AppColors.trackingAccent] (single-series case); a second
  /// color should be supplied explicitly for a multi-series chart like
  /// blood pressure so the two lines are visually distinct.
  final Color? color;
}

/// Charts one or more vitals series over time, from already-fetched
/// [VitalsHistoryEntry]s (newest-first, per [vitalsHistoryProvider]) — the
/// caller decides when there's enough data to be worth showing (see
/// `_infoRow`'s own `history.length > 1` check before offering the trend
/// icon at all). Shared by physician (read-only display) and EMS (edit
/// form) rather than duplicated, matching `dialogs.dart`'s plain
/// function-wrapping-`showDialog` pattern — no Riverpod needed here, it
/// only ever renders data the caller already has in hand.
Future<void> showVitalsTrendDialog(
  BuildContext context, {
  required String title,
  required List<VitalsHistoryEntry> history,
  required List<VitalSeries> series,
  String? unit,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _VitalsTrendDialog(
      title: title,
      history: history,
      series: series,
      unit: unit,
    ),
  );
}

class _VitalsTrendDialog extends StatelessWidget {
  const _VitalsTrendDialog({
    required this.title,
    required this.history,
    required this.series,
    this.unit,
  });

  final String title;
  final List<VitalsHistoryEntry> history;
  final List<VitalSeries> series;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;

    // Oldest-first for the chart (history itself is newest-first, matching
    // the rest of the app's convention for browsing it), one color per
    // series so multi-line charts (blood pressure) stay readable.
    final chronological = history.reversed
        .where((entry) => entry.recordedAt != null)
        .toList();
    final defaultColors = [
      AppColors.trackingAccent,
      AppColors.brand,
      AppColors.warning,
    ];
    final plotted = <_PlottedSeries>[];
    for (var i = 0; i < series.length; i++) {
      final s = series[i];
      final points = [
        for (final entry in chronological)
          if (s.selector(entry.vitals) != null)
            MapEntry(entry.recordedAt!, s.selector(entry.vitals)!),
      ];
      // A single point can't show a trend line — skip it rather than draw
      // a lone dot that implies more than the data supports.
      if (points.length < 2) continue;
      plotted.add(
        _PlottedSeries(
          label: s.label,
          color: s.color ?? defaultColors[i % defaultColors.length],
          points: points,
        ),
      );
    }

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        height: 280,
        child: plotted.isEmpty
            ? Center(
                child: Text(
                  'Not enough recorded data yet to show a trend.',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: _Chart(
                      series: plotted,
                      unit: unit,
                      palette: palette,
                    ),
                  ),
                  if (plotted.length > 1) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      children: [
                        for (final s in plotted)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                s.label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _PlottedSeries {
  const _PlottedSeries({
    required this.label,
    required this.color,
    required this.points,
  });

  final String label;
  final Color color;
  final List<MapEntry<DateTime, num>> points;
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.series,
    required this.unit,
    required this.palette,
  });

  final List<_PlottedSeries> series;
  final String? unit;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final allPoints = series.expand((s) => s.points).toList();
    final minX = allPoints
        .map((p) => p.key.millisecondsSinceEpoch)
        .reduce((a, b) => a < b ? a : b)
        .toDouble();
    final maxX = allPoints
        .map((p) => p.key.millisecondsSinceEpoch)
        .reduce((a, b) => a > b ? a : b)
        .toDouble();
    final xSpan = (maxX - minX) == 0 ? 1.0 : maxX - minX;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          horizontalInterval: null,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: palette.gridLine, strokeWidth: 1),
          drawVerticalLine: false,
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: palette.border),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) => Text(
                unit == null
                    ? value.toStringAsFixed(0)
                    : '${value.toStringAsFixed(0)}$unit',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: xSpan,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  DateFormat(
                    'MMM d, h:mm a',
                  ).format(DateTime.fromMillisecondsSinceEpoch(value.toInt())),
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        minX: minX,
        maxX: maxX,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final spot in spots)
                LineTooltipItem(
                  '${spot.y.toStringAsFixed(spot.y == spot.y.roundToDouble() ? 0 : 1)}${unit ?? ''}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                ),
            ],
          ),
        ),
        lineBarsData: [
          for (final s in series)
            LineChartBarData(
              spots: [
                for (final p in s.points)
                  FlSpot(
                    p.key.millisecondsSinceEpoch.toDouble(),
                    p.value.toDouble(),
                  ),
              ],
              isCurved: false,
              color: s.color,
              barWidth: 2.5,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(show: false),
            ),
        ],
      ),
    );
  }
}
