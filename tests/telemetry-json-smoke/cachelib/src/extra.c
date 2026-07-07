/* Empty extra translation unit. Its only job is to make
 * aether.program take the manual _compile_and_link path (which caches)
 * instead of the shell-out `ae build` path (which does not). */
int _telemetry_smoke_extra(void) { return 0; }
