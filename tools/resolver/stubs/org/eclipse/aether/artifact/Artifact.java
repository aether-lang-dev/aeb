package org.eclipse.aether.artifact;

import java.io.File;

public interface Artifact {
    String getGroupId();
    String getArtifactId();
    String getVersion();
    File getFile();
}
