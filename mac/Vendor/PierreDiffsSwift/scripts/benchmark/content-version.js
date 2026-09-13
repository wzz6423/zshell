import { performance } from 'node:perf_hooks';

import { contentVersion, diffContentVersions } from '../src/content-version.js';

const iterations = Number(process.argv[2] || 40);
const sizesMiB = process.argv.slice(3).map(Number).filter(Number.isFinite);
if (sizesMiB.length === 0) sizesMiB.push(1, 5);

function mixString(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index++) {
    hash = (Math.imul(hash, 31) + value.charCodeAt(index)) | 0;
  }
  return hash;
}

function currentVersions(oldName, oldContents, newContents, isEditable) {
  return {
    oldVersion: contentVersion(oldContents),
    newVersion: contentVersion(newContents),
    itemVersion: contentVersion(
      oldName,
      oldContents,
      newContents,
      isEditable ? 'edit' : 'review'
    ),
  };
}

function makeContents(sizeMiB, seed) {
  const line = `const value${seed} = "${'x'.repeat(96)}";\n`;
  return line.repeat(Math.ceil(sizeMiB * 1024 * 1024 / line.length))
    .slice(0, sizeMiB * 1024 * 1024);
}

function measure(name, operation) {
  const samples = [];
  let sink = 0;
  for (let index = 0; index < iterations; index++) {
    const start = performance.now();
    const result = operation();
    samples.push(performance.now() - start);
    sink = (sink + mixString(result.itemVersion)) | 0;
  }
  samples.sort((left, right) => left - right);
  const median = samples[Math.floor(samples.length / 2)];
  const p95 = samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.95))];
  console.log(`${name}\tmedian=${median.toFixed(3)}ms\tp95=${p95.toFixed(3)}ms\tsink=${sink}`);
}

for (const sizeMiB of sizesMiB) {
  const oldName = 'Sources/Large.swift';
  const oldContents = makeContents(sizeMiB, 1);
  const newContents = makeContents(sizeMiB, 2);
  const args = [oldName, oldContents, newContents, false];
  for (let index = 0; index < 4; index++) {
    currentVersions(...args);
    diffContentVersions(...args);
  }
  console.log(`contents=${sizeMiB}MiB/side iterations=${iterations}`);
  measure('current', () => currentVersions(...args));
  measure('single-pass', () => diffContentVersions(...args));
}
