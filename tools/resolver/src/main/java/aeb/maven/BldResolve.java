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
 *   --output   classpath (default) | sbom
 *   --bom      G:A:V     import an external BOM's managed versions (may repeat)
 *   --bom-file <path>    import a local BOM POM's managed versions (may repeat)
 *   --repo     <url>     add a repository besides Maven Central (may repeat)
 *   --cache    <dir>     download directory (default XDG data / ~/.local/share)
 *   <coord>              group:artifact[:version] positional, transitively resolved
 *
 * IMPORTANT (stdout discipline): bld's DependencyResolver prints "Downloading:"
 * progress to stdout. lib/maven parses our stdout as the classpath, so during
 * all resolution/download we redirect System.out to System.err and only restore
 * it to print the final result line(s). Nothing but the result reaches stdout.
 *
 * Licensed under Apache-2.0.
 */
package aeb.maven;

import rife.bld.dependencies.ArtifactRetriever;
import rife.bld.dependencies.Dependency;
import rife.bld.dependencies.DependencyResolver;
import rife.bld.dependencies.DependencySet;
import rife.bld.dependencies.Repository;
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
                default:
                    if (args[i].startsWith("-")) {
                        // Unknown option: warn and continue (match old behavior's
                        // tolerance; old code exited, but the contract here asks
                        // for warn-and-continue).
                        System.err.println("warning: unknown option: " + args[i]);
                    } else {
                        deps.add(args[i]);
                    }
            }
        }

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
        var retriever = ArtifactRetriever.instance();

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
                    loadBomCoord(bom, fetchUrls, overrides);
                } catch (Exception e) {
                    System.err.println("warning: could not load BOM " + bom + " — " + e.getMessage());
                }
            }
            for (String bomFile : bomFiles) {
                try {
                    loadBomFile(Paths.get(bomFile), fetchUrls, overrides);
                } catch (Exception e) {
                    System.err.println("warning: could not load BOM file " + bomFile + " — " + e.getMessage());
                }
            }

            File out = new File(cacheDir);
            out.mkdirs();

            // Resolve the transitive closure (compile + runtime) of every
            // positional coord, honouring the seeded version overrides.
            DependencySet all = new DependencySet();
            for (String coord : deps) {
                try {
                    Dependency root = Dependency.parse(coord);
                    // If version-less and no override provides one, bld would try
                    // to resolve version 0.0.0 and fail; warn like the old shim.
                    if (isUnknownVersion(root.version()) && overrides.get(root.toArtifactString()) == null) {
                        System.err.println("warning: skipping " + root.toArtifactString()
                                + " — no version and no BOM provides one");
                        continue;
                    }
                    var resolver = new DependencyResolver(vr, retriever, repos, root);
                    // getAllDependencies applies overrideDependency to the root
                    // and every transitive dep, and pulls in each dep's own
                    // declared dependencyManagement/parent automatically.
                    DependencySet closure = resolver.getAllDependencies(Scope.compile, Scope.runtime);
                    all.addAll(closure);
                } catch (Exception e) {
                    System.err.println("warning: cannot resolve " + coord + " — " + e.getMessage());
                }
            }

            if ("sbom".equals(outputMode)) {
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
                        System.err.println("warning: cannot download " + d + " — " + e.getMessage());
                    }
                }
                result = String.join(":", jarPaths);
            }
        } finally {
            System.setOut(realOut);
        }

        // Only the final result reaches the real stdout.
        if ("classpath".equals(outputMode)) {
            if (!result.isEmpty()) System.out.println(result);
        } else {
            if (!result.isEmpty()) System.out.println(result);
        }
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
                                     Map<String, Version> overrides) throws Exception {
        String[] p = coord.split(":");
        if (p.length < 3) throw new IllegalArgumentException("BOM needs group:artifact:version");
        String xml = fetchPom(p[0], p[1], p[2], repoUrls);
        if (xml == null) throw new IllegalStateException("POM not found in any repository");
        parsePomInto(xml, repoUrls, overrides);
    }

    private static void loadBomFile(Path path, List<String> repoUrls,
                                    Map<String, Version> overrides) throws Exception {
        String xml = new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
        parsePomInto(xml, repoUrls, overrides);
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
                                     Map<String, Version> overrides) throws Exception {
        // Accumulate properties across the parent chain, then interpolate.
        Map<String, String> properties = new LinkedHashMap<>();
        // Managed entries collected in "g:a" -> rawVersion form first, so later
        // (nearer, i.e. child) entries win and interpolation sees all props.
        Map<String, String> managed = new LinkedHashMap<>();
        List<String[]> imports = new ArrayList<>();   // [g,a,v] import-scope BOMs

        collectPom(xml, repoUrls, properties, managed, imports, 0);

        // Recurse into imported BOMs (their managed versions are lower priority
        // than anything already collected in this POM chain).
        for (String[] imp : imports) {
            try {
                String impV = interpolate(imp[2], properties);
                String impXml = fetchPom(imp[0], imp[1], impV, repoUrls);
                if (impXml != null) {
                    Map<String, String> impProps = new LinkedHashMap<>();
                    Map<String, String> impManaged = new LinkedHashMap<>();
                    List<String[]> impImports = new ArrayList<>();
                    collectPom(impXml, repoUrls, impProps, impManaged, impImports, 0);
                    for (Map.Entry<String, String> e : impManaged.entrySet()) {
                        managed.putIfAbsent(e.getKey(), e.getValue());
                    }
                    properties.putIfAbsent("__importscope__", "");
                    for (Map.Entry<String, String> e : impProps.entrySet()) {
                        properties.putIfAbsent(e.getKey(), e.getValue());
                    }
                }
            } catch (Exception e) {
                System.err.println("warning: could not import sub-BOM "
                        + imp[0] + ":" + imp[1] + " — " + e.getMessage());
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
                if (parentXml != null) {
                    collectPom(parentXml, repoUrls, properties, managed, imports, depth + 1);
                }
            } catch (Exception e) {
                System.err.println("warning: could not read parent POM "
                        + parentGroup + ":" + parentArtifact + " — " + e.getMessage());
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
                    if (Files.exists(p)) return new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
                    continue;
                }
                HttpRequest req = HttpRequest.newBuilder(URI.create(url)).GET().build();
                HttpResponse<String> resp = HTTP.send(req, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
                if (resp.statusCode() == 200) return resp.body();
            } catch (Exception e) {
                // try next repo
            }
        }
        return null;
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
