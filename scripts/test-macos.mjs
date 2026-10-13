#!/usr/bin/env node
// AppKit tests cannot reliably share one process: an early exit can even return
// status 0. Discover every test, isolate app suites, and require final summaries.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const stripAnsi = value => value.replace(/\x1b\[[0-9;]*m/g, '');

export function discoverGroups(output) {
  const lines = stripAnsi(output).trim().split(/\r?\n/).filter(Boolean);
  if (!lines.length) throw new Error('Swift test discovery returned no tests.');
  const seen = new Set();
  const groups = new Map();
  for (const id of lines) {
    // SwiftPM lists XCTest methods without (), and Swift Testing functions with
    // a signature. Reject unknown output instead of silently dropping coverage.
    const match = /^([A-Za-z_][A-Za-z0-9_]*)\.([^\s]+)$/.exec(id);
    if (!match || !match[1].endsWith('Tests')) throw new Error(`Unrecognized discovered test: ${id}`);
    if (seen.has(id)) throw new Error(`Duplicate discovered test: ${id}`);
    seen.add(id);
    const [, module, testPath] = match;
    const swiftTesting = testPath.includes('(');
    const suiteOrFunction = testPath.split('/')[0].split('(')[0];
    const name = module === 'CrossToolAppTests' ? suiteOrFunction : module;
    // Use an unqualified token because SwiftPM and Swift Testing use different
    // qualified-name separators. Count checks below also detect overmatching.
    const filter = `(^|[./])${escapeRegex(name)}([./(]|$)`;
    const key = `${module}:${name}`;
    if (!groups.has(key)) groups.set(key, { name, module, filter, tests: [], xctest: 0, swiftTesting: 0 });
    const group = groups.get(key);
    group.tests.push(id);
    group[swiftTesting ? 'swiftTesting' : 'xctest']++;
  }
  const result = [...groups.values()];
  for (const group of result) {
    const matched = [...seen].filter(id => new RegExp(group.filter).test(id));
    if (matched.length !== group.tests.length) {
      throw new Error(`Ambiguous filter for ${group.name}; split or qualify this group before running.`);
    }
  }
  return result.sort((a, b) => {
    if (a.module === 'CrossToolCoreTests' && b.module !== a.module) return -1;
    if (b.module === 'CrossToolCoreTests' && a.module !== b.module) return 1;
    return a.name.localeCompare(b.name, 'en');
  });
}

export function verifyGroupResult(group, result) {
  if (result.timedOut) throw new Error(`${group.name}: test command timed out.`);
  if (result.signal || result.code !== 0) {
    throw new Error(`${group.name}: command failed (${result.signal ?? result.code}).`);
  }
  const output = stripAnsi(result.output);
  const swiftSummaries = [...output.matchAll(/Test run with (\d+) tests?(?: in \d+ suites?)? passed after [\d.]+ seconds\./g)];
  const xctestSummaries = [...output.matchAll(/Test Suite 'Selected tests' passed at[^\n]*\n\s*Executed (\d+) tests?, with 0 failures? \(0 unexpected\)/g)];
  // Swift Testing emits exactly one final summary. Depending on which bundle
  // the filter selects, SwiftPM can emit no XCTest summary or one summary per
  // linked test bundle (including zero-test summaries). Verify their combined
  // count instead of relying on one fixed output shape.
  if (swiftSummaries.length !== 1) {
    throw new Error(`${group.name}: missing or duplicate final test summary (possible early exit).`);
  }
  const actual = {
    swiftTesting: Number(swiftSummaries[0][1]),
    xctest: xctestSummaries.reduce(
      (sum, summary) => sum + Number(summary[1]),
      0,
    ),
  };
  if (actual.swiftTesting !== group.swiftTesting || actual.xctest !== group.xctest) {
    throw new Error(`${group.name}: expected XCTest ${group.xctest} + Swift Testing ${group.swiftTesting}, got ${actual.xctest} + ${actual.swiftTesting}.`);
  }
  // Successful final counts cannot override an earlier failed run or skipped
  // cases. New intentional skips need an explicit policy instead of a green CI.
  if (/Test run with [^\n]* failed|Test Suite '[^\n]* failed at|Test Case '[^\n]* failed|(?:✘|✗) |\btest(?:s)? skipped\b|\bTest [^\n]*\bskipped(?: after|:|\.)/i.test(output)) {
    throw new Error(`${group.name}: failure or skipped test found in output.`);
  }
  return actual;
}

