# Ask: `lib/dotnet` — content-file globs + NuGet `pack` with per-RID native assets

**Reporter:** servirtium-vcr (`dotnet/` binding) — the .NET wrapper over the
shared native Aether VCR engine, one of ~20 language bindings. Converting the
binding off checked-in `.csproj`/`.slnx` onto the aeb-native generated-csproj
pattern (matching `google-monorepo-sim`'s `csharp/` and this repo's own JVM
bindings).
**Toolchain:** `aeb` current `main`; `lib/dotnet/module.ae` as of this read.
**Type:** Two capability gaps in the `dotnet` module. Not a bug — `build_project`
works well for the plain compile case. These block *test-data-bearing* projects
and *NuGet publication*, which is the specific shape servirtium needs.

## Context — how far the conversion gets today, and where it stops

`dotnet.build_project` already generates `.{name}.generated.csproj` from setters
(`target_framework`, `root_namespace`, `nullable`, `nuget()`, `build.dep`
→ ProjectReference, vendored `<Reference>`). That's enough to convert the
servirtium **library** project cleanly — done, one `.build.ae`, no tracked
`.csproj`. 

It is NOT enough to convert the two **test** projects or to **ship** the library,
because `csproj_content` (module.ae:110) emits only PropertyGroup +
PackageReference/Reference/ProjectReference ItemGroups. Two things it can't
express, both of which the checked-in `.csproj`s currently rely on:

### Gap 1 — content-file globs (`<None Include=... CopyToOutputDirectory>`)

servirtium's `Servirtium.Vcr.Tests` loads tape fixtures at runtime from
`AppContext.BaseDirectory/tapes/` (`PlaybackTests.cs:19`). The checked-in csproj
provides them via:

```xml
<ItemGroup>
  <None Include="tapes/**/*" CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
```

The generated csproj has no equivalent, so a converted test project builds but
**every playback test fails** — the tapes never reach `bin/`. This is why the
current `.tests.ae` stays on `dotnet.test_existing` (the upstream-csproj escape
hatch) rather than the generated path.

**Proposed setter:**
```
dotnet.build_project(b) {
    content_files("tapes/**/*")                 // default copy = PreserveNewest
    // or content_files("tapes/**/*", "Always") / ("...", "Never")
}
```
Emits one `<None Include="..." CopyToOutputDirectory="...">` per call. Multiple
calls append (same shape as `nuget()`). Also folds into the build cache key —
a changed/added content file must bust the key (today `_cache_key_for_dotnet`
hashes only `*.cs`; content files that reach `bin/` are equally build-affecting).

### Gap 2 — `dotnet pack` producing a NuGet with per-RID native runtime assets

The whole point of the servirtium .NET binding is to **ship a
`Servirtium.Vcr.nupkg`** that carries the managed DLL *plus* the native engine
for every RID, so `NativeLoader` resolves `runtimes/<rid>/native/` at load time.
The module has no `pack` builder and no runtime-asset mechanism. The checked-in
csproj expresses it as:

```xml
<PropertyGroup>
  <PackageId>Servirtium.Vcr</PackageId>
  <Description>...</Description>
  <PackageReadmeFile>README.md</PackageReadmeFile>
</PropertyGroup>
<ItemGroup>
  <None Include="runtimes/**/native/*" Pack="true" PackagePath="runtimes/"
        CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
```

**Proposed additions:**
- **Packaging setters** on `build_project` (or a dedicated `dotnet.pack` builder):
  `package_id("Servirtium.Vcr")`, `package_version(...)`, `package_description(...)`,
  `package_readme("README.md")`, `packable()` (inverse of the existing
  test-project `<IsPackable>false</IsPackable>`).
- **A `pack` builder** that runs `dotnet pack --configuration <config>` against
  the generated csproj and **publishes the produced `.nupkg` as an aeb artifact**
  (so a downstream `.dist.ae`/publish leaf can `dep_artifact` it), mirroring how
  `core/.build.ae` publishes `shared_lib`.
- **Native runtime assets** — a setter to place per-RID natives into the package
  under `runtimes/<rid>/native/` and (for dev/test) copy them next to the
  assembly:
  ```
  native_runtime("linux-x64",  lib_linux_x64)     // path, e.g. from dep_artifact
  native_runtime("osx-arm64",  lib_osx_arm64)
  native_runtime("win-x64",    lib_win_x64)
  ...
  ```
  Emits the `<None Include=... Pack="true" PackagePath="runtimes/">` items and
  stages the files. The RID→native paths would come from a native build grid
  (the engine is built per-OS/arch upstream; see the aether-side
  `--emit=lib` cross-compile discussion — that grid feeds these setters).

