import { randomUUID } from 'crypto';

// Builds a FHIR R4 `Bundle` (type: "document", led by a `Composition`) for
// one completed EMS-to-ER handoff — the shape PS-CA/IPS-style Canadian
// patient summaries use, not a loose grab-bag of resources. Pure mapping
// only: no Firestore/KMS access here — patients.ts's exportPatientFhirBundle
// callable is what loads/decrypts the real data and hands it to
// buildPatientFhirBundle below.
//
// LOINC/UCUM codes here were chosen from the standard FHIR vital-signs
// examples and spot-checked (heart rate 8867-4, respiratory rate 9279-1)
// against the FHIR vital-signs spec during design — worth a final check
// against loinc.org before treating this as production-certified against
// a specific receiving hospital's import tooling.
const LOINC = {
  system: 'http://loinc.org',
  edTransferSummary: '78341-5', // "Emergency department Transfer summary note"
  vitalSignsSection: '8716-3', // standard "Vital signs" section/panel code
  heartRate: '8867-4',
  respiratoryRate: '9279-1',
  temperature: '8310-5',
  oxygenSaturation: '59408-5',
  bloodPressurePanel: '85354-9',
  systolicBp: '8480-6',
  diastolicBp: '8462-4',
  gcs: '9269-2',
  age: '30525-0',
} as const;

const SYSTEM = {
  observationCategory: 'http://terminology.hl7.org/CodeSystem/observation-category',
  v3ActCode: 'http://terminology.hl7.org/CodeSystem/v3-ActCode',
  ucum: 'http://unitsofmeasure.org',
  // Placeholder, not a real provincial OID (e.g. Ontario's OHIP system) —
  // AmDash doesn't track which province issued a given healthcare number,
  // so this can't be precise yet. See the plan's "Open questions."
  healthcareNumber: 'https://amdash.app/fhir/identifier/healthcare-number',
} as const;

const GENDER_MAP: Record<string, 'male' | 'female' | 'other'> = {
  Male: 'male',
  Female: 'female',
  Other: 'other',
};

export interface FhirExportPatientInput {
  name: string; // already decrypted
  healthcareNumber: string; // already decrypted
  gender: string;
  age: unknown; // number | 'Unknown'
  destination: string;
  organizationName: string;
  treatment?: string;
  notes?: string;
  ivSize?: string;
  ivPlacement?: string;
  status: string; // 'active' | 'completed'
  submittedAt: Date | null;
  completedAt: Date | null;
}

export interface FhirExportVitalsEntry {
  heartRate: unknown; // number | 'Unknown'
  bloodPressure: unknown; // "120/80" | ''
  oxygen: unknown; // number | 'Unknown'
  temperature: unknown; // number | 'Unknown'
  respiratoryRate?: number;
  gcs?: number;
  recordedAt: Date | null;
}

// Mirrors the Dart side's isProvidedValue() (patient.dart) — a numeric-ish
// vital field is either a real number or the 'Unknown' sentinel string; an
// unprovided reading is omitted from the export, never emitted as literal
// "Unknown" data.
function providedNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function splitBloodPressure(value: unknown): { systolic: number; diastolic: number } | null {
  if (typeof value !== 'string') return null;
  const parts = value.split('/');
  if (parts.length !== 2) return null;
  const systolic = Number(parts[0].trim());
  const diastolic = Number(parts[1].trim());
  if (!Number.isFinite(systolic) || !Number.isFinite(diastolic)) return null;
  return { systolic, diastolic };
}

function escapeXml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function narrative(bodyHtml: string): { status: 'generated'; div: string } {
  return { status: 'generated', div: `<div xmlns="http://www.w3.org/1999/xhtml">${bodyHtml}</div>` };
}

function urn(): string {
  return `urn:uuid:${randomUUID()}`;
}

interface UnitCode {
  display: string;
  ucum: string;
}

