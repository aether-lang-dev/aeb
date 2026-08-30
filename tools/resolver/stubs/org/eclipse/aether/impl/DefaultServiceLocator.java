package org.eclipse.aether.impl;

public class DefaultServiceLocator {
    public <T> DefaultServiceLocator addService(Class<T> type, Class<? extends T> impl) {
        return this;
    }

    public <T> T getService(Class<T> type) { return null; }
}
