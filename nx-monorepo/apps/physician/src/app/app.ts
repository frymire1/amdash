import { Component, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterOutlet } from '@angular/router';
import { NavBarComponent } from './components/nav-bar/nav-bar.component';
import { getAnalytics } from 'firebase/analytics';
import { getFirebaseApp } from './firebase';

@Component({
  selector: 'app-root',
  imports: [CommonModule, RouterOutlet, NavBarComponent],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {
  protected readonly title = signal('amdash');
  protected readonly doctorName = signal('Dr. Alex Chan');

  constructor() {
    getAnalytics(getFirebaseApp());
  }
}
