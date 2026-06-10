/*
 * aeb-resolve — Maven dependency resolver for aeb
 *
 * Resolves Maven coordinates (g:a:v) with transitive dependencies,
 * BOM version management, and custom repository support.
 * Prints resolved jar paths to stdout.
 *
 * Licensed under Apache-2.0 (uses Maven Resolver APIs)
 */
package aeb.maven;

import org.apache.maven.model.Model;
import org.apache.maven.model.building.*;
import org.apache.maven.model.resolution.ModelResolver;
import org.apache.maven.repository.internal.MavenRepositorySystemUtils;
import org.eclipse.aether.*;
import org.eclipse.aether.artifact.Artifact;
import org.eclipse.aether.artifact.DefaultArtifact;
import org.eclipse.aether.collection.CollectRequest;
import org.eclipse.aether.connector.basic.BasicRepositoryConnectorFactory;
import org.eclipse.aether.graph.Dependency;
import org.eclipse.aether.graph.DependencyFilter;
import org.eclipse.aether.impl.DefaultServiceLocator;
import org.eclipse.aether.repository.LocalRepository;
import org.eclipse.aether.repository.RemoteRepository;
import org.eclipse.aether.resolution.*;
import org.eclipse.aether.spi.connector.RepositoryConnectorFactory;
import org.eclipse.aether.spi.connector.transport.TransporterFactory;
import org.eclipse.aether.transport.http.HttpTransporterFactory;
import org.eclipse.aether.util.artifact.JavaScopes;
import org.eclipse.aether.util.filter.DependencyFilterUtils;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class MavenResolver {

    public static void main(String[] args) throws Exception {
        List<String> boms = new ArrayList<>();
        List<String> repos = new ArrayList<>();
        List<String> deps = new ArrayList<>();
        String outputMode = "classpath";
        String cacheDir = System.getProperty("user.home") + "/.aeb/repo";

        List<String> bomFiles = new ArrayList<>();

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--bom":      boms.add(args[++i]); break;
                case "--bom-file": bomFiles.add(args[++i]); break;
                case "--repo":     repos.add(args[++i]); break;
                case "--output":   outputMode = args[++i]; break;
                case "--cache":    cacheDir = args[++i]; break;
                default:
                    if (args[i].startsWith("-")) {
                        System.err.println("Unknown option: " + args[i]);
                        System.exit(1);
                    }
                    deps.add(args[i]);
            }
        }

        // Parse .bom.ae files for maven_bom(), maven_repo(), and dep() declarations
        for (String bomFile : bomFiles) {
            parseBomAeFile(Paths.get(bomFile), boms, repos, deps);
        }

        if (repos.isEmpty()) {
            repos.add("https://repo1.maven.org/maven2");
        }

        RepositorySystem repoSystem = newRepositorySystem();
        RepositorySystemSession session = newSession(repoSystem, cacheDir);

        List<RemoteRepository> remoteRepos = new ArrayList<>();
        for (int i = 0; i < repos.size(); i++) {
            remoteRepos.add(new RemoteRepository.Builder("repo" + i, "default", repos.get(i)).build());
        }

        // Resolve BOM managed dependencies for version lookup
        Map<String, String> managedVersions = new LinkedHashMap<>();
        for (String bom : boms) {
            loadBomVersions(bom, repoSystem, session, remoteRepos, managedVersions);
        }

        // Build dependency list, filling in versions from BOMs where needed
        List<Dependency> dependencies = new ArrayList<>();
        for (String dep : deps) {
            String[] parts = dep.split(":");
            String groupId = parts[0];
            String artifactId = parts[1];
            String version = parts.length > 2 ? parts[2] : null;

            if (version == null || version.isEmpty()) {
                String key = groupId + ":" + artifactId;
                version = managedVersions.get(key);
                if (version == null) {
                    System.err.println("warning: skipping " + key + " — no version and no BOM provides one");
                    continue;
                }
            }

            Artifact artifact = new DefaultArtifact(groupId, artifactId, "jar", version);
            dependencies.add(new Dependency(artifact, JavaScopes.COMPILE));
        }

        // Collect and resolve transitive dependencies
        CollectRequest collectRequest = new CollectRequest();
        collectRequest.setDependencies(dependencies);
        collectRequest.setRepositories(remoteRepos);

        // Add all managed versions from BOMs so transitive version resolution works.
        // When jackson-databind depends on jackson-core with ${jackson.version.core},
        // the managed version from the BOM fills in the missing version.
        List<Dependency> managedDeps = new ArrayList<>();
        for (Map.Entry<String, String> entry : managedVersions.entrySet()) {
            String[] keyParts = entry.getKey().split(":");
            Artifact managed = new DefaultArtifact(keyParts[0], keyParts[1], "jar", entry.getValue());
            managedDeps.add(new Dependency(managed, null));
        }
        collectRequest.setManagedDependencies(managedDeps);

        DependencyFilter filter = DependencyFilterUtils.classpathFilter(
            JavaScopes.COMPILE, JavaScopes.RUNTIME);

        DependencyRequest dependencyRequest = new DependencyRequest(collectRequest, filter);

        DependencyResult result;
        try {
            result = repoSystem.resolveDependencies(session, dependencyRequest);
        } catch (DependencyResolutionException e) {
            // Print what we got so far, even if some transitives failed
            result = e.getResult();
            System.err.println("warning: some dependencies could not be resolved: " + e.getMessage());
        }

        // SBOM mode: emit the resolved TRANSITIVE coordinate closure as one
        // "group:artifact:version" per line — the supply-chain veto (Tier B,
        // docs/build-veto-and-sandbox.md) feeds this to a CVE/banned-dep
        // scanner. The full closure is already computed for classpath; here we
        // emit the coordinates rather than the jar paths. Sorted + de-duped so
        // the output is stable (content-addressable, diffable).
        if ("sbom".equals(outputMode)) {
            java.util.TreeSet<String> coords = new java.util.TreeSet<>();
            for (ArtifactResult artifactResult : result.getArtifactResults()) {
                Artifact a = artifactResult.getArtifact();
                coords.add(a.getGroupId() + ":" + a.getArtifactId() + ":" + a.getVersion());
            }
            for (String c : coords) {
                System.out.println(c);
            }
            return;
        }

        List<String> jarPaths = new ArrayList<>();
        for (ArtifactResult artifactResult : result.getArtifactResults()) {
            File file = artifactResult.getArtifact().getFile();
            if (file != null && file.getName().endsWith(".jar")) {
                jarPaths.add(file.getAbsolutePath());
            }
        }

        if (jarPaths.isEmpty()) return;

        if ("classpath".equals(outputMode)) {
            System.out.println(String.join(":", jarPaths));
        } else {
            for (String path : jarPaths) {
                System.out.println(path);
            }
        }
    }

    /**
     * Load versions from a BOM (and its transitive BOM imports) into the
     * managedVersions map. Uses Maven Model Builder to properly resolve
     * property interpolation and parent inheritance.
     */
    private static void loadBomVersions(
            String bomCoord,
            RepositorySystem repoSystem,
            RepositorySystemSession session,
            List<RemoteRepository> remoteRepos,
            Map<String, String> managedVersions) throws Exception {

        String[] parts = bomCoord.split(":");
        Artifact bomArtifact = new DefaultArtifact(parts[0], parts[1], "pom", parts[2]);

        // Resolve the BOM POM file
        ArtifactRequest request = new ArtifactRequest(bomArtifact, remoteRepos, null);
        ArtifactResult bomResult = repoSystem.resolveArtifact(session, request);
        File bomFile = bomResult.getArtifact().getFile();

        // Use Maven Model Builder for proper property interpolation
        DefaultModelBuildingRequest buildingRequest = new DefaultModelBuildingRequest();
        buildingRequest.setPomFile(bomFile);
        buildingRequest.setValidationLevel(ModelBuildingRequest.VALIDATION_LEVEL_MINIMAL);
        buildingRequest.setProcessPlugins(false);
        buildingRequest.setSystemProperties(System.getProperties());

        // Set up model resolver for parent POM resolution
        buildingRequest.setModelResolver(new SimpleModelResolver(repoSystem, session, remoteRepos));

        DefaultModelBuilderFactory factory = new DefaultModelBuilderFactory();
        ModelBuilder modelBuilder = factory.newInstance();

        try {
            ModelBuildingResult buildResult = modelBuilder.build(buildingRequest);
            Model effectiveModel = buildResult.getEffectiveModel();

            if (effectiveModel.getDependencyManagement() != null) {
                for (org.apache.maven.model.Dependency dep :
                        effectiveModel.getDependencyManagement().getDependencies()) {

                    // Recurse into imported BOMs
                    if ("pom".equals(dep.getType()) && "import".equals(dep.getScope())) {
                        String subBom = dep.getGroupId() + ":" + dep.getArtifactId()
                            + ":" + dep.getVersion();
                        loadBomVersions(subBom, repoSystem, session, remoteRepos, managedVersions);
                        continue;
                    }

                    String key = dep.getGroupId() + ":" + dep.getArtifactId();
                    managedVersions.put(key, dep.getVersion());
                }
            }
        } catch (ModelBuildingException e) {
            System.err.println("warning: could not fully parse BOM " + bomCoord
                + ": " + e.getMessage());
        }
    }

    /**
     * Parse a .bom.ae file for maven_bom(), maven_repo(), and dep() declarations.
     * Extracts quoted strings from lines matching these patterns.
     * BOMs are g:a:v coordinates (contain two colons), repos are URLs (contain "://"),
     * deps are g:a:v coordinates on lines containing "dep(".
     */
    private static void parseBomAeFile(Path file, List<String> boms, List<String> repos, List<String> deps)
            throws IOException {
        Pattern quoted = Pattern.compile("\"([^\"]+)\"");
        for (String line : Files.readAllLines(file)) {
            String trimmed = line.trim();
            if (trimmed.startsWith("//") || trimmed.startsWith("#")) continue;

            Matcher m = quoted.matcher(line);
            while (m.find()) {
                String val = m.group(1);
                if (line.contains("maven_bom(") && val.chars().filter(c -> c == ':').count() == 2) {
                    boms.add(val);
                } else if (line.contains("maven_repo(") && val.contains("://")) {
                    repos.add(val);
                } else if (line.contains("dep(") && val.chars().filter(c -> c == ':').count() == 2) {
                    deps.add(val);
                }
            }
        }
    }

    private static RepositorySystem newRepositorySystem() {
        DefaultServiceLocator locator = MavenRepositorySystemUtils.newServiceLocator();
        locator.addService(RepositoryConnectorFactory.class, BasicRepositoryConnectorFactory.class);
        locator.addService(TransporterFactory.class, HttpTransporterFactory.class);
        return locator.getService(RepositorySystem.class);
    }

    private static RepositorySystemSession newSession(RepositorySystem system, String localRepoDir) {
        DefaultRepositorySystemSession session = MavenRepositorySystemUtils.newSession();
        LocalRepository localRepo = new LocalRepository(localRepoDir);
        session.setLocalRepositoryManager(system.newLocalRepositoryManager(session, localRepo));
        return session;
    }

    /**
     * Minimal ModelResolver that resolves parent POMs and imported BOMs
     * via the Aether RepositorySystem.
     */
    private static class SimpleModelResolver implements ModelResolver {
        private final RepositorySystem repoSystem;
        private final RepositorySystemSession session;
        private final List<RemoteRepository> repos;

        SimpleModelResolver(RepositorySystem repoSystem,
                           RepositorySystemSession session,
                           List<RemoteRepository> repos) {
            this.repoSystem = repoSystem;
            this.session = session;
            this.repos = repos;
        }

        @Override
        public ModelSource resolveModel(String groupId, String artifactId, String version)
                throws org.apache.maven.model.resolution.UnresolvableModelException {
            Artifact artifact = new DefaultArtifact(groupId, artifactId, "pom", version);
            ArtifactRequest request = new ArtifactRequest(artifact, repos, null);
            try {
                ArtifactResult result = repoSystem.resolveArtifact(session, request);
                return new FileModelSource(result.getArtifact().getFile());
            } catch (ArtifactResolutionException e) {
                throw new org.apache.maven.model.resolution.UnresolvableModelException(
                    e.getMessage(), groupId, artifactId, version, e);
            }
        }

        @Override
        public ModelSource resolveModel(org.apache.maven.model.Parent parent)
                throws org.apache.maven.model.resolution.UnresolvableModelException {
            return resolveModel(parent.getGroupId(), parent.getArtifactId(), parent.getVersion());
        }

        @Override
        public ModelSource resolveModel(org.apache.maven.model.Dependency dependency)
                throws org.apache.maven.model.resolution.UnresolvableModelException {
            return resolveModel(dependency.getGroupId(), dependency.getArtifactId(),
                              dependency.getVersion());
        }

        @Override
        public void addRepository(org.apache.maven.model.Repository repository) {
            // ignore — we use the repos passed at construction
        }

        @Override
        public void addRepository(org.apache.maven.model.Repository repository, boolean replace) {
            // ignore
        }

        @Override
        public ModelResolver newCopy() {
            return new SimpleModelResolver(repoSystem, session, repos);
        }
    }
}
