package com.databricks.trino.auth;

import io.trino.spi.security.PasswordAuthenticator;
import io.trino.spi.security.PasswordAuthenticatorFactory;

import java.util.Map;

/**
 * Factory that creates DatabricksPasswordAuthenticator instances.
 *
 * Configuration properties (set in password-authenticator.properties):
 *   - databricks.host:          Databricks workspace URL (e.g., https://myworkspace.cloud.databricks.com)
 *   - databricks.cache-ttl-sec: How long to cache validated tokens (default: 300 seconds)
 *   - databricks.cache-max:     Max cached tokens (default: 1000)
 */
public class DatabricksAuthenticatorFactory implements PasswordAuthenticatorFactory
{
    private static final String NAME = "databricks";

    @Override
    public String getName()
    {
        return NAME;
    }

    @Override
    public PasswordAuthenticator create(Map<String, String> config)
    {
        String databricksHost = config.get("databricks.host");
        if (databricksHost == null || databricksHost.isEmpty()) {
            throw new IllegalArgumentException("databricks.host must be set in password-authenticator.properties");
        }

        // Remove trailing slash if present
        if (databricksHost.endsWith("/")) {
            databricksHost = databricksHost.substring(0, databricksHost.length() - 1);
        }

        long cacheTtlSec = Long.parseLong(config.getOrDefault("databricks.cache-ttl-sec", "300"));
        long cacheMax = Long.parseLong(config.getOrDefault("databricks.cache-max", "1000"));

        return new DatabricksPasswordAuthenticator(databricksHost, cacheTtlSec, cacheMax);
    }
}
