import { OrganizationCountry } from './set-organization-country-request';

export interface CreateOrganizationRequest {
  organizationName: string;
  adminEmail: string;
  adminFirstName: string;
  adminLastName: string;
  country: OrganizationCountry;
}
