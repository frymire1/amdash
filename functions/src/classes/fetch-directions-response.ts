export type FetchDirectionsResponse =
  | { found: true; polylinePoints: Array<[number, number]>; durationText: string; distanceText: string }
  | { found: false };
