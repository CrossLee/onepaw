import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

// Deliberately dependency-free contract checks, not a replacement for YAML or
// GitHub Actions syntax validation. Read the real workflow rather than copying
// its publication predicate or package-version implementation into fixtures.
const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 2 && args[0] === '--workflow-file'),
  'Usage: node test-windows-workflow.mjs [--workflow-file <fixture>]');
const workflowPath = args.length === 2 ? args[1] : new URL('../../.github/workflows/windows-ci.yml', import.meta.url);
// Git checks this file out with CRLF on Windows. Normalize once so every
// full-file assertion and every extracted block checks the same logical text.
const workflow = readFileSync(workflowPath, 'utf8').replace(/\r\n?/g, '\n');
const lines = workflow.split('\n');

function blockAfter(header, indentation) {
  const start = lines.indexOf(`${' '.repeat(indentation)}${header}`);
  assert.notEqual(start, -1, `Missing workflow block: ${header}`);
  let end = start + 1;
  while (end < lines.length) {
    const line = lines[end];
    if (line.trim() && !line.trimStart().startsWith('#') && line.search(/\S/) <= indentation) break;
    end += 1;
  }
  return lines.slice(start + 1, end).join('\n');
}

function step(name) {
  return blockAfter(`- name: ${name}`, 6);
}

