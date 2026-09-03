// Shape of the Google Maps Directions REST API's own JSON response — not
// what this app returns to its clients (see FetchDirectionsResponse for
// that). `duration.value`/`distance.value` (seconds/meters) are read by
// directions.ts's callDirectionsApi for numeric comparisons (e.g. ems.ts's
// proximity-alert threshold check) — `.text` alone ("12 mins") isn't
// usable for that.
export interface DirectionsApiResult {
  status: string;
  routes: Array<{
    overview_polyline: { points: string };
    legs: Array<{ duration: { text: string; value: number }; distance: { text: string; value: number } }>;
  }>;
}
