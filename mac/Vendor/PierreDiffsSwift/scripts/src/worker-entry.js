/**
 * Highlight worker entry point.
 *
 * Bundled separately from `diff-entry.js` and inlined into the main bundle as
 * a string (see `bundle.js`), so the bridge can start workers from a blob URL.
 * Pages loaded with `loadHTMLString(baseURL: nil)` have a null origin and no
 * URL to load a worker script from, but blob workers do run there.
 *
 * `worker-portable` is the upstream build that carries its own Shiki engine
 * instead of fetching WASM at runtime.
 */
import '@pierre/diffs/worker/worker-portable.js';
