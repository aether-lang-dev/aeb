package org.eclipse.aether;

import org.eclipse.aether.repository.LocalRepositoryManager;

public class DefaultRepositorySystemSession implements RepositorySystemSession {
    public DefaultRepositorySystemSession setLocalRepositoryManager(LocalRepositoryManager localRepositoryManager) {
        return this;
    }
}