const UNIT = {
  bpm: { display: 'bpm', ucum: '/min' } as UnitCode,
  celsius: { display: '°C', ucum: 'Cel' } as UnitCode,
  percent: { display: '%', ucum: '%' } as UnitCode,
  breathsPerMin: { display: 'breaths/min', ucum: '/min' } as UnitCode,
  score: { display: '{score}', ucum: '{score}' } as UnitCode,
  mmHg: { display: 'mmHg', ucum: 'mm[Hg]' } as UnitCode,
  years: { display: 'years', ucum: 'a' } as UnitCode,
};

function vitalObservation(
  code: string,
  display: string,
  value: number,
  unit: UnitCode,
  patientUrn: string,
  effectiveDateTime: string | undefined,
): object {
  return {
    resourceType: 'Observation',
    status: 'final',
    category: [
      { coding: [{ system: SYSTEM.observationCategory, code: 'vital-signs', display: 'Vital Signs' }] },
    ],
    code: { coding: [{ system: LOINC.system, code, display }] },
    subject: { reference: patientUrn },
    ...(effectiveDateTime ? { effectiveDateTime } : {}),
    valueQuantity: { value, unit: unit.display, system: SYSTEM.ucum, code: unit.ucum },
  };
}

function bloodPressureObservation(
  bp: { systolic: number; diastolic: number },
  patientUrn: string,
  effectiveDateTime: string | undefined,
): object {
  return {
    resourceType: 'Observation',
    status: 'final',
    category: [
      { coding: [{ system: SYSTEM.observationCategory, code: 'vital-signs', display: 'Vital Signs' }] },
    ],
    code: { coding: [{ system: LOINC.system, code: LOINC.bloodPressurePanel, display: 'Blood pressure panel' }] },
    subject: { reference: patientUrn },
    ...(effectiveDateTime ? { effectiveDateTime } : {}),
    component: [
      {
        code: { coding: [{ system: LOINC.system, code: LOINC.systolicBp, display: 'Systolic blood pressure' }] },
        valueQuantity: { value: bp.systolic, unit: UNIT.mmHg.display, system: SYSTEM.ucum, code: UNIT.mmHg.ucum },
      },
      {
        code: { coding: [{ system: LOINC.system, code: LOINC.diastolicBp, display: 'Diastolic blood pressure' }] },
        valueQuantity: { value: bp.diastolic, unit: UNIT.mmHg.display, system: SYSTEM.ucum, code: UNIT.mmHg.ucum },
      },
    ],
  };
}

// One Observation per *provided* vital per vitalsHistory entry — the full
// trend, not just the final reading (vitalsHistory already is that trend,
// see patients.ts's appendVitalsHistory). A field that was never filled in
// (the 'Unknown' sentinel, or genuinely absent for the optional ones)
// simply produces no Observation for that reading, rather than a
// fabricated zero or a literal "Unknown" value.
function buildVitalsObservations(entries: FhirExportVitalsEntry[], patientUrn: string): object[] {
  const observations: object[] = [];
  for (const entry of entries) {
    const effectiveDateTime = entry.recordedAt?.toISOString();

    const heartRate = providedNumber(entry.heartRate);
    if (heartRate !== null) {
      observations.push(vitalObservation(LOINC.heartRate, 'Heart rate', heartRate, UNIT.bpm, patientUrn, effectiveDateTime));
    }

    const temperature = providedNumber(entry.temperature);
    if (temperature !== null) {
      observations.push(
        vitalObservation(LOINC.temperature, 'Body temperature', temperature, UNIT.celsius, patientUrn, effectiveDateTime),
      );
    }

    const oxygen = providedNumber(entry.oxygen);
    if (oxygen !== null) {
      observations.push(
        vitalObservation(LOINC.oxygenSaturation, 'Oxygen saturation', oxygen, UNIT.percent, patientUrn, effectiveDateTime),
      );
    }

    const respiratoryRate = providedNumber(entry.respiratoryRate);
    if (respiratoryRate !== null) {
      observations.push(
        vitalObservation(LOINC.respiratoryRate, 'Respiratory rate', respiratoryRate, UNIT.breathsPerMin, patientUrn, effectiveDateTime),
      );
    }

    const gcs = providedNumber(entry.gcs);
    if (gcs !== null) {
      observations.push(
        vitalObservation(LOINC.gcs, 'Glasgow coma score total', gcs, UNIT.score, patientUrn, effectiveDateTime),
      );
    }

    const bloodPressure = splitBloodPressure(entry.bloodPressure);
    if (bloodPressure !== null) {
      observations.push(bloodPressureObservation(bloodPressure, patientUrn, effectiveDateTime));
    }
  }
  return observations;
}

