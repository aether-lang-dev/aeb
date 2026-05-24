/* A header in a non-source include dir. The C library (cbits.c)
 * #includes it, and the .build.ae makes it resolve via include_dir(),
 * standing in for the generated-data-table header an embedding program
 * needs (the mquickjs follow-up Gap 1). */
#define ROM_FACTOR 3
