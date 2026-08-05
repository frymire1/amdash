// Shape of the Google Maps Directions REST API's own JSON response — not
// what this app returns to its clients (see FetchDirectionsResponse for
// that).
export interface DirectionsApiResult {
  status: string;
  routes: Array<{
    overview_polyline: { points: string };
    legs: Array<{ duration: { text: string }; distance: { text: string } }>;
  }>;
}
