# Migrating an Nx Monorepo to aeb

This guide covers converting an Nx workspace (Angular, React, or polyglot) to aeb, based on the nx-examples migration (17 Nx project.json files → 13 `.build.ae` + 9 `.tests.ae` + 2 `.dist.ae` files).

## Overview

aeb replaces Nx's project graph, task orchestration, and build caching with its own directory-scanning DAG, builder-closure DSL, and timestamp-based incremental builds. npm packages are managed via pnpm's content-addressed store instead of yarn/npm.

## Prerequisites

```bash
# Install aeb and initialize
cd your-nx-workspace
/path/to/aeb/aeb --init

# Required tools
node --version       # Node.js (match your project's version)
pnpm --version       # pnpm (for npm dep resolution)
```

## Step 1: Extract the Dependency Graph from Nx

**Do this first.** Nx already knows the exact module dependency graph.

```bash
# Install deps to get nx working
yarn install   # or npm install

# Export the dependency graph
npx nx graph --file=deps.json

# List all projects
npx nx show projects
```

Parse the graph to understand inter-module deps:

```python
import json
with open('deps.json') as f:
    data = json.load(f)
for name, deps in data['graph']['dependencies'].items():
    internal = [d['target'] for d in deps if not d['target'].startswith('npm:')]
    print(f"{name}: {internal}")
```

Also scan source files for import patterns:
```bash
grep -rh "@your-scope" libs/ apps/ | grep "from '" | sed "s/.*from '//;s/'.*//" | sort -u
```

## Step 2: Categorize Modules by Framework

Each module uses a different compilation tool:

| Framework | Compiler | aeb builder |
|-----------|----------|-------------|
| Plain TypeScript | `tsc` | `ts.tsc_project(b)` |
| Angular | `ngc` | `angular.ngc_project(b)` |
| React (TSX) | `tsc` | `ts.tsc_project(b)` |
| Web Components | `tsc` | `ts.tsc_project(b)` |

Detect framework per module:
```bash
for lib in $(find libs -name "tsconfig.lib.json" | sed 's|/tsconfig.lib.json||'); do
    if grep -rq "@angular" "$lib/src" 2>/dev/null; then echo "$lib: angular"
    elif find "$lib/src" -name "*.tsx" | head -1 | grep -q .; then echo "$lib: react"
    else echo "$lib: plain-ts"
    fi
done
```

## Step 3: Set Up npm Dependencies via pnpm

Instead of a root `package.json` + `yarn install`, aeb uses pnpm to install build-time npm packages into `.aeb/node_modules/`.

### Create shared deps files

One per framework stack, at the project root:

```aether
// angular.deps.ae
import build
import build (dep)

aeb(cap) {
    b = build.deps()
    dep(b, "npm:typescript:5.9.2")
    dep(b, "npm:tslib:2.8.1")
    dep(b, "npm:rxjs:7.8.2")
    dep(b, "npm:@angular/core:21.2.0")
    dep(b, "npm:@angular/common:21.2.0")
    dep(b, "npm:@angular/compiler:21.2.0")
    dep(b, "npm:@angular/compiler-cli:21.2.0")
    // ... other Angular deps
}
```

```aether
// react.deps.ae
import build
import build (dep)

aeb(cap) {
    b = build.deps()
    dep(b, "npm:typescript:5.9.2")
    dep(b, "npm:react:18.3.1")
    dep(b, "npm:react-dom:18.3.1")
    dep(b, "npm:@types/react:18.3.1")
    // ... other React deps
}
```

The `npm:` prefix tells aeb to resolve via pnpm. Versions are pinned — no semver ranges.

### How resolution works

When a module's build runs, `_resolve_npm_deps()` collects all `npm:` deps and runs:
```bash
COREPACK_ENABLE_STRICT=0 pnpm add --prefix .aeb/ @angular/core@21.2.0 typescript@5.9.2 ...
```

The `.aeb/` directory gets:
- `node_modules/` — hoisted flat layout (via `.aeb/.npmrc` with `node-linker=hoisted`)
- `package.json` — auto-generated (gitignored)
- `pnpm-lock.yaml` — auto-generated (gitignored)

A symlink `node_modules → .aeb/node_modules` at the repo root lets TypeScript's module resolution find the packages.

### For Angular projects (21+)

Angular 21+ uses Ivy natively — no `ngcc` step needed. For Angular 11-16, run `ngcc` after pnpm install:
```bash
.aeb/node_modules/.bin/ngcc --properties es2015 browser module main
```

## Step 4: Create .build.ae Files

### Library modules

```aether
// libs/shared/product/types/.build.ae
import build
import build (dep, load_third_party_deps)
import ts
import ts (skip_lib_check)

aeb(cap) {
    b = build.start()
    load_third_party_deps(b, "../../../../base.deps.ae")
    ts.tsc_project(b) {
        skip_lib_check()
    }
}
```

