package org.apache.maven.model.building;

import java.io.File;
import java.util.Properties;

import org.apache.maven.model.resolution.ModelResolver;

public class DefaultModelBuildingRequest implements ModelBuildingRequest {
    @Override public ModelBuildingRequest setPomFile(File pomFile) { return this; }
    @Override public ModelBuildingRequest setValidationLevel(int validationLevel) { return this; }
    @Override public ModelBuildingRequest setProcessPlugins(boolean processPlugins) { return this; }
    @Override public ModelBuildingRequest setSystemProperties(Properties systemProperties) { return this; }
    @Override public ModelBuildingRequest setModelResolver(ModelResolver modelResolver) { return this; }
}
