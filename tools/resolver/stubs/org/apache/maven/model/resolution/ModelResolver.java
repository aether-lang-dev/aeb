package org.apache.maven.model.resolution;

import org.apache.maven.model.Dependency;
import org.apache.maven.model.Parent;
import org.apache.maven.model.Repository;
import org.apache.maven.model.building.ModelSource;

public interface ModelResolver {
    ModelSource resolveModel(String groupId, String artifactId, String version)
            throws UnresolvableModelException;

    ModelSource resolveModel(Parent parent) throws UnresolvableModelException;

    ModelSource resolveModel(Dependency dependency) throws UnresolvableModelException;

    void addRepository(Repository repository) throws InvalidRepositoryException;

    void addRepository(Repository repository, boolean replace) throws InvalidRepositoryException;

    ModelResolver newCopy();
}
