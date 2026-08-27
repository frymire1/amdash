import 'package:flutter/material.dart';

import '../models/patient.dart';
import '../theme/app_theme.dart';

/// `PatientVitals`' numeric-ish fields (heartRate/oxygen/temperature) are
/// typed `Object?` because they can also be the 'Unknown' string sentinel —
/// coerces to a real number, or null if it isn't one.
num? numOrNull(Object? value) => value is num ? value : null;

/// Splits a "120/80"-shaped blood pressure reading into its systolic
/// (index 0) or diastolic (index 1) half, or null if it isn't in that shape
/// at all (missing, or the 'Unknown' sentinel — splitting either by '/'
/// yields a single-element list, so this returns null for both parts
/// without needing to special-case the sentinel directly).
num? bloodPressurePart(String bloodPressure, int index) {
  final parts = bloodPressure.split('/');
  if (parts.length != 2) return null;
  return num.tryParse(parts[index].trim());
}

/// Where a vital reading sits relative to typical *adult* reference ranges.
/// Deliberately general/illustrative bands, not age-adjusted, not sourced
/// from a single official guideline, and not a substitute for clinical
/// judgment — same spirit as this app's other "real but approximate"
/// disclaimers (e.g. the FHIR export's identifier-system caveat). Drives
/// [PatientInfoChip]/[PatientVitalsChips]'s shading only — never gates any
/// workflow or is sent anywhere itself.
enum VitalStatus { safe, moderate, danger }

/// [status]'s themed color, from the same success/warning/critical tokens
/// [StatusPill] already uses — so a "danger" vital chip and a "critical"
/// tracking pill read as the same red across the app, not two different
/// reds.
Color vitalStatusColor(AppPalette palette, VitalStatus status) => switch (status) {
  VitalStatus.safe => palette.success,
  VitalStatus.moderate => palette.warning,
  VitalStatus.danger => palette.critical,
};

/// A visibly darker shade of [color], for a status chip's outline against
/// its own tinted fill. HSL lightness reduction rather than a lower-alpha
/// blend — reads as genuinely "darker" regardless of what's behind the
/// chip, rather than just "more saturated".
Color darkenForOutline(Color color, [double amount = 0.16]) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0)).toColor();
}

/// Adult resting heart rate: normal 60-100 bpm; mild tachycardia/bradycardia
/// out to 50/120; beyond that is the kind of reading that gets a second
/// look.
VitalStatus? heartRateStatus(Object? value) {
  final bpm = numOrNull(value);
  if (bpm == null) return null;
  if (bpm < 50 || bpm > 120) return VitalStatus.danger;
  if (bpm < 60 || bpm > 100) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// SpO2: ≥95% normal, 90-94% mild-to-moderate hypoxemia, <90% severe.
VitalStatus? oxygenStatus(Object? value) {
  final spo2 = numOrNull(value);
  if (spo2 == null) return null;
  if (spo2 < 90) return VitalStatus.danger;
  if (spo2 < 95) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Core temperature: ~36.1-37.9°C normal; fever/hypothermia bands out to
/// 38.0/35.1; beyond 39.5/35.0 is hyperpyrexia/significant hypothermia.
VitalStatus? temperatureStatus(Object? value) {
  final celsius = numOrNull(value);
  if (celsius == null) return null;
  if (celsius <= 35.0 || celsius >= 39.5) return VitalStatus.danger;
  if (celsius < 36.1 || celsius >= 38.0) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Adult respiratory rate: normal 12-20 breaths/min; 8-11 or 21-24 is
/// notable; outside that range is a red flag on its own.
VitalStatus? respiratoryRateStatus(int? value) {
  if (value == null) return null;
  if (value < 8 || value > 24) return VitalStatus.danger;
  if (value < 12 || value > 20) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Glasgow Coma Scale: the standard 13-15 mild/normal, 9-12 moderate, ≤8
/// severe bands (the last is the classic "consider airway management"
/// threshold).
VitalStatus? gcsStatus(int? value) {
  if (value == null) return null;
  if (value <= 8) return VitalStatus.danger;
  if (value <= 12) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Systolic ~90-139 normal-ish; <90 is the classic hypotension/shock
/// threshold, ≥160 a hypertensive-urgency-range reading.
VitalStatus _systolicStatus(num value) {
  if (value < 90 || value >= 160) return VitalStatus.danger;
  if (value < 100 || value >= 140) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Diastolic ~60-89 normal-ish; <50 or ≥100 the corresponding danger band.
VitalStatus _diastolicStatus(num value) {
  if (value < 50 || value >= 100) return VitalStatus.danger;
  if (value < 60 || value >= 90) return VitalStatus.moderate;
  return VitalStatus.safe;
}

/// Blood pressure is one "120/80" reading covering two numbers — this
/// reports whichever half is worse (e.g. a normal diastolic doesn't soften
/// a dangerously low systolic). Null only when neither half parses (missing
/// or the 'Unknown' sentinel); a single missing half still gets a status
/// from whichever half is present.
VitalStatus? bloodPressureStatus(String value) {
  if (!isProvidedValue(value)) return null;
  final systolic = bloodPressurePart(value, 0);
  final diastolic = bloodPressurePart(value, 1);

  VitalStatus? result;
  if (systolic != null) result = _systolicStatus(systolic);
  if (diastolic != null) {
    final diastolicStatus = _diastolicStatus(diastolic);
    result = result == null || diastolicStatus.index > result.index ? diastolicStatus : result;
  }
  return result;
}
