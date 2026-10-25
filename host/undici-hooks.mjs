/**
 * ESM resolve hook: map the bare `undici` specifier onto the jitless shim.
 *
 * Registered from `bootstrap.cjs` via `module.register()` before dsh is
 * imported. Only `undici` is rewritten; every other specifier delegates to
 * Node's default resolver.
 */

export async function resolve(specifier, context, nextResolve) {
  if (specifier === 'undici') {
    return {
      url: new URL('./undici-esm.mjs', import.meta.url).href,
      shortCircuit: true
    }
  }
  return nextResolve(specifier, context)
}
