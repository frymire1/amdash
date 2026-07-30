import { Component, ViewChild, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, FormGroupDirective, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { OrganizationService } from '../../services/organization.service';
import { AdminService } from '../../services/admin.service';

@Component({
  selector: 'app-organization-management',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatFormFieldModule,
    MatInputModule,
    MatProgressSpinnerModule,
  ],
  templateUrl: './organization-management.component.html',
  styleUrls: ['./organization-management.component.scss'],
})
export class OrganizationManagementComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly adminService = inject(AdminService);
  private readonly organizationService = inject(OrganizationService);

  // Same reason as UserManagementComponent's createUserFormDirective: a
  // plain form.reset() clears values/touched but not the directive's own
  // `submitted` flag, which would otherwise leave required fields showing
  // red after a successful submit.
  @ViewChild('organizationFormDirective') private readonly organizationFormDirective!: FormGroupDirective;

  readonly organizations = this.organizationService.organizations;

  readonly creating = signal(false);
  readonly createError = signal<string | null>(null);
  readonly createSuccess = signal<string | null>(null);

  // createOrganization (functions/src/index.ts) creates the organization AND
  // its first admin together, in one call — an org with zero admins would be
  // unreachable through any other UI path, so there's deliberately no
  // "create an empty organization" option here.
  readonly organizationForm = this.formBuilder.nonNullable.group({
    organizationName: ['', Validators.required],
    adminEmail: ['', [Validators.required, Validators.email]],
    adminFirstName: ['', Validators.required],
    adminLastName: ['', Validators.required],
  });

  async onCreateOrganization() {
    if (this.organizationForm.invalid) {
      this.organizationForm.markAllAsTouched();
      return;
    }

    const { organizationName, adminEmail, adminFirstName, adminLastName } = this.organizationForm.getRawValue();

    this.creating.set(true);
    this.createError.set(null);
    this.createSuccess.set(null);

    try {
      await this.adminService.createOrganization(organizationName, adminEmail, adminFirstName, adminLastName);
      this.createSuccess.set(
        `${organizationName} was created, with ${adminEmail} as its admin. They'll set their password the next time they use "Create Account" on the login page with this same email.`,
      );
      this.organizationFormDirective.resetForm();
    } catch (error) {
      this.createError.set(this.toErrorMessage(error, 'Failed to create organization. Please try again.'));
      console.error('Failed to create organization', error);
    } finally {
      this.creating.set(false);
    }
  }

  private toErrorMessage(error: unknown, fallback: string): string {
    if (error instanceof Error && error.message) {
      return error.message;
    }
    return fallback;
  }
}
