#!/usr/bin/env node
// One-time asset-regeneration script for the Arctic Cyan retheme's app
// icon — not part of CI, run manually whenever the icon needs
// regenerating. Recolors the EXISTING pulse-into-arrow mark (reusing
// physician/ems's existing assets/icon/icon-foreground.png as the source
// silhouette, rather than redrawing it from scratch) onto the approved
// "#3: teal gradient" treatment via a Playwright-driven canvas (no
// image-editing tooling exists in this repo otherwise). Same mark, same
// rounded-square shape as the icon that shipped before — only the
// color/gradient/scale treatment changes. Scaled up (see MARK_SCALE) and
// drawn with no glow/shadow, so the mark reads clearly at small sizes.
//
// Produces, per app:
//   - icon.png: rounded-square, full gradient background + mark — the
//     master source flutter_launcher_icons.yaml points at, and (since
//     it's already self-contained/rounded) what admin's web-only icon
//     set uses directly.
//   - icon-foreground.png (physician/ems only, which have Android
//     targets): transparent background, mark only, kept inside Android
//     adaptive icons' ~66% center safe zone — composited over
//     `adaptive_icon_background` by Android itself, so no rounding is
//     baked in here.
import { chromium } from '@playwright/test';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

async function toDataUri(filePath) {
  const buffer = await readFile(filePath);
  return `data:image/png;base64,${buffer.toString('base64')}`;
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');

const BG_FROM = '#0f201e';
const BG_TO = '#071618';
const MARK_COLOR = '#33d6e6';
const CORNER_RADIUS = 180; // matches the existing icon's proportions
// The source mark has a fair bit of margin baked in — scale it up
// (centered) so it fills more of the icon and reads clearly at small
// sizes. 1.45 keeps the arrow tip comfortably inside both the rounded
// square and Android's adaptive-icon safe zone.
const MARK_SCALE = 1.45;

function pageHtml(markFileUrl) {
  return `<!doctype html>
<html>
  <head><meta charset="utf-8" /></head>
  <body>
    <img id="mark" src="${markFileUrl}" style="display:none" />
    <canvas id="withBg" width="1024" height="1024"></canvas>
    <canvas id="fgOnly" width="1024" height="1024"></canvas>
    <script>
      window.renderReady = false;

      function recolor(ctx, img, color) {
        // Scaled up and centered — the source mark has margin baked in;
        // this crops into it so the mark fills more of the icon.
        const size = 1024 * ${MARK_SCALE};
        const offset = (1024 - size) / 2;
        ctx.drawImage(img, offset, offset, size, size);
        ctx.globalCompositeOperation = 'source-in';
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, 1024, 1024);
        ctx.globalCompositeOperation = 'source-over';
      }

      function drawMark(ctx, off) {
        ctx.drawImage(off, 0, 0);
      }

      function render() {
        const img = document.getElementById('mark');

        // Recolored (cyan) mark on an offscreen canvas, reused for both outputs.
        const off = document.createElement('canvas');
        off.width = 1024;
        off.height = 1024;
        recolor(off.getContext('2d'), img, '${MARK_COLOR}');

        // icon.png: rounded-square gradient background + glowing mark.
        const bgCanvas = document.getElementById('withBg');
        const bgCtx = bgCanvas.getContext('2d');
        bgCtx.save();
        bgCtx.beginPath();
        bgCtx.roundRect(0, 0, 1024, 1024, ${CORNER_RADIUS});
        bgCtx.clip();
        const grad = bgCtx.createLinearGradient(0, 0, 1024, 1024);
        grad.addColorStop(0, '${BG_FROM}');
        grad.addColorStop(1, '${BG_TO}');
        bgCtx.fillStyle = grad;
        bgCtx.fillRect(0, 0, 1024, 1024);
        drawMark(bgCtx, off);
        bgCtx.restore();

        // icon-foreground.png: transparent background, mark only.
        const fgCtx = document.getElementById('fgOnly').getContext('2d');
        drawMark(fgCtx, off);

        window.renderReady = true;
      }

      const img = document.getElementById('mark');
      if (img.complete) render();
      else img.onload = render;
    </script>
  </body>
</html>`;
}

// A fresh page per render — page.setContent() rewrites the document but
// doesn't reset the JS global scope, so a second setContent() call on the
// same page throws ("Identifier 'img' has already been declared") and
// silently leaves that page's canvases blank.
async function recolorApp({ browser, markDataUri, outIconPath, outForegroundPath }) {
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  page.on('console', (msg) => console.log('BROWSER:', msg.text()));
  page.on('pageerror', (err) => console.log('PAGEERROR:', err));
  try {
    await page.setContent(pageHtml(markDataUri));
    await page.waitForFunction('window.renderReady === true');

    const bgData = await page.$eval('#withBg', (c) => c.toDataURL('image/png'));
    await writeFile(outIconPath, Buffer.from(bgData.split(',')[1], 'base64'));

    if (outForegroundPath) {
      const fgData = await page.$eval('#fgOnly', (c) => c.toDataURL('image/png'));
      await writeFile(outForegroundPath, Buffer.from(fgData.split(',')[1], 'base64'));
    }
  } finally {
    await page.close();
  }
}

const browser = await chromium.launch();
try {
  // Read every source mark image up front, before any output file is
  // written — both physician/ems write back to the same path they read
  // from (icon-foreground.png), and admin reuses ems's mark, so writing
  // as we go would feed an already-recolored image into a later step.
  const emsMarkPath = path.join(REPO_ROOT, 'flutter', 'apps', 'ems', 'assets', 'icon', 'icon-foreground.png');
  const markDataUris = {
    physician: await toDataUri(path.join(REPO_ROOT, 'flutter', 'apps', 'physician', 'assets', 'icon', 'icon-foreground.png')),
    ems: await toDataUri(emsMarkPath),
  };

  // physician/ems already have their own icon-foreground.png (the
  // isolated mark) — recolor both icon.png and icon-foreground.png from it.
  for (const app of ['physician', 'ems']) {
    const iconDir = path.join(REPO_ROOT, 'flutter', 'apps', app, 'assets', 'icon');
    await recolorApp({
      browser,
      markDataUri: markDataUris[app],
      outIconPath: path.join(iconDir, 'icon.png'),
      outForegroundPath: path.join(iconDir, 'icon-foreground.png'),
    });
    console.log(`Updated ${app} icon.png + icon-foreground.png`);
  }

  // admin is web-only (no Android adaptive icon), and has no
  // icon-foreground.png of its own — reuse ems's (pre-read) mark as the
  // source silhouette, write only icon.png.
  const adminIconDir = path.join(REPO_ROOT, 'flutter', 'apps', 'admin', 'assets', 'icon');
  await recolorApp({ browser, markDataUri: markDataUris.ems, outIconPath: path.join(adminIconDir, 'icon.png') });
  console.log('Updated admin icon.png');
} finally {
  await browser.close();
}

console.log('Done. Run `dart run flutter_launcher_icons` in each Flutter app to regenerate platform icons.');
