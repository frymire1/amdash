export interface PublishAmbulanceLocationRequest {
  ambulanceId: string;
  latitude: number;
  longitude: number;
  isTransporting: boolean;
}
