import assert from 'node:assert/strict';
import test from 'node:test';

import { contentVersion, diffContentVersions } from '../src/content-version.js';

const base = {
  oldName: 'Sources/Example.swift',
  oldContents: 'let value = 1\n',
  newContents: 'let value = 2\n',
  isEditable: false,
};

function versions(overrides = {}) {
  const input = { ...base, ...overrides };
  return diffContentVersions(
    input.oldName,
    input.oldContents,
    input.newContents,
    input.isEditable
  );
}

test('content changes invalidate the matching side and item', () => {
  const initial = versions();
  const oldChanged = versions({ oldContents: 'let value = 0\n' });
  const newChanged = versions({ newContents: 'let value = 3\n' });

  assert.notEqual(oldChanged.oldVersion, initial.oldVersion);
  assert.equal(oldChanged.newVersion, initial.newVersion);
  assert.notEqual(oldChanged.itemVersion, initial.itemVersion);
  assert.equal(newChanged.oldVersion, initial.oldVersion);
  assert.notEqual(newChanged.newVersion, initial.newVersion);
  assert.notEqual(newChanged.itemVersion, initial.itemVersion);
});

test('metadata changes invalidate the item without discarding side caches', () => {
  const initial = versions();
  for (const changed of [
    versions({ oldName: 'Sources/Renamed.swift' }),
    versions({ isEditable: true }),
  ]) {
    assert.equal(changed.oldVersion, initial.oldVersion);
    assert.equal(changed.newVersion, initial.newVersion);
    assert.notEqual(changed.itemVersion, initial.itemVersion);
  }
});

test('each side content is fingerprinted once', () => {
  let oldCoercions = 0;
  let newCoercions = 0;
  const oldContents = { toString() { oldCoercions += 1; return base.oldContents; } };
  const newContents = { toString() { newCoercions += 1; return base.newContents; } };

  diffContentVersions(base.oldName, oldContents, newContents, false);

  assert.equal(oldCoercions, 1);
  assert.equal(newCoercions, 1);
});

test('distinct contents never collide (replaces the 32-bit hash)', () => {
  // The previous 32-bit djb2 hash (`hash >>> 0`) could map two different files
  // onto the same `version`, serving a stale diff. The fingerprint must now be
  // a length-prefixed string and stay collision-free across distinct inputs.
  const samples = new Set();
  for (let index = 0; index < 20000; index++) {
    const contents = `sample-${index}-${Math.random().toString(36).slice(2)}`;
    const version = contentVersion(contents);
    assert.equal(typeof version, 'string');
    assert.match(version, /^[0-9a-z]+:[0-9a-z]+$/);
    assert.equal(contentVersion(contents), version);
    const before = samples.size;
    samples.add(version);
    assert.equal(samples.size, before + 1);
  }
});
