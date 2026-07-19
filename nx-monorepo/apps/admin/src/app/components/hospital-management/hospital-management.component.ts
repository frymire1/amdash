import { Component, inject, signal, ViewChild } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, FormGroupDirective, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { Hospital, HospitalService } from '@amdash/auth';
import { AdminService } from '../../services/admin.service';

@Component({
  selector: 'app-hospital-management',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
  ],
  templateUrl: './hospital-management.component.html',
  styleUrls: ['./hospital-management.component.scss'],
})
export class HospitalManagementComponent {
  private readonly formBuilder = inject(FormBuilder);
  private readonly adminService = inject(AdminService);
  private readonly hospitalService = inject(HospitalService);

  // Same reason as UserManagementComponent's createUserFormDirective: a
  // plain form.reset() clears values/touched but not the directive's own
  // `submitted` flag, which would otherwise leave required fields showing
  // red after a successful submit.
  @ViewChild('hospitalFormDirective') private readonly hospitalFormDirective!: FormGroupDirective;

  readonly hospitals = this.hospitalService.hospitals;

  readonly creating = signal(false);
  readonly createError = signal<string | null>(null);
  readonly createSuccess = signal<string | null>(null);

  readonly deletingId = signal<string | null>(null);
  readonly deleteError = signal<string | null>(null);

  readonly hospitalForm = this.formBuilder.nonNullable.group({
    name: ['', Validators.required],
    address: ['', Validators.required],
  });

  async onCreateHospital() {
    if (this.hospitalForm.invalid) {
      this.hospitalForm.markAllAsTouched();
      return;
    }

    const { name, address } = this.hospitalForm.getRawValue();

    this.creating.set(true);
    this.createError.set(null);
    this.createSuccess.set(null);

    try {
      await this.adminService.createHospital(name, address);
      this.createSuccess.set(`${name} was added.`);
      this.hospitalFormDirective.resetForm();
    } catch (error) {
      this.createError.set(this.toErrorMessage(error, 'Failed to add hospital. Please try again.'));
      console.error('Failed to create hospital', error);
    } finally {
      this.creating.set(false);
    }
  }

  async deleteHospital(hospital: Hospital) {
    this.deletingId.set(hospital.id);
    this.deleteError.set(null);

    try {
      await this.adminService.deleteHospital(hospital.id);
    } catch (error) {
      this.deleteError.set(this.toErrorMessage(error, 'Failed to delete hospital. Please try again.'));
      console.error('Failed to delete hospital', error);
    } finally {
      this.deletingId.set(null);
    }
  }

  private toErrorMessage(error: unknown, fallback: string): string {
    if (error instanceof Error && error.message) {
      return error.message;
    }
    return fallback;
  }
}
