/// Google Directions REST API key — used by [DirectionsService] for the
/// route/ETA overlay on the patient map. This is a distinct concern from
/// the `google_maps_flutter` map-rendering API key (configured per-platform
/// in AndroidManifest.xml/AppDelegate.swift/web bootstrap): that one is a
/// tile-rendering key restricted by app package/bundle ID, while this one
/// makes plain HTTPS REST calls with no such restriction available for
/// mobile — see the platform-config step for the key strategy this ended
/// up using.
const directionsApiKey = String.fromEnvironment('DIRECTIONS_API_KEY');
