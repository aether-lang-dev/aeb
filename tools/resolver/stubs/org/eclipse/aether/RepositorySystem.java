package org.eclipse.aether;

import org.eclipse.aether.repository.LocalRepository;
import org.eclipse.aether.repository.LocalRepositoryManager;
import org.eclipse.aether.resolution.ArtifactRequest;
import org.eclipse.aether.resolution.ArtifactResult;
import org.eclipse.aether.resolution.ArtifactResolutionException;

public interface RepositorySystem {
    ArtifactResult resolveArtifact(RepositorySystemSession session, ArtifactRequest request)
            throws ArtifactResolutionException;

    LocalRepositoryManager newLocalRepositoryManager(RepositorySystemSession session, LocalRepository localRepository);
}
