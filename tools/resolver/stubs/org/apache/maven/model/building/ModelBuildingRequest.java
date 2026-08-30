package org.apache.maven.model.building;

import java.io.File;
import java.util.Properties;

import org.apache.maven.model.resolution.ModelResolver;

public interface ModelBuildingRequest {
    int VALIDATION_LEVEL_MINIMAL = 0;

    ModelBuildingRequest setPomFile(File pomFile);
    ModelBuildingRequest setValidationLevel(int validationLevel);
    ModelBuildingRequest setProcessPlugins(boolean processPlugins);
    ModelBuildingRequest setSystemProperties(Properties systemProperties);
    ModelBuildingRequest setModelResolver(ModelResolver modelResolver);
}