For modules with inter-module deps:
```aether
// libs/shared/product/state/.build.ae  (Angular)
import build
import build (dep, load_third_party_deps)
import angular
import angular (skip_lib_check)

aeb(cap) {
    b = build.start()
    load_third_party_deps(b, "../../../../angular.deps.ae")
    dep(b, "libs/shared/product/data")
    dep(b, "libs/shared/product/types")
    angular.ngc_project(b) {
        skip_lib_check()
    }
}
```

### App modules

Apps use `tsconfig.app.json` instead of `tsconfig.lib.json`:
```aether
// apps/products/.build.ae
import build
import build (dep, load_third_party_deps)
import angular
import angular (skip_lib_check, tsconfig)

aeb(cap) {
    b = build.start()
    load_third_party_deps(b, "../../angular.deps.ae")
    dep(b, "libs/products/home-page")
    dep(b, "libs/products/product-detail-page")
    angular.ngc_project(b) {
        tsconfig("tsconfig.app.json")
        skip_lib_check()
    }
}
```

### Key patterns

**TypeScript path aliases** — the existing `tsconfig.base.json` handles inter-module resolution. No changes needed.

**`skip_lib_check()`** — always use this. It prevents type-checking errors from `node_modules` declarations.

**`tsconfig("tsconfig.app.json")`** — override the default `tsconfig.lib.json` for app modules.

**`dep(b, "libs/shared/product/types")`** — inter-module deps. These control build order (topo sort). TypeScript's path aliases handle the actual module resolution.

## Step 5: Create .tests.ae Files

```aether
// libs/shared/product/state/.tests.ae
import build
import build (dep, load_third_party_deps)
import jest

aeb(cap) {
    b = build.start()
    dep(b, "libs/shared/product/state")
    load_third_party_deps(b, "../../../../angular.deps.ae")
    jest.project(b)
}
```

### Jest preset

Replace `@nx/jest/preset` with a standalone preset that resolves `tsconfig.base.json` path aliases:

```javascript
// jest.preset.js (at repo root)
const path = require('path');
const repoRoot = __dirname;

module.exports = {
  testMatch: ['**/+(*.)+(spec|test).+(ts|js)?(x)'],
  transform: { '^.+\\.(ts|js|html)$': 'ts-jest' },
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'html'],
  testEnvironment: 'jsdom',
  moduleNameMapper: (() => {
    const tsconfig = require('./tsconfig.base.json');
    const paths = tsconfig.compilerOptions.paths || {};
    const mapper = {};
    for (const [alias, targets] of Object.entries(paths)) {
      mapper['^' + alias.replace(/\*/g, '(.*)') + '$'] =
        path.join(repoRoot, targets[0].replace(/\*/g, '$1'));
    }
    return mapper;
  })(),
};
```

### Test dependencies

Install Jest and test frameworks into `.aeb/node_modules/`:
```bash
cd .aeb && COREPACK_ENABLE_STRICT=0 pnpm add \
    jest ts-jest jest-preset-angular jest-environment-jsdom \
    @types/jest @types/node document-register-element
```

## Step 6: Create .dist.ae Files (App Bundling)

### React apps (webpack)

Create a standalone webpack config that doesn't depend on `@nx/webpack`:

```javascript
// apps/cart/webpack.aeb.config.js
const path = require('path');
const HtmlWebpackPlugin = require('html-webpack-plugin');

module.exports = {
  mode: 'production',
  entry: path.resolve(__dirname, 'src/main.tsx'),
  output: { path: path.resolve(__dirname, '../../dist/apps/cart'), clean: true },
  resolve: {
    extensions: ['.tsx', '.ts', '.js'],
    alias: (() => {
      const tsconfig = require('../../tsconfig.base.json');
      // Build aliases from tsconfig paths...
    })(),
  },
  module: {
    rules: [
      { test: /\.tsx?$/, use: { loader: 'ts-loader', options: { transpileOnly: true } } },
      { test: /\.css$/, use: ['style-loader', 'css-loader'] },
      { test: /\.scss$/, use: ['style-loader', 'css-loader', 'sass-loader'] },
    ],
  },
  plugins: [new HtmlWebpackPlugin({ template: 'src/index.html' })],
};
```

```aether
// apps/cart/.dist.ae
import build
import build (dep, load_third_party_deps)
import webpack

aeb(cap) {
    b = build.start()
    dep(b, "apps/cart")
    load_third_party_deps(b, "../../react.deps.ae")
    webpack.bundle(b)
}
```

### Angular apps (ng build)

Create a minimal `angular.json` at the repo root with the app's build config:

```json
{
  "version": 1,
  "projects": {
    "products": {
      "root": "apps/products",
      "architect": {
        "build": {
          "builder": "@angular-devkit/build-angular:browser",
          "options": { "main": "apps/products/src/main.ts", ... }
        }
      }
    }
  }
}
```

```aether
// apps/products/.dist.ae
import build
import build (dep, load_third_party_deps)
import angular

aeb(cap) {
    b = build.start()
    dep(b, "apps/products")
    load_third_party_deps(b, "../../angular.deps.ae")
    angular.ng_build(b)
}
```

## Step 7: Remove Nx Config

