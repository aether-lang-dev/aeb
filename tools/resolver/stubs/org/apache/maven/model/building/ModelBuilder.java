package org.apache.maven.model.building;

public interface ModelBuilder {
    ModelBuildingResult build(ModelBuildingRequest request) throws ModelBuildingException;
}
