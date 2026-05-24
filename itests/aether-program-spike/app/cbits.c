/* A C library function the Aether program FFIs into (declared `extern
 * c_triple` in app.ae). This is a committed C *library* — not a `main`
 * shim — so it is exactly the kind of C an Aether program is allowed to
 * link. The program's entry point is still Aether's main(). */
int c_triple(int x) { return x * 3; }
