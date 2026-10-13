import assert from 'node:assert/strict';
import test from 'node:test';
import { discoverGroups, verifyGroupResult } from './test-macos.mjs';

const listing = [
  'CrossToolCoreTests.ColorTests/testRed',
  'CrossToolCoreTests.ColorTests/green()',
  'CrossToolCoreTests.httpFlow()',
  'CrossToolAppTests.WindowTests/first()',
  'CrossToolAppTests.WindowTests/second()',
  'CrossToolAppTests.translation()',
].join('\n');
const summary = (count, suites = '') => `✔ Test run with ${count} tests${suites} passed after 0.101 seconds.\n`;
const xctestSummary = count => `Test Suite 'Selected tests' passed at 2026-09-09 00:00:00.000.\n\t Executed ${count} tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n`;
const result = output => ({ code: 0, signal: null, timedOut: false, output });

test('discovers Core module, individual app suites and standalone functions dynamically', () => {
  const groups = discoverGroups(listing);
  assert.equal(groups.length, 3);
  assert.equal(groups.reduce((sum, group) => sum + group.tests.length, 0), 6);
  assert.equal(groups[0].name, 'CrossToolCoreTests');
  assert.equal(groups[0].xctest, 1);
  assert.equal(groups[0].swiftTesting, 2);
  for (const group of groups) {
    assert.equal(listing.split('\n').filter(id => new RegExp(group.filter).test(id)).length, group.tests.length);
  }
});

for (const [name, value] of [
  ['empty discovery', ''], ['invalid output', 'Build complete!'],
  ['duplicate test', `${listing}\nCrossToolCoreTests.httpFlow()`],
  ['ambiguous suite filter', `${listing}\nCrossToolCoreTests.WindowTests/third()`],
]) test(`rejects ${name}`, () => assert.throws(() => discoverGroups(value)));

test('counts XCTest once and requires the independent Swift Testing summary', () => {
  const group = discoverGroups(listing)[0];
  assert.deepEqual(verifyGroupResult(group, result(
    "Test Suite 'ColorTests' passed at date\n Executed 1 test, with 0 failures (0 unexpected)\n" +
    xctestSummary(1) + summary(2, ' in 1 suite'),
  )), { xctest: 1, swiftTesting: 2 });
});

test('sums XCTest summaries from selected and empty linked test bundles', () => {
  const group = discoverGroups(listing)[0];
  assert.deepEqual(verifyGroupResult(group, result(
    xctestSummary(1) + xctestSummary(0) + summary(2),
  )), { xctest: 1, swiftTesting: 2 });
});

test('accepts Swift Testing-only group with the XCTest zero summary', () => {
  const group = discoverGroups(listing).find(group => group.name === 'WindowTests');
  assert.deepEqual(verifyGroupResult(group, result(xctestSummary(0) + summary(2))), { xctest: 0, swiftTesting: 2 });
});

test('accepts Swift Testing-only group when SwiftPM omits XCTest output', () => {
  const group = discoverGroups(listing).find(group => group.name === 'WindowTests');
  assert.deepEqual(verifyGroupResult(group, result(summary(2))), { xctest: 0, swiftTesting: 2 });
});

for (const [name, output] of [
  ['exit zero before final summary', xctestSummary(1) + '◇ Test httpFlow() started.'],
  ['missing XCTest summary', summary(2)],
  ['zero matches', xctestSummary(0) + summary(0)],
  ['partial matches', xctestSummary(1) + summary(1)],
  ['overmatching', xctestSummary(1) + summary(3)],
  ['wrong framework balance', xctestSummary(2) + summary(1)],
  ['duplicated run', xctestSummary(1) + summary(2) + summary(2)],
  ['earlier failure', '✘ Test foo() failed after 0.1 seconds.\n' + xctestSummary(1) + summary(2)],
  ['skipped test', '✔ Test foo() skipped after 0.1 seconds.\n' + xctestSummary(1) + summary(2)],
  ['skipped test with reason', '↷ Test foo() skipped: "Unavailable"\n' + xctestSummary(1) + summary(2)],
]) test(`rejects ${name}`, () => assert.throws(() => verifyGroupResult(discoverGroups(listing)[0], result(output))));

for (const [name, overrides] of [
  ['nonzero exit', { code: 1 }], ['signal', { code: null, signal: 'SIGSEGV' }], ['timeout', { timedOut: true }],
]) test(`rejects ${name} even with successful summaries`, () => assert.throws(() => verifyGroupResult(
  discoverGroups(listing)[0], { ...result(xctestSummary(1) + summary(2)), ...overrides },
)));