export async function runCommand(command, args, { cwd, timeoutMs, logPath, echo = true }) {
  let output = '';
  let stdout = '';
  let timedOut = false;
  let forceKill;
  const child = spawn(command, args, {
    cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, NO_COLOR: '1', TERM: 'dumb', LC_ALL: 'en_US.UTF-8' },
  });
  const killGroup = signal => {
    if (!child.pid) return;
    try { process.kill(-child.pid, signal); } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
  };
  const cancel = () => {
    if (timedOut) return;
    timedOut = true;
    killGroup('SIGTERM');
    forceKill = setTimeout(() => killGroup('SIGKILL'), 3000);
  };
  process.once('SIGINT', cancel);
  process.once('SIGTERM', cancel);
  const timer = setTimeout(cancel, timeoutMs);
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; output += chunk; if (echo) process.stdout.write(chunk); });
  child.stderr.on('data', chunk => { output += chunk; if (echo) process.stderr.write(chunk); });
  try {
    const status = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code, signal) => resolve({ code, signal }));
    });
    await writeFile(logPath, `$ ${command} ${args.map(value => JSON.stringify(value)).join(' ')}\n${output}`, 'utf8');
    return { ...status, output, stdout, timedOut };
  } finally {
    clearTimeout(timer);
    clearTimeout(forceKill);
    process.removeListener('SIGINT', cancel);
    process.removeListener('SIGTERM', cancel);
  }
}

export async function main() {
  if (process.argv.length > 2) throw new Error('Usage: scripts/test-macos.sh (no filters: always verifies the complete discovered suite)');
  if (process.platform !== 'darwin') throw new Error('The macOS product tests require macOS with Xcode 26 or later (macOS 26 SDK); the app deployment target remains macOS 14.');
  await mkdir(path.join(projectDir, '.build'), { recursive: true });
  const logDir = await mkdtemp(path.join(projectDir, '.build', 'macos-regression-'));
  const report = { startedAt: new Date().toISOString(), status: 'running', discoveredTests: 0, passedTests: 0, groups: [] };
  const saveReport = () => writeFile(path.join(logDir, 'summary.json'), `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(`macOS regression logs: ${logDir}`);
  try {
    const discovered = await runCommand('swift', ['test', 'list'], {
      cwd: projectDir, timeoutMs: 10 * 60 * 1000, logPath: path.join(logDir, 'discovery.log'), echo: false,
    });
    if (discovered.code !== 0 || discovered.signal || discovered.timedOut) {
      throw new Error(`Test build/discovery failed. See ${path.join(logDir, 'discovery.log')}`);
    }
    const groups = discoverGroups(discovered.stdout);
    report.discoveredTests = groups.reduce((sum, group) => sum + group.tests.length, 0);
    report.groups = groups.map(group => ({ ...group, status: 'pending' }));
    await saveReport();
    console.log(`Discovered ${report.discoveredTests} tests in ${groups.length} isolated groups.`);
    for (const [index, group] of groups.entries()) {
      const logName = `${String(index + 1).padStart(2, '0')}-${group.name}.log`;
      const entry = report.groups[index];
      entry.status = 'running';
      entry.log = logName;
      await saveReport();
      console.log(`\n[${index + 1}/${groups.length}] ${group.name}: expecting ${group.tests.length} tests`);
      const result = await runCommand('swift', ['test', '--skip-build', '--filter', group.filter], {
        cwd: projectDir, timeoutMs: 3 * 60 * 1000, logPath: path.join(logDir, logName),
      });
      entry.exitCode = result.code;
      entry.signal = result.signal;
      entry.actual = verifyGroupResult(group, result);
      entry.status = 'passed';
      report.passedTests += group.tests.length;
      await saveReport();
    }
    report.status = 'passed';
    console.log(`\nPASS ${report.passedTests}/${report.discoveredTests} tests across ${groups.length} isolated groups.`);
  } catch (error) {
    report.status = 'failed';
    report.error = error.message;
    for (const group of report.groups) if (group.status === 'running') group.status = 'failed';
    throw error;
  } finally {
    report.finishedAt = new Date().toISOString();
    await saveReport();
    console.log(`Evidence: ${path.join(logDir, 'summary.json')}`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`FAIL: ${error.message}`); process.exitCode = 1; });
}
