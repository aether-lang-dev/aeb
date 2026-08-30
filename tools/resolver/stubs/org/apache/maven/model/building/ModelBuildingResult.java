package org.apache.maven.model.building;

import org.apache.maven.model.Model;

public interface ModelBuildingResult {
    Model getEffectiveModel();
}
