export interface PublishAmbulanceLocationRequest {
  ambulanceId: string;
  phoneNumber: string;
  latitude: number;
  longitude: number;
  isTransporting: boolean;
}
