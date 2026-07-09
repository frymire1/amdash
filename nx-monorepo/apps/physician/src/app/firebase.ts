import { FirebaseApp, getApp, getApps, initializeApp } from 'firebase/app';

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

export function getFirebaseApp(): FirebaseApp {
  return getApps().length ? getApp() : initializeApp(firebaseConfig);
}
