import { Component, inject, PLATFORM_ID, signal } from '@angular/core';
import { CommonModule, isPlatformBrowser } from '@angular/common';
import { RouterOutlet } from '@angular/router';
import { NavBarComponent } from './components/nav-bar/nav-bar.component';

// Import the functions you need from the SDKs you need
import { initializeApp } from 'firebase/app';
import { getAnalytics } from 'firebase/analytics';
// TODO: Add SDKs for Firebase products that you want to use
// https://firebase.google.com/docs/web/setup#available-libraries

// Your web app's Firebase configuration
// For Firebase JS SDK v7.20.0 and later, measurementId is optional
const firebaseConfig = {
  apiKey: 'AIzaSyDHOpM_Mi9NcMeZS8sD42olEMyN_MjVl5k',
  authDomain: 'amdash-dev.firebaseapp.com',
  projectId: 'amdash-dev',
  storageBucket: 'amdash-dev.firebasestorage.app',
  messagingSenderId: '577422583971',
  appId: '1:577422583971:web:488d6ba962843f924fb716',
  measurementId: 'G-QXETV3X3MD',
};

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
    // Firebase Analytics requires browser APIs (window, cookies) that
    // aren't present during SSR/prerendering.
    if (isPlatformBrowser(inject(PLATFORM_ID))) {
      const app = initializeApp(firebaseConfig);
      getAnalytics(app);
    }
  }
}