// A known age without a known birthdate is honestly represented as its
// own Observation (LOINC 30525-0 "Age") — NOT as a fabricated
// Patient.birthDate. AmDash only ever stores age (a number), never a real
// birthdate, and guessing one from age would be actively wrong, not just
// imprecise.
function buildAgeObservation(age: unknown, patientUrn: string): object | null {
  const value = providedNumber(age);
  if (value === null) return null;
  return {
    resourceType: 'Observation',
    status: 'final',
    code: { coding: [{ system: LOINC.system, code: LOINC.age, display: 'Age' }] },
    subject: { reference: patientUrn },
    valueQuantity: { value, unit: UNIT.years.display, system: SYSTEM.ucum, code: UNIT.years.ucum },
  };
}

function buildPatient(patient: FhirExportPatientInput, patientUrn: string): { fullUrl: string; resource: object } {
  const identifiers =
    patient.healthcareNumber && patient.healthcareNumber !== 'Unknown'
      ? [{ system: SYSTEM.healthcareNumber, value: patient.healthcareNumber }]
      : undefined;

  return {
    fullUrl: patientUrn,
    resource: {
      resourceType: 'Patient',
      // AmDash stores one free-text name, not separate given/family — a
      // guessed split risks silently mangling a real name, so this uses
      // FHIR's own `text`-only HumanName form instead.
      name: [{ text: patient.name }],
      gender: GENDER_MAP[patient.gender] ?? 'unknown',
      ...(identifiers ? { identifier: identifiers } : {}),
    },
  };
}

function buildEncounter(
  patient: FhirExportPatientInput,
  patientUrn: string,
  encounterUrn: string,
  organizationUrn: string,
): { fullUrl: string; resource: object } {
  const period: Record<string, string> = {};
  if (patient.submittedAt) period.start = patient.submittedAt.toISOString();
  if (patient.completedAt) period.end = patient.completedAt.toISOString();

  const hasDestination = patient.destination && patient.destination !== 'Unknown';

  return {
    fullUrl: encounterUrn,
    resource: {
      resourceType: 'Encounter',
      status: patient.status === 'completed' ? 'finished' : 'in-progress',
      class: { system: SYSTEM.v3ActCode, code: 'EMER', display: 'emergency' },
      subject: { reference: patientUrn },
      serviceProvider: { reference: organizationUrn, display: patient.organizationName },
      ...(Object.keys(period).length > 0 ? { period } : {}),
      // Reference-by-display only — the destination hospital is free text
      // EMS typed (Patient.destination), not linked to a real FHIR
      // Location/Organization resource (AmDash's own `hospitals`
      // collection isn't actually referenced by a patient's destination
      // field today), so this is the correct FHIR idiom for "we know the
      // name, not a resolvable resource."
      ...(hasDestination ? { location: [{ location: { display: patient.destination } }] } : {}),
    },
  };
}

function buildTreatmentNarrativeHtml(patient: FhirExportPatientInput): string | null {
  const parts: string[] = [];
  if (patient.treatment) parts.push(`<p><strong>Treatment given:</strong> ${escapeXml(patient.treatment)}</p>`);
  if (patient.ivSize || patient.ivPlacement) {
    const ivBits = [patient.ivSize, patient.ivPlacement].filter((v): v is string => Boolean(v)).map(escapeXml).join(', ');
    parts.push(`<p><strong>IV access:</strong> ${ivBits}</p>`);
  }
  if (patient.notes) parts.push(`<p><strong>Notes:</strong> ${escapeXml(patient.notes)}</p>`);
  return parts.length > 0 ? parts.join('') : null;
}

