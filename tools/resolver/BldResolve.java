/*
 * aeb-resolve — Maven dependency resolver for aeb, on top of bld's resolver.
 *
 * This is a drop-in replacement for the Eclipse-Aether-based MavenResolver:
 * same CLI contract, same stdout semantics (colon-joined classpath for
 * --output classpath, sorted/de-duped "g:a:v" lines for --output sbom), but
 * implemented entirely on bld's self-contained resolver (com.uwyn.rife2:bld,
 * zero external deps).
 *
 * CLI:
 *   java -cp <bld.jar>:<dir-with-this-class> aeb.maven.BldResolve \
 *        --output classpath|sbom [--bom G:A:V]... [--bom-file <path>]... \
 *        [--repo <url>]... [--cache <dir>] <coord> <coord>...
 *
 *   --output   classpath (default) | sbom | nodes
 *              nodes: write one aeb build file per artifact of the closure,
 *              each with its jar's sha256 and a dep() on what ITS pom asks
 *              for, at the version the pom declares. No version is mediated:
 *              two versions of one artifact are both written and reported,
 *              and a person picks (dep_arbitration; --pick writes a default).
 *   --into     <dir>     nodes: where (default third_party/java), laid out
 *                        <dir>/<group dirs>/<artifact>/<version>/.jar.ae
 *              --bom there only gives a version to a version-less
 *              coordinate named on the command line; no node's edges are
 *              changed by it.
 *   --output   managed: for each --bom G:A:V, write what it manages to
 *              <dir>/<group dirs>/<artifact>/<version>/managed.bom.ae, one
 *              managed("group:artifact", "version") line each, sorted. The
 *              build reads versions from that file, not from the network.
 *   --pick     G:A=V     nodes: write <dir>/<group dirs>/<artifact>/.jar.ae,
 *                        the default for G:A: V, and not the other versions
 *                        this run found (may repeat)
 *   --bom      G:A:V     import an external BOM's managed versions (may repeat)
 *   --bom-file <path>    import a local BOM: either an aeb `.bom.ae` (scanned
 *                        as text for maven_bom()/maven_repo()/dep() lines) or
 *                        a Maven BOM POM's managed versions (may repeat)
 *   --repo     <url>     add a repository besides Maven Central (may repeat)
 *   --cache    <dir>     download directory (default XDG data / ~/.local/share)
 *   <coord>              group:artifact[:version] positional, transitively resolved
 *
 * IMPORTANT (stdout discipline): bld's DependencyResolver prints "Downloading:"
 * progress to stdout. lib/maven parses our stdout as the classpath, so during
 * all resolution/download we redirect System.out to System.err and only restore
 * it to print the final result line(s). Nothing but the result reaches stdout.
 *
 * FAILURE: anything asked for that could not be had is an error, not a warning:
 * an unknown option, a BOM or BOM file that cannot be read, a parent or imported
 * POM that cannot be fetched, a coordinate with no version, a coordinate that
 * does not resolve, a jar that does not download. Each is reported on stderr as
 * "error: ...", every one of them rather than the first, and the exit status is
 * 1 with NOTHING on stdout. A caller must never be handed part of a classpath:
 * the compile that follows then fails on a missing class, or worse succeeds and
 * the missing jar is found at run time.
 *
 * Licensed under Apache-2.0.
 */
package aeb.maven;

import rife.bld.dependencies.ArtifactRetriever;
import rife.bld.dependencies.Dependency;
import rife.bld.dependencies.DependencyResolver;
import rife.bld.dependencies.DependencySet;
import rife.bld.dependencies.Repository;
import rife.bld.dependencies.RepositoryArtifact;
import rife.bld.dependencies.Scope;
import rife.bld.dependencies.Version;
import rife.bld.dependencies.VersionResolution;
import rife.ioc.HierarchicalProperties;

import javax.xml.parsers.DocumentBuilderFactory;
import java.io.File;
import java.io.PrintStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

public class BldResolve {

