export interface GeocodeResult {
  status: string;
  results: Array<{ geometry: { location: { lat: number; lng: number } } }>;
}
