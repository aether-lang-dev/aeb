package org.eclipse.aether.artifact;

import java.io.File;

public class DefaultArtifact implements Artifact {
    public DefaultArtifact(String groupId, String artifactId, String extension, String version) {
    }

    @Override public String getGroupId() { return null; }
    @Override public String getArtifactId() { return null; }
    @Override public String getVersion() { return null; }
    @Override public File getFile() { return null; }
}