function buildComposition({
  patient,
  patientUrn,
  encounterUrn,
  organizationUrn,
  vitalsObservationEntries,
}: {
  patient: FhirExportPatientInput;
  patientUrn: string;
  encounterUrn: string;
  organizationUrn: string;
  vitalsObservationEntries: { fullUrl: string; resource: object }[];
}): object {
  const sections: object[] = [];

  // Age isn't a vital sign — it's referenced in the Bundle (see
  // buildPatientFhirBundle) but deliberately left out of this section,
  // which only ever lists the actual vitalsHistory-derived readings.
  if (vitalsObservationEntries.length > 0) {
    sections.push({
      title: 'Vital Signs',
      code: { coding: [{ system: LOINC.system, code: LOINC.vitalSignsSection, display: 'Vital signs' }] },
      entry: vitalsObservationEntries.map((e) => ({ reference: e.fullUrl })),
    });
  }

  const treatmentHtml = buildTreatmentNarrativeHtml(patient);
  if (treatmentHtml) {
    sections.push({ title: 'Treatment & Notes', text: narrative(treatmentHtml) });
  }

  const destination = patient.destination && patient.destination !== 'Unknown' ? patient.destination : 'Not recorded';
  sections.push({
    title: 'Transport',
    text: narrative(`<p><strong>Destination:</strong> ${escapeXml(destination)}</p>`),
  });

  return {
    resourceType: 'Composition',
    status: 'final',
    type: { coding: [{ system: LOINC.system, code: LOINC.edTransferSummary, display: 'Emergency department Transfer summary note' }] },
    subject: { reference: patientUrn },
    encounter: { reference: encounterUrn },
    date: (patient.completedAt ?? new Date()).toISOString(),
    // No individual EMS practitioner identity is captured anywhere in
    // AmDash's own data model (vitalsHistory's `recordedBy` is an
    // internal Firebase uid, not a real practitioner registration) — the
    // honest author reference is the EMS organization itself, not a
    // synthesized fake Practitioner.
    author: [{ reference: organizationUrn, display: patient.organizationName }],
    title: 'EMS to ER Handoff Summary',
    section: sections,
  };
}

// The one exported entry point — patients.ts's exportPatientFhirBundle
// callable loads/decrypts the real Firestore data and calls this with it.
export function buildPatientFhirBundle(patient: FhirExportPatientInput, vitalsHistory: FhirExportVitalsEntry[]): object {
  const patientUrn = urn();
  const encounterUrn = urn();
  const organizationUrn = urn();
  const compositionUrn = urn();

  const patientEntry = buildPatient(patient, patientUrn);
  const encounterEntry = buildEncounter(patient, patientUrn, encounterUrn, organizationUrn);
  const organizationEntry = { fullUrl: organizationUrn, resource: { resourceType: 'Organization', name: patient.organizationName } };

  const ageObservation = buildAgeObservation(patient.age, patientUrn);
  const ageEntry = ageObservation ? [{ fullUrl: urn(), resource: ageObservation }] : [];
  const vitalsObservationEntries = buildVitalsObservations(vitalsHistory, patientUrn).map((resource) => ({
    fullUrl: urn(),
    resource,
  }));

  const composition = buildComposition({
    patient,
    patientUrn,
    encounterUrn,
    organizationUrn,
    vitalsObservationEntries,
  });

  return {
    resourceType: 'Bundle',
    type: 'document',
    timestamp: new Date().toISOString(),
    identifier: { system: 'https://amdash.app/fhir/bundle-id', value: randomUUID() },
    entry: [
      { fullUrl: compositionUrn, resource: composition },
      patientEntry,
      encounterEntry,
      organizationEntry,
      ...ageEntry,
      ...vitalsObservationEntries,
    ],
  };
}
