// Shared by the self-contained Patrol test runners (run-*-patrol-test.mjs)
// — permanent infrastructure, not a one-off script. Node/JS rather than
// Dart because it's just a process-spawning wrapper around the `patrol`
// CLI, called from the same Node scripts that use the Firebase Admin SDK
// for setup/teardown (see firebase-admin-cli.mjs) — no reason to split
// that across two languages.
//
// Spawns `patrol test --device <device>` against a given Flutter app.
// Runs both on a developer's Windows machine and in CI (a Codemagic Linux
// runner), which need genuinely different handling — Windows requires a
// shell to launch a .bat file at all, which then requires manual argv
// quoting (cmd.exe doesn't quote for you); POSIX needs neither.
//
// Android/iOS e2e no longer go through this file — they run on Firebase
// Test Lab via `patrol build` + `gcloud firebase test ... run` instead
// (see the Codemagic android-e2e/ios-e2e workflows), since `patrol test`
// against a local emulator/simulator device id has no equivalent on Test
// Lab's own device pool. `device` here is effectively always 'chrome' now
// (or a real device id when running this locally against a plugged-in
// phone/booted simulator for manual dev testing).
import { execFile, spawn } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const IS_WINDOWS = process.platform === 'win32';
const IS_MACOS = process.platform === 'darwin';

// Adjust these if your Windows machine's Flutter/pub-cache locations
// differ. Not used on Linux/macOS — CI's flutter-action and `dart pub
// global` already put both on PATH, so `patrol`/`flutter` resolve directly.
const FLUTTER_BIN = path.join(os.homedir(), 'flutter', 'bin');
const PUB_CACHE_BIN = path.join(os.homedir(), 'AppData', 'Local', 'Pub', 'Cache', 'bin');

// `device` is 'chrome' (default), 'android', 'ios', or an exact Flutter
// device id. An Android emulator's or iOS Simulator's real device id isn't
// known until CI boots it, so 'android'/'ios' are resolved dynamically
// here via `flutter devices --machine` rather than hardcoded — pick the
// first attached device of that platform type. Matched on `targetPlatform`
// (e.g. "android-x64", "ios") — confirmed via a real `--machine` run on
// this machine that there is no `platformType` field in this Flutter
// version's output, only `targetPlatform`.
async function resolveDeviceId(device) {
  if (device !== 'android' && device !== 'ios') return device;
  const { stdout } = await execFileAsync('flutter', ['devices', '--machine']);
  const devices = JSON.parse(stdout);
  const match = devices.find((d) => (d.targetPlatform ?? '').startsWith(device));
  if (!match) {
    throw new Error(`No connected '${device}' device found. flutter devices --machine returned: ${stdout}`);
  }
  return match.id;
}

// `patrol test` (via `flutter run -d web-server`) spawns its own dev
// server as a grandchild process. By the time it's actually running, it's
// been reparented away from our spawn's process tree (confirmed: `taskkill
// /T` against the top-level PID alone reliably misses it), so it outlives
// `patrol.bat` even on a normal, successful exit — not just on crashes.
// Left unchecked, every run leaks one more `dart.exe ... test_bundle.dart`
// process, and after enough of them accumulate on a long-lived dev machine
// they start starving new runs of resources (observed: dozens of leaked
// processes leading to a genuine native crash and then a dev server too
// resource-starved to serve its own scripts). CI runners are ephemeral —
// destroyed after the job — so this cleanup only runs on Windows, where it
// actually matters. Belt-and-suspenders: kill the spawned tree AND
// separately sweep for any dart.exe still running this app's test_bundle,
// matched by command line rather than by process-tree membership.
function killProcessTree(pid) {
  return new Promise((resolve) => {
    spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' }).on('close', () => resolve());
  });
}