Once all modules compile, tests pass, and apps bundle:

```bash
# Remove Nx config
find . -name "project.json" -not -path "*/node_modules/*" -delete
rm -f nx.json deps.json
rm -rf .nx/

# Remove Nx references from eslintrc files
# (or replace @nx/eslint-plugin with standard eslint rules)

# Remove Nx webpack configs (replaced by standalone configs)
rm apps/*/webpack.config.js

# Fix tsconfig references to @nx/react typings
# Create local typings/ directory with the .d.ts files
```

## Step 8: Verify

```bash
# Full build + test + bundle
aeb

# Build specific module
aeb libs/shared/product/state

# Bundle specific app
aeb --dist apps/cart
```

## After Migration

A few aeb features pay off once the migration is in place. See the
README for the canonical reference; brief pointers:

- **Verify the dep graph visually.** `aeb --graph | dot -Tsvg > deps.svg`
  emits the full DAG. After translating an Nx workspace this is the
  fastest way to confirm the project graph matches what
  `nx graph` used to show. `aeb --graph mermaid` for inline-Markdown.
- **Use `aeb --since` in CI.** Equivalent to Nx's `nx affected`:
  `aeb --since main` builds and tests only modules downstream of the
  PR's changed files. Combined with aeb's content-addressed cache,
  this is the standard CI shape.
- **Narrow PR checks to tests with `--scan '.tests.ae'`.** Nx has
  `nx affected:test` (only the test target type). aeb's equivalent is
  `aeb --since main --scan '.tests.ae'` — runs only the test
  targets impacted by the PR, skipping `.build.ae` rebuild rows and
  `.dist.ae` packagers. `--scan '.dist.ae'` is the symmetric
  release-pipeline shape.
- **Composite test targets via `build.scan()`.** Equivalent to Nx
  project tags + `nx run-many --target=test`. Commit a `.all-tests.ae`
  once and your CI command stays `aeb .all-tests.ae --since main`
  forever:

  ```aether
  // .all-tests.ae at the workspace root
  import build
  aeb(cap) {
      b = build.start()
      build.scan(b, "**/.tests.ae")
  }
  ```

  Every `.tests.ae` in the tree is automatically picked up at
  build-graph extraction time. New apps/libs join the test set the
  moment their `.tests.ae` lands; no CI config change needed.
- **Cache and telemetry are auto-on.** Each `aeb` run prints a
  `[telemetry]` block at the end with per-module wall-time and
  `[hit]`/`[miss]` cache outcomes. Useful for spotting which modules
  are slow during incremental development.

## Available Builders

| Builder | Purpose | DSL |
|---------|---------|-----|
| `ts.tsc_project(b)` | TypeScript/React compilation | `tsconfig()`, `skip_lib_check()` |
| `angular.ngc_project(b)` | Angular compilation | `tsconfig()`, `skip_lib_check()` |
| `jest.project(b)` | Jest test execution | `timeout()` |
| `webpack.bundle(b)` | React app bundling | `webpack_config()` |
| `angular.ng_build(b)` | Angular app bundling | (uses angular.json) |

## What Doesn't Migrate Automatically

| Nx feature | aeb equivalent |
|-----------|---------------|
| Nx Cloud caching | Content-addressed cache (`lib/cache`, sha256+zlib) wired into several SDKs; mtime-only for the rest. Remote/distributed cache is designed (`distributed-cache-plan.md`). |
| `nx affected` | **`aeb --since <ref>` / `--print-affected`** — builds/tests only modules downstream of a diff (see the `--since` guidance earlier in this doc). |
| Nx generators | Manual (or write Aether scripts) |
| Cypress e2e | Run `cypress` directly (not yet integrated into aeb) |
| Nx plugins | Replace with standalone tooling |
| `nx serve` | Run `webpack serve` or `ng serve` directly |

## Appendix: Directory Structure After Migration

```
your-project/
├── .aeb/                    # aeb workspace (gitignored)
│   ├── lib/ → aeb SDKs
│   ├── node_modules/        # pnpm-managed npm packages
│   ├── package.json         # auto-generated
│   └── .npmrc               # node-linker=hoisted
├── angular.json             # minimal Angular CLI config (for ng build)
├── jest.preset.js           # standalone Jest preset
├── tsconfig.base.json       # path aliases (kept from Nx)
├── typings/                 # local .d.ts files (replaces @nx/react/typings)
├── base.deps.ae             # shared npm deps (TypeScript)
├── angular.deps.ae          # Angular npm deps
├── react.deps.ae            # React npm deps
├── apps/
│   ├── cart/
│   │   ├── .build.ae        # compile (tsc)
│   │   ├── .tests.ae        # test (jest)
│   │   ├── .dist.ae         # bundle (webpack)
│   │   └── webpack.aeb.config.js
│   └── products/
│       ├── .build.ae        # compile (ngc)
│       ├── .tests.ae        # test (jest)
│       └── .dist.ae         # bundle (ng build)
└── libs/
    └── shared/product/types/
        ├── .build.ae        # compile (tsc)
        └── src/
```
