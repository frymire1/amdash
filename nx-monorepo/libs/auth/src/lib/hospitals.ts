export interface Hospital {
  name: string;
  latitude: number;
  longitude: number;
}

// Shared by the EMS app's destination-hospital picker and the physician
// app's work-location picker, so a hospital name means the same physical
// place — and therefore the same coordinates — in both apps.
export const HOSPITALS: readonly Hospital[] = [
  { name: 'General Hospital', latitude: 43.6591, longitude: -79.3656 },
  { name: "St. Mary's Medical Center", latitude: 43.6426, longitude: -79.3871 },
  { name: 'Riverside Trauma Center', latitude: 43.6677, longitude: -79.3948 },
  { name: 'University Medical Center', latitude: 43.6629, longitude: -79.3957 },
  { name: 'Mercy Regional Hospital', latitude: 43.6205, longitude: -79.5132 },
];

export const HOSPITAL_NAMES: readonly string[] = HOSPITALS.map((hospital) => hospital.name);

export function findHospital(name: string | undefined): Hospital | undefined {
  return HOSPITALS.find((hospital) => hospital.name === name);
}