function killOrphanedWebServer(appDir) {
  // PowerShell single-quoted strings treat backslash as a plain literal
  // character (no escaping needed or wanted) — only the quote character
  // itself needs doubling.
  const appDirEscaped = appDir.replace(/'/g, "''");
  const script = `Get-CimInstance Win32_Process -Filter "Name='dart.exe'" | Where-Object { $_.CommandLine -like '*test_bundle.dart*' -and $_.CommandLine -like '*${appDirEscaped}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
  return new Promise((resolve) => {
    spawn('powershell', ['-NoProfile', '-Command', script], { stdio: 'ignore' }).on('close', () => resolve());
  });
}

export async function runPatrolTest({
  appDir,
  target,
  dartDefines,
  device = 'chrome',
  // Web-only (Playwright browser context options patrol_cli passes
  // straight through) — mocks Geolocator.getCurrentPosition() so a
  // headless CI browser (no real GPS, no location permission prompt UI to
  // click through) can still exercise a real live-tracking flow. Plain
  // objects here, JSON-encoded below right where the CLI expects a JSON
  // string, rather than making every call site remember the exact
  // '{"latitude": ..., "longitude": ...}' / '["geolocation"]' shapes.
  webGeolocation,
  webPermissions,
}) {
  const resolvedDevice = await resolveDeviceId(device);

  return new Promise((resolve) => {
    const args = ['test', '--device', resolvedDevice, '--show-flutter-logs', '--verbose', '--target', target];

    if (IS_WINDOWS) {
      // With shell:true, spawn joins argv with plain spaces and hands the
      // whole line to cmd.exe — it does NOT quote entries for you, so any
      // --dart-define value containing a space (e.g. a hospital or patient
      // name) gets silently split into separate, unrelated argv words by
      // cmd.exe. Confirmed via a Dart-side debug print that a multi-word
      // SMOKE_HOSPITAL value arrived truncated at the first space.
      const quote = (arg) => (/\s/.test(arg) ? `"${arg}"` : arg);
      for (const [key, value] of Object.entries(dartDefines)) {
        args.push('--dart-define', quote(`${key}=${value}`));
      }
      // Best-effort escaping for local Windows testing — a naive
      // `"${json}"` wrap left patrol_cli receiving `{latitude:43.66,...}`
      // (cmd.exe strips every unescaped '"' as a quote-toggle, regardless
      // of surrounding context — no quote characters survived at all).
      // Backslash-escaping first (below) gets the quote characters
      // through cmd.exe's OWN parsing intact, confirmed via a direct
      // `cmd.exe /c` + a throwaway batch file that just echoed %*, but
      // patrol.bat is itself a batch file that forwards to the real
      // dart.exe executable via its own %* expansion — a *second* round
      // of Windows command-line parsing this value passes through, which
      // still isn't unmangling it correctly even with this escaping
      // (confirmed: same "must be a valid JSON" error via a direct
      // PowerShell invocation too, bypassing this file's spawn call
      // entirely — so it's not specific to how this script quotes it).
      // Chasing the exact right escaping through two nested layers of
      // cmd.exe/batch parsing is a real Windows-only rabbit hole that
      // doesn't affect CI at all: the POSIX branch below spawns `patrol`
      // directly via execve with no shell involved, so this whole problem
      // class doesn't exist there — args arrive at Dart's argv exactly as
      // JSON.stringify produced them. Left as the best available attempt
      // for local Windows dev convenience rather than fully solved.
      const quoteJson = (value) => `"${JSON.stringify(value).replaceAll('"', '\\"')}"`;
      if (webGeolocation) {
        args.push('--web-geolocation', quoteJson(webGeolocation));
      }
      if (webPermissions) {
        args.push('--web-permissions', quoteJson(webPermissions));
      }
      const extraPath = [FLUTTER_BIN, PUB_CACHE_BIN, process.env.Path ?? process.env.PATH ?? ''].join(
        path.delimiter,
      );
      // Set both casings — Git Bash's inherited env has PATH (POSIX
      // convention); native Windows child-process resolution wants Path.
      const env = { ...process.env, Path: extraPath, PATH: extraPath };
      // Absolute path, not relying on PATH resolution — Node's
      // child_process spawn on Windows is unreliable about honoring a
      // manually-constructed Path/PATH env var (case-sensitivity mismatch
      // between Git Bash's POSIX-style PATH and Windows' native Path), so
      // "patrol" alone resolves inconsistently depending on what shell
      // launched this script.
      const patrolBin = path.join(PUB_CACHE_BIN, 'patrol.bat');
      console.log('Running:', patrolBin, args.join(' '));
      const child = spawn(patrolBin, args, { cwd: appDir, env, shell: true, stdio: 'inherit' });
      child.on('close', async (code) => {
        await killProcessTree(child.pid);
        await killOrphanedWebServer(appDir);
        resolve(code ?? 1);
      });
    } else {
      // No shell involved on POSIX — argv entries reach patrol as discrete
      // strings straight from execve, so spaces in dart-define values need
      // no special handling (and quoting them would be actively wrong:
      // with no shell to interpret the quote characters, they'd become part
      // of the literal value).
      for (const [key, value] of Object.entries(dartDefines)) {
        args.push('--dart-define', `${key}=${value}`);
      }
      // No shell here either — no quoting needed, same reasoning as the
      // dart-defines above.
      if (webGeolocation) {
        args.push('--web-geolocation', JSON.stringify(webGeolocation));
      }
      if (webPermissions) {
        args.push('--web-permissions', JSON.stringify(webPermissions));
      }

      if (resolvedDevice === 'chrome' && !IS_MACOS) {
        // Patrol's underlying Playwright config launches Chromium headed
        // (not headless) — fine on a dev machine with a real display, but
        // a bare Linux CI runner has no X server for it to attach to
        // (confirmed: "browserType.launch: Target page, context or browser
        // has been closed" / "Missing X server or $DISPLAY"). xvfb-run
        // provides a virtual framebuffer so a headed browser can launch
        // anyway — the standard fix Playwright's own error message
        // suggests. Not needed (and not installed) on macOS CI runners,
        // which have a real display session unlike a bare Linux box — see
        // the `!IS_MACOS` guard above. Android/iOS runs don't involve a
        // browser at all (native instrumentation), so this wrapping is
        // web-only regardless of platform.
        const xvfbArgs = ['-a', 'patrol', ...args];
        console.log('Running: xvfb-run', xvfbArgs.join(' '));
        const child = spawn('xvfb-run', xvfbArgs, { cwd: appDir, stdio: 'inherit' });
        child.on('close', (code) => resolve(code ?? 1));
      } else {
        console.log('Running: patrol', args.join(' '));
        const child = spawn('patrol', args, { cwd: appDir, stdio: 'inherit' });
        child.on('close', (code) => resolve(code ?? 1));
      }
    }
  });
}