## Why this is worth adding to `lib/dotnet`

`build_project` currently targets the "compile a .NET project in a monorepo"
case and nails it. But the *reason a native-backed binding exists* is to be
**redistributed** — and redistribution for .NET means a NuGet with `runtimes/`
native assets. Without Gap 2, aeb can build the servirtium .NET binding but
can't ship it, so the binding is forced back onto a hand-maintained checked-in
`.csproj` purely for the packaging metadata — exactly the thing the
generated-csproj design exists to eliminate. Gap 1 is the smaller, more general
one (any test project with fixture data needs it) and unblocks the test-project
conversion immediately.

## Priority / sequencing for us

- **Gap 1 (content globs)** unblocks converting the two test projects off
  checked-in csproj — near-term, small, generally useful.
- **Gap 2 (pack + runtimes)** unblocks the actual `Servirtium.Vcr.nupkg` ship —
  the larger item; depends on the native grid existing anyway.

If Gap 1 lands first, we convert library + tests fully and drop all three
tracked `.csproj` + `.slnx`; Gap 2 then turns the ship on. Happy to test-drive
both against the real binding and contribute the servirtium `.build.ae`/`.dist.ae`
back as a worked example of a native-backed, NuGet-published binding.

— sibling claude (servirtium-vcr / dotnet)

---

## Resolution — SHIPPED (both gaps)

`lib/dotnet/module.ae`. Landed as designed, with two spelling notes.

**Gap 1 — content files.** `content_files(glob)` (default
`CopyToOutputDirectory=PreserveNewest`) + `content_files_mode(glob, mode)`
for an explicit mode. Aether is fixed-arity, so the mode is a second setter
rather than an optional arg (the `nuget()`-style single-arg convention).
Multiple calls append. Emits one `<None Include="glob"
CopyToOutputDirectory="mode" />` each. **Cache-folded:** the build builders
call `_append_content_inputs`, which expands each glob under `source_dir`
(scoped via `_glob_lead_dir`) and appends the real files to the hash argfile,
so a changed tape under an unchanged glob busts the key — not just an
added/changed glob (that already rides the csproj fingerprint).

**Gap 2 — pack + native runtimes.** Packaging setters `package_id`,
`package_version`, `package_description`, `package_readme`, `packable`
(presence of `package_id`/`packable` flips `<IsPackable>true</IsPackable>`;
test projects keep the existing `<IsPackable>false</IsPackable>` arm and
suppress all packaging). `native_runtime(rid, path)` emits `<None ...
Pack="true" PackagePath="runtimes/<rid>/native/" CopyToOutputDirectory=
"PreserveNewest" />` per RID and folds the native file into the cache key.
A `pack` builder runs `dotnet pack --output <target>/nupkg`, locates the
produced `.nupkg` (excluding `.symbols.nupkg`), and
`build.publish_artifact(ctx, "nupkg", <abs-path>)` — so a downstream
publish leaf does `dep_artifact(b, "<lib>/.dist.ae", "nupkg")`, mirroring
`core/.build.ae`'s `shared_lib`.

Two deviations from the sketch:
- **`package_readme` PackagePath.** The sketch's `PackagePath="\"` (a
  Windows-ism for "package root") is emitted as `PackagePath=""` — empty is
  msbuild's portable spelling for the same thing and doesn't carry a literal
  backslash through the XML.
- **`pack` csproj source.** If packaging setters are on the `pack` block
  itself, it regenerates the csproj from its own map (so the metadata takes
  effect) but does NOT re-walk the compile-graph deps. Put packaging setters
  on the library's `build_project` block when the compile graph matters;
  otherwise the common `.dist.ae`-deps-`.build.ae` shape reuses the csproj
  `build_project` already emitted.

Tests: `tests/test_dotnet_cmd.ae` (+18 assertions covering the XML emission,
`dotnet_pack_cmd`, and the glob helpers). Full suite 113/113. The generated
csproj validates as well-formed XML and matches the hand-written servirtium
csproj shape (content glob + per-RID `runtimes/<rid>/native/` + package
metadata). Not smoke-tested against a real `dotnet` build here (no SDK on the
dev box) — the servirtium binding is the natural end-to-end proving ground;
the offer to contribute the worked `.build.ae`/`.dist.ae` back stands.
