package org.apache.maven.model.resolution;

public class UnresolvableModelException extends Exception {
    private static final long serialVersionUID = 1L;
    public UnresolvableModelException(String message, String groupId, String artifactId,
                                      String version, Throwable cause) {
    }
}
