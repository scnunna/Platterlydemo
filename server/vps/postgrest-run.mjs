// Runs PostgREST on the VPS and restarts it if it exits (start-vps.ps1 starts this; Node outlives the scheduled task).
// Usage: node postgrest-run.mjs <postgrest.exe> <postgrest.conf> <log file>
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const [exe, conf, logFile] = process.argv.slice(2);
const log = m => fs.appendFileSync(logFile, `${new Date().toISOString()} ${m}\n`);
let fails = 0;
function run() {
  const started = Date.now();
  const p = spawn(exe, [conf], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  p.stdout.on('data', d => fs.appendFileSync(logFile, d)); p.stderr.on('data', d => fs.appendFileSync(logFile, d));
  p.on('exit', (code, sig) => {
    fails = Date.now() - started > 60e3 ? 0 : fails + 1;
    const wait = Math.min(60, 2 ** fails);
    log(`postgrest exited (code ${code}${sig ? ', ' + sig : ''}); restarting in ${wait} s`);
    setTimeout(run, wait * 1000);
  });
}
log('supervisor started'); run();
