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

    // Sized off the actual screen rather than a fixed 360x280 — fine on a
    // desktop/tablet-width Chrome window, but a fixed 360 content width
    // can overflow an AlertDialog's own inset padding on a narrow phone
    // screen (native Android/iOS, or a narrow mobile-web viewport).
    // Clamped both ways: never so wide it looks silly on a big screen,
    // never so narrow the chart has no room to breathe.
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = (screenSize.width * 0.86).clamp(260.0, 420.0);
    final dialogHeight = (screenSize.height * 0.42).clamp(220.0, 320.0);

    return AlertDialog(
      title: unit == null
          ? Text(title)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title),
                const SizedBox(width: 6),
                Text(
                  unit!.trim(),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.normal, color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
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
    final allTimestamps = series.expand((s) => s.points.map((p) => p.key));
    final minTime = allTimestamps.reduce((a, b) => a.isBefore(b) ? a : b);
    final maxTime = allTimestamps.reduce((a, b) => a.isAfter(b) ? a : b);

    // Every FlSpot's x below is elapsed milliseconds *since minTime*, not
    // raw millisecondsSinceEpoch. Epoch values are huge (~1.8 trillion) —
    // fl_chart generates candidate tick positions as multiples of
    // `interval` from an internal baseline, and a huge, essentially
    // arbitrary minX/maxX almost never lines up cleanly with those
    // multiples. The real symptom (caught on a real device screenshot):
    // two mispositioned, overlapping date labels bunched at one edge
    // instead of one under each point. Shifting the origin to 0 makes
    // minX exactly a clean multiple of any interval — a candidate at
    // exactly 0 and exactly xSpan is then guaranteed, not a coin flip.
    final xSpan = maxTime.difference(minTime).inMilliseconds.toDouble();
    final safeXSpan = xSpan == 0 ? 1.0 : xSpan;
    final sameDay = minTime.year == maxTime.year && minTime.month == maxTime.month && minTime.day == maxTime.day;
    // No need to repeat the date on both ends when it's the same day —
    // shorter labels, less crowding, especially on a narrow phone screen.
    final axisFormat = DateFormat(sameDay ? 'h:mm a' : 'MMM d, h:mm a');
    final tooltipFormat = DateFormat('MMM d, h:mm a');

    double elapsedX(DateTime time) => time.difference(minTime).inMilliseconds.toDouble();

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
              // Bare numbers only — no per-tick unit suffix (that's what
              // was wrapping to a second line and looking terrible; the
              // unit now shows once, in the dialog's own title instead).
              reservedSize: 34,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                child: Text(
                  value.toStringAsFixed(0),
                  style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          // Only the first and last reading get an axis label. Real vitals
          // history is usually just a handful of entries clustered close
          // together in time — spacing labels by a computed time interval
          // (fl_chart's usual approach) either crowds several illegibly or
          // mislabels them outright (see the xSpan comment above). Any
          // point in between is still exactly readable via its tooltip.
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: safeXSpan,
              getTitlesWidget: (value, meta) {
                final isStart = value <= safeXSpan / 2;
                return SideTitleWidget(
                  // fitInside nudges each label to stay inside the plot's
                  // own bounds instead of overflowing past its edge (the
                  // "bled into the y-axis label" half of the original
                  // bug) — the min/maxTime shift above is what stops the
                  // two labels from landing on top of each other in the
                  // first place.
                  meta: meta,
                  fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                  child: Text(
                    axisFormat.format(isStart ? minTime : maxTime),
                    style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                );
              },
            ),
          ),
        ),
        minX: 0,
        maxX: safeXSpan,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final spot in spots)
                LineTooltipItem(
                  '${spot.y.toStringAsFixed(spot.y == spot.y.roundToDouble() ? 0 : 1)}${unit ?? ''}',
                  const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  children: [
                    // Exact timestamp, now that the axis itself only ever
                    // labels the two endpoints — this is how an
                    // in-between point's own time is still discoverable.
                    TextSpan(
                      text: '\n${tooltipFormat.format(minTime.add(Duration(milliseconds: spot.x.round())))}',
                      style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.normal),
                    ),
                  ],
                ),
            ],
          ),
        ),
        lineBarsData: [
          for (final s in series)
            LineChartBarData(
              spots: [
                for (final p in s.points) FlSpot(elapsedX(p.key), p.value.toDouble()),
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
