# aeb v0.305 lib/ruby: `ruby_manager("rbenv")` resolves tool PATHS but doesn't establish the rbenv ENV → `bundle exec` runs under the system Ruby

(Distinct from the segfault ask — that's fixed. This is the next layer, in the
rbenv resolution itself.)

## Symptom
A ruby node with `ruby_manager("rbenv")` (was `ruby_env`) installs gems fine but
then `bundle exec ruby …` fails:
`Could not find minitest-…, base64-…, webrick-…, erb-… in locally installed
gems (Bundler::GemNotFound)`. The SAME node WITHOUT `ruby_manager` (system Ruby)
passes. So it is rbenv-routing-specific.

## Root cause
`_rbenv_which(builder_map, tool)` resolves via `rbenv which <tool>`, which returns
the **version-dir binary** e.g. `~/.rbenv/versions/3.3.12/bin/bundle`. The cmd
builders then run that bare (`'${bundle_bin}' exec …`). A bare version-dir
binary does NOT set up the rbenv environment (RBENV_VERSION / RUBYLIB / GEM_HOME
selection), so the process falls back to the **system** Ruby's rubygems — the
trace shows `<internal:/usr/lib/ruby/vendor_ruby/rubygems/...>` (system 3.1),
not the rbenv 3.3.12 gems. Install (which wrote a `--local path` config) and
exec then disagree on where gems live.

## Verified fixes (by hand)
Both establish the env and load the gems correctly:
- `rbenv exec bundle …` (needs rbenv on PATH or an absolute rbenv bin + env), OR
- the rbenv **shim** by absolute path: `~/.rbenv/shims/bundle …` — self-establishes
  the env even with NOTHING rbenv on PATH (proven: `PATH=/usr/bin:/bin` +
  absolute shim → install + `exec ruby require minitest` both succeed).

## Suggested fix
For the rbenv manager, resolve tools to the **shim path**
(`$RBENV_ROOT|~/.rbenv/shims/<tool>`) rather than `rbenv which <tool>`'s
version-dir binary — the shim fits the builders' existing quoted single-token
shape (`'${bundle_bin}'`) AND establishes the env. When a version is pinned,
still export `RBENV_VERSION` (the shim honours it). Keep `rbenv which` only if
you additionally wrap execution in `rbenv exec` / export the env — but the shim
is the smaller change given the current cmd-builder shape.

## Repro
```
cd <a ruby node dir with a Gemfile>
export PATH=$HOME/.rbenv/bin:/usr/bin:/bin
B=$(rbenv which bundle)      # version-dir binary
"$B" config set --local path "$PWD/.b" && "$B" install
"$B" exec ruby -e 'require "minitest/autorun"'   # FAILS: uses system rubygems
$HOME/.rbenv/shims/bundle exec ruby -e 'require "minitest/autorun"'  # WORKS
```

## selaenium impact
selaenium's ruby/.tests.ae needs rbenv Ruby 3.3.12 (system apt Ruby 3.1's
default cgi gem can't be swapped by bundler for the webrick specs). With this
bug the rbenv path can't run the suite; the crash is gone but the bundle-exec
env issue blocks a green run until the shim (or rbenv-exec) fix lands. As a
stopgap, putting `~/.rbenv/shims` on PATH and dropping `ruby_manager` makes the
default (system-PATH) resolver pick the shim'd 3.3.12 — but the point of
`ruby_manager` was to avoid that PATH accident, so the SDK should do it right.

Found 2026-09-11.
