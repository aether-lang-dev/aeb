# Nx to aeb Migration — Dependency Status

> **Upstream is PINNED to `2cae706`** (see `../fetch-upstream.sh`). The
> `.build.ae` files here were authored against the layout before nx-examples
> #458, "migrate to TypeScript solution-style configs", which:
>
> - dropped the `tsconfig` `paths` aliases in favour of npm-workspace package
>   resolution — a `customConditions: ["@nx-example/source"]` entry plus a
>   per-lib `package.json` with an `exports` map;
> - deleted every `.babelrc` and `apps/cart/webpack.config.js`;
> - made `libs/shared/product/types` re-export a `./generated` module that an
>   `nx codegen` target produces from an OpenAPI document.
>
> Fetching HEAD instead replaced the subject of the test: 82 of the 88 recorded
> upstream files were gone and the build failed with `Cannot find module
> '@nx-example/shared-jsxify'` and `Cannot find module './generated'` — neither
> of which says anything about aeb.
>
> **Re-migrating to the current upstream is worth doing** and is the natural
> next piece of work here: it would exercise aeb against TS project references
> and workspace-package resolution, which nothing in itests/ covers today. It
> is a migration, not a fix, and the pin moves in the same commit.


After dropping nx as orchestrator, the dev team still needs:

## Known gap: the workspace dev-dependencies are not declared

Under Nx these arrive from one `pnpm install` of the root `package.json`.
Under aeb every npm package a node needs is declared in a `.deps.ae`, and the
migration declared only the runtime set (typescript, tslib, rxjs, react,
@emotion, @angular, @ngrx). Everything the *test* and *bundle* paths need was
missed, so those nodes fail on absence rather than on anything aeb did:

| node | fails with | needs |
|------|-----------|-------|
| every `.tests.ae` | `jest: No such file or directory` | `jest@30.3.0`, `ts-jest@29.2.4`, `jest-environment-jsdom@30.2.0`, `@types/jest@30.0.0`, and `@nx/jest@23.0.0-beta.18` for `jest.preset.js`'s `@nx/jest/preset` + `@nx/jest/plugins/resolver` |
| `apps/cart` | `Cannot find type definition file for '@nx/react/typings/cssmodule.d.ts'` | `@nx/react@23.0.0-beta.18` |
| `libs/shared/e2e-utils` | `Cannot find name 'cy'` | `cypress@15.15.0`, plus `typeRoots`/`types` plumbing — cypress ships its types at `node_modules/cypress/types`, not under `node_modules/@types`, which is where `tsconfig.base.json` points |

Versions are upstream's `package.json` at the pinned revision. Declaring the
`@nx/*` entries keeps the "lingering nx tentacles" this document describes
below; rewriting `jest.preset.js` to drop `@nx/jest` is the alternative, and
the better end state.

## Still invoked by aeb daily

- **TypeScript** (`tsc`) — `ts.tsc_project(b)` in `.build.ae` runs `tsc --project <tsconfig>` for each library and the React app. Resolves npm deps first via `pnpm.resolve()`, then invokes `node_modules/.bin/tsc`.

- **Angular compiler** (`ngc`) — `ts.ngc_project(b)` in `apps/products/.build.ae` runs `ngc --project <tsconfig>` instead of `tsc`. Same pattern as `tsc_project` but uses the Angular compiler binary for template compilation.

- **Webpack** — `ts.webpack_bundle(b)` in `apps/cart/.dist.ae` runs `node_modules/.bin/webpack --config webpack.aeb.config.js` to bundle the React app for production.

- **Angular CLI** (`ng`) — `ts.ng_build(b)` in `apps/products/.dist.ae` runs `ng build <app> --configuration production` for the Angular production bundle.

- **Jest** — `ts.jest_project(b)` in `.tests.ae` runs `node_modules/.bin/jest --config <jest.config.ts> --no-cache` per module. aeb handles the dependency graph so each module's tests run after its deps are built.

- **Babel** — not invoked directly by aeb, but Jest and Webpack use it under the hood for JSX transformation (configured via `.babelrc` and `babel.config.json`).

## Framework runtime (in the code itself)

- **Angular** + NgRx (products app)
- **React** + Emotion (cart app)
- **rxjs**, **zone.js**, **tslib**

## Still referenced but potentially droppable

- **`@nx/*` packages** — some are still imported in `jest.config.ts` and `cypress.config.ts` for preset helpers (`nxE2EPreset`, `@nx/jest`). These are the lingering nx tentacles — they'd need small rewrites to fully remove.
- **Cypress** — only for e2e tests, not daily builds

## Can remove entirely

- **`nx`** itself — the orchestrator being replaced
- **`@nx/devkit`**, **`@nx/workspace`** — if the jest/cypress configs are rewritten

TypeScript, Webpack, Jest, Angular CLI, Babel, and the framework packages (Angular, React, NgRx, Emotion) all stay. The `@nx/*` packages linger only because of config file imports that could be rewritten.

## Google-style DAG and sparse checkout

This migration produces the same full DAG as
[google-monorepo-sim](https://github.com/paul-hammant/google-monorepo-sim) —
aeb scans all `.build.ae` / `.tests.ae` / `.dist.ae` files, topological-sorts
the dependency graph, and generates a single orchestrator binary that runs
every module in order with an in-memory visited map.

The key property is **greppability**: every in-repo dependency is an explicit
`dep(b, "libs/shared/header")` line in the module's `.build.ae`. No plugin
resolution, no `project.json` graph computation — just grep.

This means `gcheckout` (the Aether sparse-checkout tool from google-monorepo-sim)
can work here. It walks `.build.ae` files, greps `dep()` lines, and
`git sparse-checkout add`s each module transitively. The full dependency
DAG is recoverable from the build files alone.

Third-party npm deps are loaded separately via `load_third_party_deps(b, "../../react.deps.ae")`.
These don't affect the build DAG or sparse checkout — they declare external
packages resolved by pnpm/yarn at install time, not in-repo modules. The
naming is deliberate: `load_third_party_deps` (not `load_deps_file`) to make
clear that in-repo module deps must always be inline `dep()` calls.
