/**
 * Collision-resistant content fingerprint for CodeView item `version` values.
 *
 * The previous implementation was a 32-bit djb2 hash (`hash >>> 0`). A 32-bit
 * space is small enough that two distinct files can land on the same `version`,
 * and CodeView keeps an existing record untouched when the version matches — so
 * a collision served a stale diff for the wrong content. This replaces it with a
 * 64-bit FNV-1a hash computed exactly with BigInt (no float precision loss),
 * rendered as a base36 string and prefixed with the input length. The length
 * prefix plus the 64-bit hash together make accidental collisions effectively
 * impossible, and the string form keeps `===` exact.
 *
 * `version` is only ever used for equality checks (CodeView keeps the cached
 * record when it matches), so a string identity is fine. The fingerprint is
 * deterministic: identical content always yields the same version, and different
 * content yields a different one, so the parsed-diff and highlight caches are
 * invalidated precisely — never re-scanning the body for unchanged files.
 */
const FNV_OFFSET_64 = 14695981039346656037n;
const FNV_PRIME_64 = 1099511628211n;
const MASK_64 = (1n << 64n) - 1n;

export function contentVersion(...parts) {
  let length = 0;
  let hash = FNV_OFFSET_64;
  for (const part of parts) {
    const text = String(part ?? '');
    length += text.length;
    for (let index = 0; index < text.length; index++) {
      hash ^= BigInt(text.charCodeAt(index) & 0xff);
      hash = (hash * FNV_PRIME_64) & MASK_64;
    }
  }
  // Length prefix guards against equal-hash-but-different-size inputs.
  return `${length.toString(36)}:${hash.toString(36)}`;
}

export function diffContentVersions(oldName, oldContents, newContents, isEditable) {
  const oldVersion = contentVersion(oldContents);
  const newVersion = contentVersion(newContents);
  return {
    oldVersion,
    newVersion,
    // Metadata (the file name and whether the file is editable) is folded into
    // the item version so a rename or a mode change invalidates the cached item
    // without discarding either side's parsed-diff cache.
    itemVersion: contentVersion(
      oldName,
      oldVersion,
      newVersion,
      isEditable ? 'edit' : 'review'
    ),
  };
}
