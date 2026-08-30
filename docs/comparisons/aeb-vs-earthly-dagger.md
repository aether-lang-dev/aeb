# aeb vs. Earthly and Dagger

Earthly and Dagger treat builds as reproducible, containerized
pipelines. They are strong when the build environment matters as much
as the commands: pinned images, isolated steps, portable execution,
and remote runners.

aeb treats the repo's module graph as the center. A target is a
dot-prefixed `.ae` file, and language SDKs know how to compile, test,
package, and connect artifacts across languages.

## What aeb should learn

- Containerized execution as an optional backend.
- Explicit action inputs and outputs.
- Remote execution hooks.
- Reproducible build environments for targets that need them.
- Good artifact passing semantics between steps.

## What aeb should keep different

Earthly and Dagger are pipeline-shaped. aeb is graph-shaped. The
pipeline should fall out of the graph, not replace it.

aeb should not make every build step a container by default. For many
repo-local builds, direct SDK invocation is simpler and faster. The
right model is:

```text
.build.ae graph -> actions -> local / sandbox / container / remote backend
```

## Rule of thumb

Use Earthly/Dagger ideas for isolated execution and remote workers.
Keep aeb's source-tree-native graph as the source of truth.
