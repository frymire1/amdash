import { Component, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { Patient } from '../../models/patient.model';
import { PatientUploadService } from '../../services/patient-upload.service';
import { PatientSessionService } from '../../services/patient-session.service';

@Component({
  selector: 'app-patient-upload',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatFormFieldModule,
    MatInputModule,
    MatSelectModule,
  ],
  templateUrl: './patient-upload.component.html',
  styleUrls: ['./patient-upload.component.scss'],
})
export class PatientUploadComponent implements OnInit {
  private readonly formBuilder = inject(FormBuilder);
  private readonly patientUploadService = inject(PatientUploadService);
  private readonly patientSessionService = inject(PatientSessionService);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);

  private editingId: string | null = null;

  readonly isEditing = signal(false);
  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);

  readonly patientForm = this.formBuilder.nonNullable.group({
    name: ['', Validators.required],
    gender: ['', Validators.required],
    age: [null as number | null, [Validators.required, Validators.min(0)]],
    healthcareNumber: ['', Validators.required],
    vitals: this.formBuilder.nonNullable.group({
      heartRate: [null as number | null, Validators.required],
      bloodPressure: ['', Validators.required],
      oxygen: [null as number | null, Validators.required],
      temperature: [null as number | null, Validators.required],
    }),
    location: this.formBuilder.nonNullable.group({
      latitude: [null as number | null, Validators.required],
      longitude: [null as number | null, Validators.required],
      address: ['', Validators.required],
    }),
  });

  ngOnInit() {
    const id = this.route.snapshot.paramMap.get('id');
    const uploaded = id ? this.patientSessionService.findUploadedPatient(id) : undefined;

    if (id && uploaded) {
      this.editingId = id;
      this.isEditing.set(true);
      this.patientForm.setValue({
        name: uploaded.patient.name,
        gender: uploaded.patient.gender,
        age: uploaded.patient.age,
        healthcareNumber: uploaded.patient.healthcareNumber,
        vitals: uploaded.patient.vitals,
        location: uploaded.patient.location,
      });
    }
  }

  async onSubmit() {
    if (this.patientForm.invalid) {
      this.patientForm.markAllAsTouched();
      return;
    }

    const value = this.patientForm.getRawValue();
    const patient: Patient = {
      name: value.name,
      gender: value.gender,
      age: value.age!,
      healthcareNumber: value.healthcareNumber,
      vitals: {
        heartRate: value.vitals.heartRate!,
        bloodPressure: value.vitals.bloodPressure,
        oxygen: value.vitals.oxygen!,
        temperature: value.vitals.temperature!,
      },
      location: {
        latitude: value.location.latitude!,
        longitude: value.location.longitude!,
        address: value.location.address,
      },
    };

    this.submitting.set(true);
    this.errorMessage.set(null);

    try {
      if (this.editingId) {
        await this.patientUploadService.updatePatient(this.editingId, patient);
        this.patientSessionService.upsertUploadedPatient(this.editingId, patient);
      } else {
        const id = await this.patientUploadService.uploadPatient(patient);
        this.patientSessionService.upsertUploadedPatient(id, patient);
      }
      this.router.navigate(['/']);
    } catch (error) {
      this.errorMessage.set('Failed to upload patient. Please try again.');
      console.error('Failed to upload patient', error);
    } finally {
      this.submitting.set(false);
    }
  }
}
