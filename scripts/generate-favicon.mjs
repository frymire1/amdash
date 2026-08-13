#!/usr/bin/env node
// One-time asset-generation script — regenerates the marketing site's
// favicon/apple-touch-icon from the finalized Arctic Cyan app icon
// (flutter/apps/ems/assets/icon/icon.png, the same source every Flutter
// app's launcher icon comes from) so the brand mark matches everywhere.
// Not part of CI, run manually. Requires `npx png-to-ico` (fetched
// on-demand, not an installed dependency) to bundle multi-resolution
// PNGs into a real .ico.
import { chromium } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(REPO_ROOT, 'flutter', 'apps', 'ems', 'assets', 'icon', 'icon.png');
const PUBLIC_DIR = path.join(REPO_ROOT, 'marketing', 'public');

async function resize(sourceDataUri, size) {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: size, height: size } });
    await page.setContent(`<!doctype html><html><body>
      <img id="src" src="${sourceDataUri}" style="display:none" />
      <canvas id="c" width="${size}" height="${size}"></canvas>
      <script>
        window.ready = false;
        const img = document.getElementById('src');
        function draw() {
          document.getElementById('c').getContext('2d').drawImage(img, 0, 0, ${size}, ${size});
          window.ready = true;
        }
        if (img.complete) draw(); else img.onload = draw;
      </script>
    </body></html>`);
    await page.waitForFunction('window.ready === true');
    const dataUrl = await page.$eval('#c', (c) => c.toDataURL('image/png'));
    return Buffer.from(dataUrl.split(',')[1], 'base64');
  } finally {
    await browser.close();
  }
}

const sourceBuffer = await readFile(SOURCE);
const sourceDataUri = `data:image/png;base64,${sourceBuffer.toString('base64')}`;

await mkdir(PUBLIC_DIR, { recursive: true });

const sizes = [16, 32, 48];
const tmpPaths = [];
for (const size of sizes) {
  const buf = await resize(sourceDataUri, size);
  const p = path.join(PUBLIC_DIR, `.favicon-${size}.png`);
  await writeFile(p, buf);
  tmpPaths.push(p);
  console.log(`Rendered ${size}x${size}`);
}

const icoBuffer = execFileSync('npx', ['--yes', 'png-to-ico', ...tmpPaths], { shell: true });
await writeFile(path.join(PUBLIC_DIR, 'favicon.ico'), icoBuffer);
console.log('Wrote favicon.ico');

for (const p of tmpPaths) await rm(p);

const touchIconBuf = await resize(sourceDataUri, 180);
await writeFile(path.join(PUBLIC_DIR, 'apple-touch-icon.png'), touchIconBuf);
console.log('Wrote apple-touch-icon.png');
