package com.databricks.trino.auth;

import io.trino.spi.Plugin;
import io.trino.spi.security.PasswordAuthenticatorFactory;

import java.util.List;

/**
 * Trino SPI Plugin entry point for Databricks token authentication.
 *
 * This plugin registers the DatabricksAuthenticatorFactory, which creates
 * authenticator instances that validate Databricks API tokens passed as
 * Trino passwords.
 */
public class DatabricksAuthenticatorPlugin implements Plugin
{
    @Override
    public Iterable<PasswordAuthenticatorFactory> getPasswordAuthenticatorFactories()
    {
        return List.of(new DatabricksAuthenticatorFactory());
    }
}
