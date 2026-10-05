#!/usr/bin/env node
/**
 * Stages one `@signet/cli-<platform>` npm package for release: copies the
 * freshly built binaries (the Go `signet` CLI and the Rust `signet-simulator`)
 * into its `bin/` directory side by side and pins the package's own `version`
 * field.
 *
 * Usage:
 *   node scripts/release/stage-platform-package.mjs <package-dir> <version> <source>=<name> [<source>=<name> ...]
 *
 * Each binary is `<source path>=<name in bin/>`: the build step disambiguates
 * its outputs per-target with a prefix, but the published package must hold
 * them under their real names (`signet[.exe]`, `signet-simulator[.exe]`) —
 * cli/npm/cli/bin/signet.js's shim looks for those, and signet looks for the
 * simulator next to itself.
 *
 * Example (from the repo root):
 *   node scripts/release/stage-platform-package.mjs cli/npm/cli-linux-x64 0.1.0 \
 *     cli/dist/cli-linux-x64-signet=signet \
 *     cli/dist/cli-linux-x64-signet-simulator=signet-simulator
 */
import { chmodSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const [, , packageDir, version, ...binaries] = process.argv;

if (!packageDir || !version || binaries.length === 0) {
  console.error(
    'usage: stage-platform-package.mjs <package-dir> <version> <source>=<name> [<source>=<name> ...]',
  );
  process.exit(1);
}

const binDir = path.join(packageDir, 'bin');
mkdirSync(binDir, { recursive: true });

for (const spec of binaries) {
  const sep = spec.lastIndexOf('=');
  const source = sep > 0 ? spec.slice(0, sep) : '';
  const name = sep > 0 ? spec.slice(sep + 1) : '';
  if (!source || !name || name !== path.basename(name)) {
    console.error(`bad binary spec "${spec}": expected <source>=<file name>`);
    process.exit(1);
  }
  const dest = path.join(binDir, name);
  copyFileSync(source, dest);
  chmodSync(dest, 0o755); // no-op on Windows; required for the binary to exec on Linux/macOS
  console.log(`Staged ${dest}`);
}

const pkgPath = path.join(packageDir, 'package.json');
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
pkg.version = version;
writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);

console.log(`Staged ${binaries.length} binaries into ${pkg.name}@${version}`);