    public static void main(String[] args) {
        List<String> boms = new ArrayList<>();
        List<String> bomFiles = new ArrayList<>();
        List<String> repoUrls = new ArrayList<>();
        List<String> deps = new ArrayList<>();
        String outputMode = "classpath";
        // Everything that went wrong, in the order met. Non-empty at the end
        // means exit 1 and an empty stdout.
        List<String> errors = new ArrayList<>();
        String into = "third_party/java";
        List<String> picks = new ArrayList<>();

        // XDG Base Directory: downloaded Maven artifacts are reconstructible
        // but expensive, so they live in the data dir, not the cache dir.
        // Matches MavenResolver's default so the two shims share a store.
        String xdgData = System.getenv("XDG_DATA_HOME");
        String cacheDir = (xdgData != null && !xdgData.isEmpty())
                ? xdgData + "/aeb/repo"
                : System.getProperty("user.home") + "/.local/share/aeb/repo";

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--bom":      boms.add(args[++i]); break;
                case "--bom-file": bomFiles.add(args[++i]); break;
                case "--repo":     repoUrls.add(args[++i]); break;
                case "--output":   outputMode = args[++i]; break;
                case "--cache":    cacheDir = args[++i]; break;
                case "--into":     into = args[++i]; break;
                case "--pick":     picks.add(args[++i]); break;
                default:
                    if (args[i].startsWith("-")) {
                        errors.add("unknown option: " + args[i]);
                    } else {
                        deps.add(args[i]);
                    }
            }
        }

        // A --bom-file is EITHER an aeb `.bom.ae` — the aeb DSL, scanned as text
        // for maven_bom()/maven_repo()/dep() lines, which is the contract every
        // `*.bom.ae` in the tree documents — OR a literal Maven BOM POM (XML).
        // The Eclipse-Aether shim this class replaced handled both; the rewrite
        // to bld kept only the XML branch, so each `.bom.ae` died with
        // "Content is not allowed in prolog" and its repo/coordinate lines were
        // dropped with only a warning. The visible symptom was one step removed
        // from the cause: a Clojars- or Jitpack-hosted closure reported as
        // "couldn't find artifact ... at repo1.maven.org".
        //
        // Discriminate on CONTENT, not on the filename: a POM's first non-blank
        // character is always '<' (prolog or root element), and an .ae file's
        // never is.
        List<String> bomPomFiles = new ArrayList<>();
        for (String bomFile : bomFiles) {
            try {
                Path bp = Paths.get(bomFile);
                if (looksLikeXml(bp)) {
                    bomPomFiles.add(bomFile);
                } else {
                    parseBomAeFile(bp, boms, repoUrls, deps);
                }
            } catch (Exception e) {
                errors.add("could not read BOM file " + bomFile + ": " + e.getMessage());
            }
        }
        bomFiles = bomPomFiles;

        // Repository list: Central always present, plus any --repo URLs.
        List<Repository> repos = new ArrayList<>();
        repos.add(Repository.MAVEN_CENTRAL);
        for (String url : repoUrls) {
            repos.add(new Repository(url));
        }

        // Full remote URL list used for raw BOM-POM fetching (Central + extras).
        List<String> fetchUrls = new ArrayList<>();
        fetchUrls.add("https://repo1.maven.org/maven2");
        fetchUrls.addAll(repoUrls);

        var props = new HierarchicalProperties();
        var vr = new VersionResolution(props);
        // The caching retriever: a pom is read once per run, and a pom that
        // needs cleaning before bld can parse it can be put in (cleanPom).
        var retriever = ArtifactRetriever.cachingInstance();

        // versionOverrides() is bld's LIVE backing map (verified by disassembly:
        // it returns the private versionOverrides_ field). Its key is
        // Dependency.toArtifactString() == "group:artifact"; its value is a
        // Version. DependencyResolver.getAllDependencies() consults it via
        // overrideDependency(), so putting "g:a" -> Version here makes a
        // version-less positional coord (or any transitive dep) take the BOM's
        // version. We seed it from every --bom / --bom-file BEFORE resolving.
        Map<String, Version> overrides = vr.versionOverrides();

        // stdout discipline: capture the real stdout, silence bld's progress
        // (it prints "Downloading:" to stdout) by pointing System.out at stderr
        // for the whole resolution phase. Restore only to print the result.
        PrintStream realOut = System.out;
        System.setOut(new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.err), true));

        String result;
        try {
            // Load caller-supplied BOMs into the override map.
            for (String bom : boms) {
                try {
                    loadBomCoord(bom, fetchUrls, overrides, errors);
                } catch (Exception e) {
                    errors.add("could not load BOM " + bom + ": " + e.getMessage());
                }
            }
            for (String bomFile : bomFiles) {
                try {
                    loadBomFile(Paths.get(bomFile), fetchUrls, overrides, errors);
                } catch (Exception e) {
                    errors.add("could not load BOM file " + bomFile + ": " + e.getMessage());
                }
            }

            File out = new File(cacheDir);
            out.mkdirs();

            // Resolve the transitive closure (compile + runtime) of every
            // positional coord, honouring the seeded version overrides.
            DependencySet all = new DependencySet();
            for (String coord : "nodes".equals(outputMode) ? new ArrayList<String>() : deps) {
                try {
                    Dependency root = Dependency.parse(coord);
                    // If version-less and no override provides one, bld would try
                    // to resolve version 0.0.0 and fail on that; say what is
                    // actually missing.
                    if (isUnknownVersion(root.version()) && overrides.get(root.toArtifactString()) == null) {
                        errors.add(root.toArtifactString() + " has no version and no BOM provides one");
                        continue;
                    }
                    var resolver = new DependencyResolver(vr, retriever, repos, root);
                    // getAllDependencies applies overrideDependency to the root
                    // and every transitive dep, and pulls in each dep's own
                    // declared dependencyManagement/parent automatically.
                    DependencySet closure = null;
                    for (int attempt = 0; closure == null; attempt++) {
                        try {
                            closure = resolver.getAllDependencies(Scope.compile, Scope.runtime);
                        } catch (Exception e) {
                            if (attempt > 50 || !cleanPom(e, retriever, repos)) throw e;
                            resolver = new DependencyResolver(vr, retriever, repos, root);
                        }
                    }
                    all.addAll(closure);
                } catch (Exception e) {
                    errors.add("cannot resolve " + coord + ": " + e.getMessage());
                }
            }

            if ("managed".equals(outputMode)) {
                result = writeManaged(boms, into, fetchUrls, errors);
            } else if ("nodes".equals(outputMode)) {
                result = writeNodes(deps, into, picks, repoUrls, vr, retriever, repos,
                        fetchUrls, overrides, out, errors);
            } else if ("sbom".equals(outputMode)) {
                // Sorted + de-duped coordinate closure, one "g:a:v" per line.
                TreeSet<String> coords = new TreeSet<>();
                for (Dependency d : all) {
                    coords.add(d.groupId() + ":" + d.artifactId() + ":" + d.version());
                }
                StringBuilder sb = new StringBuilder();
                for (String c : coords) sb.append(c).append('\n');
                // Trim a single trailing newline so println doesn't double it.
                if (sb.length() > 0 && sb.charAt(sb.length() - 1) == '\n') sb.setLength(sb.length() - 1);
                result = sb.toString();
            } else {
                // classpath: download each jar, colon-join absolute paths.
                List<String> jarPaths = new ArrayList<>();
                for (Dependency d : all) {
                    try {
                        var dr = new DependencyResolver(vr, retriever, repos, d);
                        dr.transferIntoDirectory(out);
                        for (String loc : dr.getTransferLocations()) {
                            File f = new File(out, new File(loc).getName());
                            if (f.getName().endsWith(".jar")) {
                                jarPaths.add(f.getAbsolutePath());
                            }
                        }
                    } catch (Exception e) {
                        errors.add("cannot download " + d + ": " + e.getMessage());
                    }
                }
                result = String.join(":", jarPaths);
            }
        } finally {
            System.setOut(realOut);
        }

        if (!errors.isEmpty()) {
            for (String e : errors) System.err.println("error: " + e);
            System.err.println("aeb-resolve: " + errors.size()
                    + (errors.size() == 1 ? " error" : " errors") + ", nothing resolved");
            System.exit(1);
        }

        // Only the final result reaches the real stdout.
        if (!result.isEmpty()) System.out.println(result);
    }

    /**
     * Some poms on Maven Central begin with a UTF-8 byte-order mark
     * (dk.brics.automaton:automaton:1.11-8 is one). Maven reads them; bld's
     * XML reader stops at "Content is not allowed in prolog", and the whole
     * closure above that pom is lost. When `e` is that failure, fetch the pom
     * named in it, drop everything before its first '<', and put the cleaned
     * text into the retriever's cache so the next attempt parses it. True
     * when something was cleaned and a retry is worth making.
     */
    private static boolean cleanPom(Exception e, ArtifactRetriever retriever, List<Repository> repos) {
        String msg = String.valueOf(e.getMessage());
        if (!msg.contains("Unable to parse artifact document")) return false;
        Matcher m = Pattern.compile("from '([^']+\\.pom)'").matcher(msg);
        if (!m.find()) return false;
        String url = m.group(1);
        try {
            String xml;
            if (url.startsWith("file:")) {
                xml = new String(Files.readAllBytes(Paths.get(URI.create(url))), StandardCharsets.UTF_8);
            } else if (url.startsWith("/")) {
                xml = new String(Files.readAllBytes(Paths.get(url)), StandardCharsets.UTF_8);
            } else {
                HttpResponse<String> resp = HTTP.send(HttpRequest.newBuilder(URI.create(url)).GET().build(),
                        HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
                if (resp.statusCode() != 200) return false;
                xml = resp.body();
            }
            int lt = xml.indexOf('<');
            if (lt <= 0) return false;      // nothing in front of the document: not this problem
            String cleaned = xml.substring(lt);
            var cache = ArtifactRetriever.class.getDeclaredMethod("cache", RepositoryArtifact.class, String.class);
            cache.setAccessible(true);
            for (Repository r : repos) cache.invoke(retriever, new RepositoryArtifact(r, url), cleaned);
            System.err.println("note: " + url + " begins with " + lt
                    + " character(s) before its XML (a byte-order mark); read without them");
            return true;
        } catch (Exception ex) {
            return false;
        }
    }

    // ---- --output nodes ---------------------------------------------------

    /** group:artifact:version, with :classifier when there is one. */
    private static String coordOf(Dependency d) {
        String c = d.groupId() + ":" + d.artifactId() + ":" + d.version();
        String cl = d.classifier();
        return (cl == null || cl.isEmpty()) ? c : c + ":" + cl;
    }

    /** <into>/<group dirs>/<artifact>, the directory holding the version directories. */
    private static String artifactDir(String into, Dependency d) {
        return into + "/" + d.groupId().replace('.', '/') + "/" + d.artifactId();
    }

    /** <into>/<group dirs>/<artifact>/<version>[-<classifier>], one version's node. */
    private static String nodeDir(String into, Dependency d) {
        String cl = d.classifier();
        return artifactDir(into, d) + "/" + d.version()
                + ((cl == null || cl.isEmpty()) ? "" : "-" + cl);
    }

    private static String sha256(Path p) throws Exception {
        var md = java.security.MessageDigest.getInstance("SHA-256");
        byte[] h = md.digest(Files.readAllBytes(p));
        StringBuilder sb = new StringBuilder();
        for (byte b : h) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    /** Write `content` to `file` unless it already holds exactly that. True when written. */
    private static boolean writeIfChanged(Path file, String content) throws Exception {
        if (Files.exists(file)
                && new String(Files.readAllBytes(file), StandardCharsets.UTF_8).equals(content)) {
            return false;
        }
        Files.createDirectories(file.getParent());
        Files.write(file, content.getBytes(StandardCharsets.UTF_8));
        return true;
    }

    /**
     * Walk the closure of `roots` as the poms declare it and write a node per
     * artifact. Returns the report for stdout. Every failure goes to `errors`;
     * the caller prints them and exits 1, and nodes already written stay (each
     * is whole and correct on its own).
     */
    private static String writeNodes(List<String> roots, String into, List<String> picks,
                                     List<String> repoUrls, VersionResolution vr,
                                     ArtifactRetriever retriever, List<Repository> repos,
                                     List<String> fetchUrls, Map<String, Version> overrides,
                                     File cache, List<String> errors) {
        String home = System.getProperty("user.home");
        Path jarStore = Paths.get(home, ".cache", "aeb", "jars");
        Map<String, Dependency> seen = new LinkedHashMap<>();          // coord -> artifact
        Map<String, List<String>> askedBy = new LinkedHashMap<>();     // coord -> who asked
        java.util.ArrayDeque<Dependency> queue = new java.util.ArrayDeque<>();
        int written = 0, unchanged = 0;
        List<String> notes = new ArrayList<>();

        for (String coord : roots) {
            try {
                Dependency root = Dependency.parse(coord);
                if (isUnknownVersion(root.version()) && overrides.get(root.toArtifactString()) == null) {
                    errors.add(root.toArtifactString() + " has no version and no BOM provides one");
                    continue;
                }
                root = vr.overrideDependency(root);
                queue.add(root);
                askedBy.computeIfAbsent(coordOf(root), k -> new ArrayList<>()).add("you");
            } catch (Exception e) {
                errors.add("cannot read coordinate " + coord + ": " + e.getMessage());
            }
        }
        // A BOM has now done all it does here: given a version to a root
        // that had none. From this point every edge is what the artifact's
        // own pom declares. A node is one file shared by everything that
        // depends on it, so it cannot carry one consumer's BOM.
        overrides.clear();

        while (!queue.isEmpty()) {
            Dependency d = queue.poll();
            String coord = coordOf(d);
            if (seen.containsKey(coord)) continue;
            seen.put(coord, d);
            try {
                String type = d.type();
                boolean pomOnly = "pom".equals(type);
                if (type != null && !type.isEmpty() && !"jar".equals(type) && !pomOnly) {
                    errors.add(coord + " is of type '" + type + "', asked for by "
                            + String.join(", ", askedBy.get(coord)) + ": only jar and pom are handled");
                    continue;
                }
                // The dependency without its asker's exclusions: this node is
                // the artifact as its own pom has it. Exclusions are recorded
                // on the edge of whoever declared them.
                Dependency base = new Dependency(d.groupId(), d.artifactId(), d.version(),
                        d.classifier(), d.type());
                var resolver = new DependencyResolver(vr, retriever, repos, base);
                DependencySet direct = null;
                for (int attempt = 0; direct == null; attempt++) {
                    try {
                        direct = resolver.getDirectDependencies(Scope.compile, Scope.runtime);
                    } catch (Exception e) {
                        if (attempt > 50 || !cleanPom(e, retriever, repos)) throw e;
                        resolver = new DependencyResolver(vr, retriever, repos, base);
                    }
                }

                String pomXml = fetchPom(d.groupId(), d.artifactId(), d.version().toString(), fetchUrls);
                if (pomXml != null) {
                    String packaging = childText(parseXml(pomXml).getDocumentElement(), "packaging");
                    if ("pom".equals(packaging)) pomOnly = true;
                }

                String sha = "";
                if (!pomOnly) {
                    resolver.transferIntoDirectory(cache);
                    File jar = null;
                    for (String loc : resolver.getTransferLocations()) {
                        File f = new File(cache, new File(loc).getName());
                        if (f.getName().endsWith(".jar")) jar = f;
                    }
                    if (jar == null || !jar.isFile()) {
                        errors.add(coord + " has no jar in any repository");
                        continue;
                    }
                    sha = sha256(jar.toPath());
                    // Where java.jar_maven looks first, so the build that
                    // follows fetches nothing.
                    Path stored = jarStore.resolve(sha + ".jar");
                    if (!Files.exists(stored)) {
                        Files.createDirectories(jarStore);
                        Files.copy(jar.toPath(), stored);
                    }
                }

                StringBuilder n = new StringBuilder();
                n.append("// ").append(coord).append(", as its pom declares it.\n");
                n.append("// Written by `aeb mvn add`; run that again rather than edit this.\n");
                n.append("import bldr\n");
                if (!direct.isEmpty()) n.append("import bldr (dep)\n");
                n.append("import java\n");
                List<String> setters = new ArrayList<>();
                StringBuilder block = new StringBuilder();
                if (!pomOnly && !repoUrls.isEmpty()) {
                    setters.add("central");
                    setters.add("repo");
                    block.append("            central()\n");
                    for (String u : repoUrls) block.append("            repo(\"").append(u).append("\")\n");
                }
                StringBuilder depLines = new StringBuilder();
                for (Dependency raw : direct) {
                    Dependency dep = raw;
                    if (isUnknownVersion(dep.version())) {
                        // A version bld could not read as one: a range. Take
                        // it from the pom's own text and settle it now, once;
                        // the node records the version, not the range.
                        String range = pomXml == null ? null
                                : declaredVersion(pomXml, raw.groupId(), raw.artifactId());
                        String fixed = range == null ? null
                                : versionInRange(range, raw.groupId(), raw.artifactId(), fetchUrls);
                        if (range == null && pomXml != null) {
                            // No <version> on the dependency: the pom's own
                            // dependencyManagement supplies it, through its
                            // parents and the BOMs they import (jaxb-runtime
                            // and jaxb-core). That is the artifact's own
                            // declaration, not a consumer's BOM.
                            Map<String, Version> own = new LinkedHashMap<>();
                            parsePomInto(pomXml, fetchUrls, own, new ArrayList<>());
                            Version mv = own.get(raw.toArtifactString());
                            if (mv != null) {
                                fixed = mv.toString();
                                range = "[" + fixed + "]";
                            }
                        }
                        if (fixed == null) {
                            errors.add(coord + " asks for " + dep.toArtifactString()
                                    + (range == null ? " with no version its pom supplies"
                                        : " at " + range + ", and no published version is in that range"));
                            continue;
                        }
                        if (!range.equals("[" + fixed + "]")) {
                            notes.add(coord + " asks for " + dep.toArtifactString() + " at " + range
                                    + ": taken as " + fixed + ", the highest published in the range today");
                        }
                        dep = new Dependency(raw.groupId(), raw.artifactId(), Version.parse(fixed),
                                raw.classifier(), raw.type(), raw.exclusions());
                    }
                    String dc = coordOf(dep);
                    depLines.append("        dep(\"").append(nodeDir(into, dep)).append("/.jar.ae\")\n");
                    for (var ex : raw.exclusions()) {
                        if (!setters.contains("excluding")) setters.add("excluding");
                        block.append("            excluding(\"").append(dep.toArtifactString())
                                .append("\", \"").append(ex.groupId()).append(":")
                                .append(ex.artifactId()).append("\")\n");
                    }
                    askedBy.computeIfAbsent(dc, k -> new ArrayList<>()).add(coord);
                    queue.add(dep);
                }
                if (!setters.isEmpty()) {
                    n.append("import java (").append(String.join(", ", setters)).append(")\n");
                }
                n.append("main() {\n    bldr.build() {\n").append(depLines);
                String call = pomOnly
                        ? "java.pom_maven(\"" + coord + "\")"
                        : "java.jar_maven(\"" + coord + "\", \"" + sha + "\")";
                if (block.length() > 0) {
                    n.append("        ").append(call).append(" {\n").append(block).append("        }\n");
                } else {
                    n.append("        ").append(call).append("\n");
                }
                n.append("    }\n}\n");
                if (writeIfChanged(Paths.get(nodeDir(into, d), ".jar.ae"), n.toString())) written++;
                else unchanged++;
            } catch (Exception e) {
                errors.add("cannot resolve " + coord + " (asked for by "
                        + String.join(", ", askedBy.get(coord)) + "): " + e.getMessage());
            }
        }

        // Artifacts met at more than one version: the diamonds a classpath
        // holding all of this would have.
        Map<String, List<Dependency>> byGa = new LinkedHashMap<>();
        for (Dependency d : seen.values()) {
            String cl = d.classifier();
            String ga = d.toArtifactString() + ((cl == null || cl.isEmpty()) ? "" : ":" + cl);
            byGa.computeIfAbsent(ga, k -> new ArrayList<>()).add(d);
        }

        StringBuilder report = new StringBuilder();
        for (String pick : picks) {
            int eq = pick.indexOf('=');
            if (eq < 0) { errors.add("--pick wants group:artifact=version, got " + pick); continue; }
            String ga = pick.substring(0, eq), v = pick.substring(eq + 1);
            List<Dependency> vs = byGa.get(ga);
            Dependency chosen = null;
            List<String> others = new ArrayList<>();
            if (vs != null) for (Dependency d : vs) {
                if (d.version().toString().equals(v)) chosen = d; else others.add(d.version().toString());
            }
            if (chosen == null) {
                errors.add("--pick " + pick + ": this closure does not hold " + ga + " at " + v);
                continue;
            }
            if (others.isEmpty()) {
                errors.add("--pick " + pick + ": " + ga + " is at one version here; there is nothing to pick between");
                continue;
            }
            String body = "// The default for " + ga + " wherever a classpath would hold more than one\n"
                    + "// version of it and no node closer to the leaf says otherwise.\n"
                    + "import bldr\nimport bldr (dep, dep_arbitration, and_not)\nimport java\n"
                    + "main() {\n    bldr.build() {\n"
                    + "        dep_arbitration(\"" + ga + "\", \"" + v + "\", and_not(\""
                    + String.join(", ", others) + "\"))\n"
                    + "        dep(\"" + nodeDir(into, chosen) + "/.jar.ae\")\n"
                    + "        java.jar_bundle()\n    }\n}\n";
            try {
                Path f = Paths.get(artifactDir(into, chosen), ".jar.ae");
                writeIfChanged(f, body);
                report.append("default: ").append(ga).append(" is ").append(v).append(", and not ")
                        .append(String.join(", ", others)).append("  (").append(f).append(")\n");
            } catch (Exception e) {
                errors.add("cannot write the default for " + ga + ": " + e.getMessage());
            }
        }

        for (var e : byGa.entrySet()) {
            List<Dependency> vs = e.getValue();
            if (vs.size() < 2) continue;
            String ga = e.getKey();
            Path adir = Paths.get(artifactDir(into, vs.get(0)));
            boolean hasDefault = false;
            try (var files = Files.list(adir)) {
                for (Path f : (Iterable<Path>) files::iterator) {
                    String name = f.getFileName().toString();
                    if (Files.isRegularFile(f) && name.startsWith(".") && name.endsWith(".ae")
                            && new String(Files.readAllBytes(f), StandardCharsets.UTF_8)
                                .contains("dep_arbitration(\"" + ga + "\"")) hasDefault = true;
                }
            } catch (Exception ignore) {
                // no directory, no default
            }
            Dependency highest = vs.get(0);
            for (Dependency d : vs) if (d.version().compareTo(highest.version()) > 0) highest = d;
            report.append("diamond: ").append(ga).append(hasDefault ? "  (a default is written)\n" : "\n");
            for (Dependency d : vs) {
                report.append("    ").append(d.version()).append("  asked for by ")
                        .append(String.join(", ", askedBy.get(coordOf(d)))).append("\n");
            }
            if (!hasDefault) {
                report.append("    a classpath holding both stops until someone picks: in the build file that\n")
                      .append("    meets it, or as the default with  --pick ").append(ga).append("=")
                      .append(highest.version()).append("  (the highest; a suggestion)\n");
            }
        }
        for (String note : notes) report.append("range: ").append(note).append("\n");
        report.append(written).append(" node").append(written == 1 ? "" : "s").append(" written, ")
              .append(unchanged).append(" unchanged, under ").append(into);
        return report.toString();
    }

    /**
     * The <version> text a pom gives its own dependency on group:artifact,
     * with ${...} properties of that pom filled in; null if it gives none.
     */
    private static String declaredVersion(String pomXml, String group, String artifact) throws Exception {
        Element project = parseXml(pomXml).getDocumentElement();
        Map<String, String> props = new LinkedHashMap<>();
        Element propsEl = firstChild(project, "properties");
        if (propsEl != null) {
            NodeList kids = propsEl.getChildNodes();
            for (int i = 0; i < kids.getLength(); i++) {
                Node k = kids.item(i);
                if (k.getNodeType() == Node.ELEMENT_NODE) props.put(k.getNodeName(), k.getTextContent().trim());
            }
        }
        String pv = childText(project, "version");
        if (pv != null) props.putIfAbsent("project.version", pv);
        Element depsEl = firstChild(project, "dependencies");
        if (depsEl == null) return null;
        for (Element dep : childElements(depsEl, "dependency")) {
            if (group.equals(interpolate(childText(dep, "groupId"), props))
                    && artifact.equals(interpolate(childText(dep, "artifactId"), props))) {
                String v = interpolate(childText(dep, "version"), props);
                return (v == null || v.isEmpty()) ? null : v;
            }
        }
        return null;
    }

    /**
     * The version a Maven range stands for: "[1.2]" is 1.2; anything with a
     * bound ("[1.0,2.0)", "[1.5,)", "(,1.0]", several joined by commas) is the
     * highest published version inside it, read from the artifact's
     * maven-metadata.xml. Null when the text is not a range or nothing fits.
     */
    private static String versionInRange(String range, String group, String artifact,
                                         List<String> repoUrls) {
        String r = range.trim();
        if (!(r.startsWith("[") || r.startsWith("("))) return null;
        Matcher exact = Pattern.compile("^\\[([^,\\[\\]()]+)\\]$").matcher(r);
        if (exact.matches()) return exact.group(1).trim();

        List<String[]> spans = new ArrayList<>();   // [open, low, high, close]
        Matcher m = Pattern.compile("([\\[(])([^,\\[\\]()]*),([^,\\[\\]()]*)([\\])])").matcher(r);
        while (m.find()) spans.add(new String[]{m.group(1), m.group(2).trim(), m.group(3).trim(), m.group(4)});
        if (spans.isEmpty()) return null;

        String rel = group.replace('.', '/') + "/" + artifact + "/maven-metadata.xml";
        List<String> published = new ArrayList<>();
        for (String base : repoUrls) {
            String url = base.endsWith("/") ? base + rel : base + "/" + rel;
            try {
                String xml;
                if (url.startsWith("file:")) {
                    Path p = Paths.get(URI.create(url));
                    if (!Files.exists(p)) continue;
                    xml = new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
                } else {
                    HttpResponse<String> resp = HTTP.send(HttpRequest.newBuilder(URI.create(url)).GET().build(),
                            HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
                    if (resp.statusCode() != 200) continue;
                    xml = resp.body();
                }
                Matcher vm = Pattern.compile("<version>([^<]+)</version>").matcher(xml);
                while (vm.find()) published.add(vm.group(1).trim());
                if (!published.isEmpty()) break;
            } catch (Exception e) {
                // try the next repository
            }
        }
        Version best = null;
        for (String pv : published) {
            Version v;
            try { v = Version.parse(pv); } catch (Exception e) { continue; }
            // A range does not reach for a pre-release unless it names one.
            String q = v.qualifier();
            if (q != null && !q.isEmpty() && !r.contains(q)) continue;
            for (String[] sp : spans) {
                boolean ok = true;
                if (!sp[1].isEmpty()) {
                    int c = v.compareTo(Version.parse(sp[1]));
                    ok = "[".equals(sp[0]) ? c >= 0 : c > 0;
                }
                if (ok && !sp[2].isEmpty()) {
                    int c = v.compareTo(Version.parse(sp[2]));
                    ok = "]".equals(sp[3]) ? c <= 0 : c < 0;
                }
                if (ok && (best == null || v.compareTo(best) > 0)) best = v;
            }
        }
        return best == null ? null : best.toString();
    }

    /**
     * --output managed: one file per --bom, listing what it manages. Each BOM
     * is read on its own (its parents and imports included), so the file says
     * what THAT BOM manages, not the union of all given.
     */
    private static String writeManaged(List<String> boms, String into,
                                       List<String> fetchUrls, List<String> errors) {
        StringBuilder report = new StringBuilder();
        for (String bom : boms) {
            String[] p = bom.split(":");
            if (p.length != 3) { errors.add("a BOM is group:artifact:version, got " + bom); continue; }
            Map<String, Version> managed = new LinkedHashMap<>();
            int before = errors.size();
            try {
                loadBomCoord(bom, fetchUrls, managed, errors);
            } catch (Exception e) {
                errors.add("could not load BOM " + bom + ": " + e.getMessage());
            }
            if (errors.size() > before) continue;
            StringBuilder body = new StringBuilder();
            body.append("// What ").append(bom).append(" manages.\n");
            body.append("// Written by `aeb mvn add`; run that again rather than edit this.\n");
            for (String ga : new TreeSet<>(managed.keySet())) {
                body.append("managed(\"").append(ga).append("\", \"")
                        .append(managed.get(ga)).append("\")\n");
            }
            Path f = Paths.get(into, p[0].replace('.', '/'), p[1], p[2], "managed.bom.ae");
            try {
                writeIfChanged(f, body.toString());
                if (report.length() > 0) report.append("\n");
                report.append(bom).append(" manages ").append(managed.size())
                        .append(" artifacts  (").append(f).append(")");
            } catch (Exception e) {
                errors.add("cannot write " + f + ": " + e.getMessage());
            }
        }
        return report.toString();
    }

    private static boolean isUnknownVersion(Version v) {
        // A version-less coord parses to VersionNumber.UNKNOWN (0.0.0), whose
        // toString() is empty. That's our "no version supplied" signal.
        String s = v.toString();
        return s == null || s.isEmpty() || "0.0.0".equals(s);
    }

    // ---- External BOM import ---------------------------------------------

    /**
     * Fetch an external BOM by G:A:V, read its dependencyManagement (with
     * parent inheritance and property interpolation), and put each managed
     * "group:artifact" -> Version into the override map so version-less coords
     * pick up the BOM's version.
     */
    private static void loadBomCoord(String coord, List<String> repoUrls,
                                     Map<String, Version> overrides,
                                     List<String> errors) throws Exception {
        String[] p = coord.split(":");
        if (p.length < 3) throw new IllegalArgumentException("BOM needs group:artifact:version");
        String xml = fetchPom(p[0], p[1], p[2], repoUrls);
        if (xml == null) throw new IllegalStateException("POM not found in any repository");
        parsePomInto(xml, repoUrls, overrides, errors);
    }

    /**
     * True when `path` holds an XML document (a Maven BOM POM) rather than an
     * aeb `.bom.ae`. Checked by first non-whitespace byte: '<' opens either the
     * XML prolog or the root element, and never begins an .ae line.
     */
    private static boolean looksLikeXml(Path path) throws Exception {
        String head = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
        for (int i = 0; i < head.length(); i++) {
            char c = head.charAt(i);
            if (Character.isWhitespace(c)) continue;
            return c == '<';
        }
        return false;   // empty file: nothing to XML-parse
    }

    /**
     * Scan an aeb `.bom.ae` for maven_bom(), maven_repo() and dep() lines and
     * append what they declare to the caller's lists. Text-only by design — the
     * greppable contract aeb's build files rest on (no Aether evaluation).
     *
     * A BOM coordinate and a dep coordinate are both "g:a:v" (exactly two
     * colons); a repo is a URL (contains "://"). Lines commented with // or #
     * are skipped, so a coordinate quoted inside a comment does not register.
     */
    private static void parseBomAeFile(Path file, List<String> boms,
                                       List<String> repoUrls, List<String> deps)
            throws Exception {
        Pattern quoted = Pattern.compile("\"([^\"]+)\"");
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            String trimmed = line.trim();
            if (trimmed.startsWith("//") || trimmed.startsWith("#")) continue;

            Matcher m = quoted.matcher(line);
            while (m.find()) {
                String val = m.group(1);
                long colons = val.chars().filter(c -> c == ':').count();
                if (line.contains("maven_bom(") && colons == 2) {
                    boms.add(val);
                } else if (line.contains("maven_repo(") && val.contains("://")) {
                    if (!repoUrls.contains(val)) repoUrls.add(val);
                } else if (line.contains("dep(") && colons == 2) {
                    deps.add(val);
                }
            }
        }
    }

    private static void loadBomFile(Path path, List<String> repoUrls,
                                    Map<String, Version> overrides,
                                    List<String> errors) throws Exception {
        String xml = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
        parsePomInto(xml, repoUrls, overrides, errors);
    }

    /**
     * Parse a POM's dependencyManagement into the override map, resolving:
     *  - parent <properties>/<dependencyManagement> (walked up the parent chain,
     *    fetched from the remote repos),
     *  - imported BOMs (scope=import, type=pom) recursively,
     *  - ${...} property interpolation using accumulated properties
     *    (including project.version / ${revision} style basics).
     *
     * Limitation: this is a pragmatic reader, not a full Maven model builder.
     * It handles the common external-BOM shape (concrete managed versions,
     * a parent that supplies properties/versions, and import-scope sub-BOMs).
     * Exotic profile-activated or plugin-injected properties are not modelled.
     */
    private static void parsePomInto(String xml, List<String> repoUrls,
                                     Map<String, Version> overrides,
                                     List<String> errors) throws Exception {
        // Accumulate properties across the parent chain, then interpolate.
        Map<String, String> properties = new LinkedHashMap<>();
        // Managed entries collected in "g:a" -> rawVersion form first, so later
        // (nearer, i.e. child) entries win and interpolation sees all props.
        Map<String, String> managed = new LinkedHashMap<>();
        List<String[]> imports = new ArrayList<>();   // [g,a,v] import-scope BOMs

        collectPom(xml, repoUrls, properties, managed, imports, errors, 0);

        // Recurse into imported BOMs (their managed versions are lower priority
        // than anything already collected in this POM chain).
        for (String[] imp : imports) {
            try {
                String impV = interpolate(imp[2], properties);
                String impXml = fetchPom(imp[0], imp[1], impV, repoUrls);
                if (impXml == null) {
                    errors.add("imported BOM " + imp[0] + ":" + imp[1] + ":" + impV
                            + " not found in any repository");
                } else {
                    Map<String, String> impProps = new LinkedHashMap<>();
                    Map<String, String> impManaged = new LinkedHashMap<>();
                    List<String[]> impImports = new ArrayList<>();
                    collectPom(impXml, repoUrls, impProps, impManaged, impImports, errors, 0);
                    for (Map.Entry<String, String> e : impManaged.entrySet()) {
                        managed.putIfAbsent(e.getKey(), e.getValue());
                    }
                    properties.putIfAbsent("__importscope__", "");
                    for (Map.Entry<String, String> e : impProps.entrySet()) {
                        properties.putIfAbsent(e.getKey(), e.getValue());
                    }
                }
            } catch (Exception e) {
                errors.add("could not import BOM " + imp[0] + ":" + imp[1] + ": " + e.getMessage());
            }
        }

        for (Map.Entry<String, String> e : managed.entrySet()) {
            String v = interpolate(e.getValue(), properties);
            if (v == null || v.isEmpty() || v.contains("${")) continue; // unresolved
            try {
                overrides.put(e.getKey(), Version.parse(v));
            } catch (Exception ignore) {
                // non-parseable version — skip quietly
            }
        }
    }

    /**
     * Read one POM's own properties + dependencyManagement, then walk up to its
     * parent (fetched from the repos) accumulating both. Child properties/managed
     * entries take precedence over parent (putIfAbsent as we ascend).
     */
    private static void collectPom(String xml, List<String> repoUrls,
                                   Map<String, String> properties,
                                   Map<String, String> managed,
                                   List<String[]> imports,
                                   List<String> errors,
                                   int depth) throws Exception {
        if (depth > 20) return; // guard against parent cycles
        Document doc = parseXml(xml);
        Element project = doc.getDocumentElement();

        // project.version / project.groupId (needed for ${project.version}).
        String projGroup = childText(project, "groupId");
        String projVersion = childText(project, "version");

        // <properties>
        Element propsEl = firstChild(project, "properties");
        if (propsEl != null) {
            NodeList kids = propsEl.getChildNodes();
            for (int i = 0; i < kids.getLength(); i++) {
                Node n = kids.item(i);
                if (n.getNodeType() == Node.ELEMENT_NODE) {
                    properties.putIfAbsent(n.getNodeName(), n.getTextContent().trim());
                }
            }
        }

        // <parent> supplies fallback group/version and is walked for its props.
        Element parentEl = firstChild(project, "parent");
        String parentGroup = null, parentArtifact = null, parentVersion = null;
        if (parentEl != null) {
            parentGroup = childText(parentEl, "groupId");
            parentArtifact = childText(parentEl, "artifactId");
            parentVersion = childText(parentEl, "version");
        }
        if (projGroup == null) projGroup = parentGroup;
        if (projVersion == null) projVersion = parentVersion;
        if (projVersion != null) {
            properties.putIfAbsent("project.version", projVersion);
            properties.putIfAbsent("project.groupId", projGroup == null ? "" : projGroup);
            // ${revision}/${sha1}/${changelist} flatten-plugin idioms often equal
            // project.version; only seed revision if not otherwise defined.
            properties.putIfAbsent("revision", projVersion);
        }

        // <dependencyManagement><dependencies>
        Element dm = firstChild(project, "dependencyManagement");
        if (dm != null) {
            Element depsEl = firstChild(dm, "dependencies");
            if (depsEl != null) {
                for (Element dep : childElements(depsEl, "dependency")) {
                    String g = childText(dep, "groupId");
                    String a = childText(dep, "artifactId");
                    String v = childText(dep, "version");
                    String scope = childText(dep, "scope");
                    String type = childText(dep, "type");
                    if (g == null || a == null) continue;
                    if ("import".equals(scope) && "pom".equals(type)) {
                        imports.add(new String[]{g, a, v == null ? "" : v});
                        continue;
                    }
                    if (v == null) continue;
                    managed.putIfAbsent(g + ":" + a, v);
                }
            }
        }

        // Ascend to parent for its properties/managed versions.
        if (parentGroup != null && parentArtifact != null && parentVersion != null) {
            try {
                String pv = interpolate(parentVersion, properties);
                String parentXml = fetchPom(parentGroup, parentArtifact, pv, repoUrls);
                if (parentXml == null) {
                    errors.add("parent POM " + parentGroup + ":" + parentArtifact + ":" + pv
                            + " not found in any repository");
                } else {
                    collectPom(parentXml, repoUrls, properties, managed, imports, errors, depth + 1);
                }
            } catch (Exception e) {
                errors.add("could not read parent POM "
                        + parentGroup + ":" + parentArtifact + ": " + e.getMessage());
            }
        }
    }

    /** Substitute ${prop} tokens using the accumulated property map (one pass, then a second for nesting). */
    private static String interpolate(String s, Map<String, String> props) {
        if (s == null) return null;
        for (int pass = 0; pass < 5 && s.contains("${"); pass++) {
            StringBuilder out = new StringBuilder();
            int i = 0;
            while (i < s.length()) {
                int open = s.indexOf("${", i);
                if (open < 0) { out.append(s.substring(i)); break; }
                out.append(s, i, open);
                int close = s.indexOf('}', open);
                if (close < 0) { out.append(s.substring(open)); break; }
                String key = s.substring(open + 2, close);
                String val = props.get(key);
                if (val == null) { out.append(s, open, close + 1); }
                else { out.append(val); }
                i = close + 1;
            }
            String next = out.toString();
            if (next.equals(s)) break;
            s = next;
        }
        return s;
    }

    // ---- Raw POM fetching -------------------------------------------------

    private static final HttpClient HTTP = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NORMAL)
            .build();

    /** Fetch a POM's XML from the first repo that has it; null if none do. */
    private static String fetchPom(String group, String artifact, String version,
                                   List<String> repoUrls) {
        String rel = group.replace('.', '/') + "/" + artifact + "/" + version
                + "/" + artifact + "-" + version + ".pom";
        for (String base : repoUrls) {
            String url = base.endsWith("/") ? base + rel : base + "/" + rel;
            try {
                if (url.startsWith("file:")) {
                    Path p = Paths.get(URI.create(url));
                    if (Files.exists(p)) return fromFirstTag(new String(Files.readAllBytes(p), StandardCharsets.UTF_8));
                    continue;
                }
                HttpRequest req = HttpRequest.newBuilder(URI.create(url)).GET().build();
                HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
                if (resp.statusCode() == 200) return fromFirstTag(resp.body());
            } catch (Exception e) {
                // try next repo
            }
        }
        return null;
    }

    /** A pom's text from its first '<': some are published with a byte-order mark in front. */
    private static String fromFirstTag(String xml) {
        int lt = xml.indexOf('<');
        return lt > 0 ? xml.substring(lt) : xml;
    }

    // ---- Tiny DOM helpers -------------------------------------------------

    private static Document parseXml(String xml) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(false);
        // Harden against XXE: no external entities/DTDs (BOM POMs never need them).
        f.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        f.setFeature("http://xml.org/sax/features/external-general-entities", false);
        f.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        return f.newDocumentBuilder().parse(new java.io.ByteArrayInputStream(xml.getBytes(StandardCharsets.UTF_8)));
    }

    private static Element firstChild(Element parent, String name) {
        for (Element e : childElements(parent, name)) return e;
        return null;
    }

    private static List<Element> childElements(Element parent, String name) {
        List<Element> out = new ArrayList<>();
        NodeList kids = parent.getChildNodes();
        for (int i = 0; i < kids.getLength(); i++) {
            Node n = kids.item(i);
            if (n.getNodeType() == Node.ELEMENT_NODE && n.getNodeName().equals(name)) {
                out.add((Element) n);
            }
        }
        return out;
    }

    private static String childText(Element parent, String name) {
        Element e = firstChild(parent, name);
        return e == null ? null : e.getTextContent().trim();
    }
}
