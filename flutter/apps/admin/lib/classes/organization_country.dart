/// Mirrors `OrganizationCountry` (`functions/src/classes/set-organization-
/// country-request.ts`) — kept as a small closed set (not free text) since
/// 'CA' specifically adds a CLOUD Act / data-residency callout to the
/// Cloud KMS encryption section in Settings (that section itself is open
/// to every org, not gated by country — see
/// `setOrganizationCmekPreference`'s own doc comment), and this is shared
/// between the org-creation form (organization_management_screen.dart) and
/// the self-service editor (organization_settings_screen.dart) so the two
/// never drift apart.
const organizationCountries = {
  'CA': 'Canada',
  'US': 'United States',
  'GB': 'United Kingdom',
  'AU': 'Australia',
  'OTHER': 'Other',
};