function readPublishPredicate() {
  const publish = blockAfter('publish-preview:', 2);
  const match = publish.match(/    if: >-\n\s*\$\{\{([\s\S]*?)\}\}/);
  assert.ok(match, 'The publish job must have an explicit predicate.');
  const terms = match[1].trim().split(/\s*&&\s*/).map(term => {
    const parsed = term.match(/^([a-z0-9_.-]+) == ('[^']*'|true)$/);
    assert.ok(parsed, `Unreviewed publication predicate syntax: ${term}`);
    return { path: parsed[1], value: parsed[2] === 'true' ? true : parsed[2].slice(1, -1) };
  });
  assert.equal(terms.length, 5, 'Publication must require all five reviewed conditions.');
  return context => terms.every(({ path, value }) => {
    const actual = path.split('.').reduce((entry, key) => entry?.[key], context);
    return actual === value;
  });
}

test('push and pull requests cover Windows, shared web assets, icons, and workflow changes', () => {
  for (const event of ['push:', 'pull_request:']) {
    const trigger = blockAfter(event, 2);
    for (const path of ['windows/**', 'Sources/CrossToolApp/Resources/Web/**',
      'Resources/Brand/OnePaw-AppIcon.png', '.github/workflows/windows-ci.yml']) {
      assert.ok(trigger.includes(`- "${path}"`), `${event} does not cover ${path}`);
    }
  }
});

test('manual publication is a typed, optional, default-false input', () => {
  const input = blockAfter('publish_preview:', 6);
  assert.match(input, /^        type: boolean$/m);
  assert.match(input, /^        required: false$/m);
  assert.match(input, /^        default: false$/m);
  assert.ok(blockAfter('workflow_dispatch:', 2).includes('publish_preview:'));
});

test('only explicitly requested main publication with both validations successful is allowed', () => {
  const permits = readPublishPredicate();
  let combinations = 0;
  let allowed = 0;
  for (const event of ['push', 'pull_request', 'workflow_dispatch', 'workflow_run', 'release']) {
    for (const ref of ['refs/heads/main', 'refs/heads/codex/windows-native-preview',
      'refs/heads/feature/test', 'refs/pull/1/merge', 'refs/tags/v0.6.6']) {
      for (const publish of [undefined, false, true]) {
        for (const verify of ['success', 'failure', 'cancelled', 'skipped']) {
          for (const install of ['success', 'failure', 'cancelled', 'skipped']) {
            const context = {
              github: { event_name: event, ref },
              inputs: { publish_preview: publish },
              needs: { 'verify-windows': { result: verify }, 'install-windows11-arm64': { result: install } },
            };
            const expected = event === 'workflow_dispatch' && ref === 'refs/heads/main' &&
              publish === true && verify === 'success' && install === 'success';
            assert.equal(permits(context), expected, JSON.stringify(context));
            combinations += 1;
            if (expected) allowed += 1;
          }
        }
      }
    }
  }
  assert.equal(combinations, 1200);
  assert.equal(allowed, 1);
});

test('publication cannot depend on a magic commit message or the old platform branch', () => {
  const publish = blockAfter('publish-preview:', 2);
  assert.doesNotMatch(publish, /head_commit|startsWith\(|windows-native-preview/);
  assert.match(publish, /needs:\n      - verify-windows\n      - install-windows11-arm64/);
});

test('only the publication job gets repository write permission; no signing secrets are read', () => {
  assert.match(workflow, /^permissions:\n  contents: read$/m);
  assert.equal((workflow.match(/contents: write/g) ?? []).length, 1);
  assert.match(blockAfter('publish-preview:', 2), /permissions:\n      contents: write/);
  assert.doesNotMatch(workflow, /\$\{\{\s*secrets\.|CertificatePath|CertificatePassword|signing_certificate/);
});

test('the tested and published release artifacts have the same exact unsigned name', () => {
  const expected = 'name: 一爪-windows-${{ needs.verify-windows.outputs.package_version }}-unsigned-test';
  for (const name of ['Download the MSIX test bundle', "Download this run's unsigned release artifact"]) {
    const download = step(name);
    assert.ok(download.includes(expected));
    assert.doesNotMatch(download, /pattern:|merge-multiple:|run-id:|github-token:|repository:/);
  }
  assert.ok(step('Upload unsigned test MSIX packages')
    .includes('name: 一爪-windows-${{ steps.package_version.outputs.version }}-unsigned-test'));
});

test('release source and target remain pinned to the exact verified SHA', () => {
  const publish = blockAfter('publish-preview:', 2);
  assert.ok(publish.includes('RELEASE_TARGET_SHA: ${{ github.sha }}'));
  assert.ok(step('Checkout the exact verified commit').includes('ref: ${{ github.sha }}'));
  assert.ok(publish.includes('--target "$RELEASE_TARGET_SHA"'));
  assert.ok(publish.includes('.object.type == "commit" and .object.sha == $sha'));
});

test('exact source files, hashes, cloud byte comparison, and draft-first publication stay enforced', () => {
  const publish = blockAfter('publish-preview:', 2);
  assert.ok(publish.includes('setup_name="OnePaw-Windows-${version}-Setup.exe"'),
    'The public Setup asset must use the ASCII-safe OnePaw brand.');
  assert.doesNotMatch(publish, /setup_name="一爪-Windows-/,
    'A localized Setup asset prefix is not stable on GitHub Releases.');
  for (const contract of [
    'diff -u "$preview_root/expected-source-files.txt" "$preview_root/actual-source-files.txt"',
    'diff -u "$preview_root/expected-source-hashes.txt" "$preview_root/actual-source-hashes.txt"',
    'sha256sum --check --strict "$preview_root/source-SHA256SUMS.txt"',
    'cmp -- "$asset_dir/$setup_name" "$cloud_dir/download/$setup_name"',
    '.signed == false', '.artifactKind == "unsigned-test"', '--draft', '--draft=false',
  ]) assert.ok(publish.includes(contract), `Missing validation: ${contract}`);
  for (const [name, count] of [['expected_source_names', 9], ['expected_source_hash_names', 7]]) {
    const entries = publish.match(new RegExp(`${name}=\\(\\n([\\s\\S]*?)\\n          \\)`));
    assert.ok(entries, `Missing exact allowlist: ${name}`);
    assert.equal(entries[1].trim().split('\n').length, count);
  }
});

test('Windows releases remain prereleases and never replace the macOS latest release', () => {
  const publish = blockAfter('publish-preview:', 2);
  assert.ok(publish.includes('release_tag="windows-v${version}-preview"'));
  assert.equal((publish.match(/--latest=false/g) ?? []).length, 2);
  assert.equal((publish.match(/--prerelease/g) ?? []).length, 2);
});

test('the actual package-version implementation accepts bounds and fails closed without wrapping', () => {
  const versionStep = step('Choose package version');
  assert.match(versionStep, /shell: node \{0\}/);
  const script = versionStep.split('        run: |\n')[1]
    ?.split('\n').filter(line => line.startsWith('          ')).map(line => line.slice(10)).join('\n');
  assert.ok(script, 'Missing package version script.');
  for (const [input, expected] of [
    ['1', '0.1.1.0'], ['21', '0.1.21.0'], ['65535', '0.1.65535.0'],
    [undefined, null], ['', null], ['0', null], ['-1', null], ['01', null], ['1.2', null],
    [' 1', null], ['1 ', null], ['1e2', null], ['65536', null], ['131070', null],
    ['9007199254740992', null], ['99999999999999999999999999999999999', null],
  ]) {
    const writes = [];
    const run = () => runInNewContext(script, {
      process: { env: { GITHUB_RUN_NUMBER: input, GITHUB_OUTPUT: 'test-output' } },
      require(module) {
        assert.equal(module, 'node:fs');
        return { appendFileSync(path, text) { assert.equal(path, 'test-output'); writes.push(text); } };
      },
    }, { timeout: 1000 });
    if (expected === null) {
      assert.throws(run, /run number|MSIX build field/);
      assert.deepEqual(writes, [], `Invalid input ${input} must not emit a version.`);
    } else {
      run();
      assert.deepEqual(writes, [`version=${expected}\n`]);
    }
  }
});

test('workflow safety checks are part of every Windows verification run', () => {
  const safetyStep = step('Verify Windows workflow safety policy');
  for (const entry of [
    '.\\scripts\\test-windows-workflow.mjs',
    '.\\scripts\\test-windows-workflow-inputs.test.mjs',
    '.\\scripts\\test-window-acceptance-contract.mjs',
  ]) assert.ok(safetyStep.includes(entry), `Workflow safety step does not run ${entry}`);
});
