/* A C library function the Aether program FFIs into (declared `extern
 * c_triple` in app.ae). It #includes rom.h from a separate include dir,
 * which resolves only because .build.ae declares include_dir("../inc")
 * — exercising the Gap-1 `-I` support. This is a committed C *library*
 * (not a `main` shim); the program's entry is still Aether's main(). */
#include "rom.h"
int c_triple(int x) { return x * ROM_FACTOR; }
