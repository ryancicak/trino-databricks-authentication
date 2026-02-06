package com.databricks.trino.auth;

import io.trino.spi.security.AccessDeniedException;
import io.trino.spi.security.BasicPrincipal;
import io.trino.spi.security.PasswordAuthenticator;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.Principal;
import java.time.Duration;
import java.util.concurrent.ConcurrentHashMap;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Validates Databricks API tokens passed as Trino passwords.
 * 
 * Zero external dependencies: uses only JDK standard library + Trino SPI.
 * No Guava, no Jackson - simple ConcurrentHashMap cache and regex JSON parsing.
 *
 * Flow:
 *   1. User connects to Trino with user="alice@company.com" password="dapi..."
 *   2. This authenticator calls Databricks SCIM API: GET /api/2.0/preview/scim/v2/Me
 *      with Authorization: Bearer <token>
 *   3. Databricks returns the token owner's identity (email)
 *   4. If the email matches the provided username, authentication succeeds
 *   5. The verified email becomes the Trino principal (used for access control & audit)
 */
public class DatabricksPasswordAuthenticator implements PasswordAuthenticator
{
    private static final Logger LOG = Logger.getLogger(DatabricksPasswordAuthenticator.class.getName());

    // Regex to extract "userName" from SCIM JSON response
    private static final Pattern USERNAME_PATTERN = Pattern.compile("\"userName\"\\s*:\\s*\"([^\"]+)\"");

    private final String databricksHost;
    private final HttpClient httpClient;
    private final long cacheTtlMs;
    private final long cacheMax;

    /**
     * Simple cache: token -> CacheEntry(email, timestamp)
     * No Guava needed - just a ConcurrentHashMap with TTL check.
     */
    private final ConcurrentHashMap<String, CacheEntry> tokenCache = new ConcurrentHashMap<>();

    private static class CacheEntry
    {
        final String email;
        final long timestampMs;

        CacheEntry(String email, long timestampMs)
        {
            this.email = email;
            this.timestampMs = timestampMs;
        }
    }

    public DatabricksPasswordAuthenticator(String databricksHost, long cacheTtlSec, long cacheMax)
    {
        this.databricksHost = databricksHost;
        this.cacheTtlMs = cacheTtlSec * 1000;
        this.cacheMax = cacheMax;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    @Override
    public Principal createAuthenticatedPrincipal(String user, String password)
    {
        String token = password;

        if (token == null || token.isEmpty()) {
            throw new AccessDeniedException("No Databricks token provided");
        }

        try {
            String verifiedEmail = getCachedOrValidate(token);

            if (!verifiedEmail.equalsIgnoreCase(user)) {
                LOG.warning(String.format(
                        "Identity mismatch: user claimed '%s' but token belongs to '%s'",
                        user, verifiedEmail));
                throw new AccessDeniedException(String.format(
                        "Identity mismatch: you authenticated as '%s' but claimed to be '%s'",
                        verifiedEmail, user));
            }

            LOG.info(String.format("Authenticated Databricks user: %s", verifiedEmail));
            return new BasicPrincipal(verifiedEmail);
        }
        catch (AccessDeniedException e) {
            throw e;
        }
        catch (Exception e) {
            LOG.log(Level.SEVERE, "Token validation failed", e);
            throw new AccessDeniedException("Authentication failed: " + e.getMessage());
        }
    }

    /**
     * Checks cache first, validates with Databricks if not cached or expired.
     */
    private String getCachedOrValidate(String token) throws IOException, InterruptedException
    {
        long now = System.currentTimeMillis();

        CacheEntry entry = tokenCache.get(token);
        if (entry != null && (now - entry.timestampMs) < cacheTtlMs) {
            return entry.email;
        }

        // Validate with Databricks
        String email = validateTokenWithDatabricks(token);

        // Evict oldest entries if cache is full
        if (tokenCache.size() >= cacheMax) {
            // Simple eviction: remove ~10% of entries (oldest first)
            long cutoff = now - cacheTtlMs;
            tokenCache.entrySet().removeIf(e -> e.getValue().timestampMs < cutoff);
            // If still too full, just clear it
            if (tokenCache.size() >= cacheMax) {
                tokenCache.clear();
            }
        }

        tokenCache.put(token, new CacheEntry(email, now));
        return email;
    }

    /**
     * Calls Databricks SCIM API to validate a token and return the owner's email.
     *
     * GET /api/2.0/preview/scim/v2/Me
     * Authorization: Bearer <token>
     *
     * Response:
     * {
     *   "userName": "alice@company.com",
     *   "emails": [{"value": "alice@company.com", "primary": true}],
     *   ...
     * }
     */
    private String validateTokenWithDatabricks(String token) throws IOException, InterruptedException
    {
        String url = databricksHost + "/api/2.0/preview/scim/v2/Me";

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .header("Authorization", "Bearer " + token)
                .header("Accept", "application/json")
                .timeout(Duration.ofSeconds(10))
                .GET()
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());

        if (response.statusCode() == 401 || response.statusCode() == 403) {
            throw new AccessDeniedException("Invalid Databricks token (HTTP " + response.statusCode() + ")");
        }

        if (response.statusCode() != 200) {
            throw new IOException("Databricks API returned HTTP " + response.statusCode() + ": " + response.body());
        }

        // Parse userName from JSON using regex (no Jackson dependency needed)
        String body = response.body();
        Matcher matcher = USERNAME_PATTERN.matcher(body);

        String userName = null;
        if (matcher.find()) {
            userName = matcher.group(1);
        }

        if (userName == null || userName.isEmpty()) {
            throw new AccessDeniedException("Could not determine user identity from Databricks token");
        }

        LOG.info(String.format("Token validated: belongs to %s", userName));
        return userName;
    }
}
