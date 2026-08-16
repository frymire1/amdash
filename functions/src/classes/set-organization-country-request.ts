// ISO 3166-1 alpha-2 where one exists ('CA', 'US', 'GB', 'AU'), 'OTHER'
// otherwise — kept as a small closed set rather than a free-text field
// since 'CA' specifically gates the Canadian data-residency section in
// Settings, and a typo'd/inconsistent value there would silently hide it.
export type OrganizationCountry = 'CA' | 'US' | 'GB' | 'AU' | 'OTHER';

export interface SetOrganizationCountryRequest {
  country: OrganizationCountry;
}
