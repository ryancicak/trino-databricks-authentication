#!/bin/bash
# =============================================================================
# configure_auth.sh — Configure Trino for Databricks password authentication
#
# This script runs ON every node in the EMR cluster. It:
#   1. Creates password-authenticator.properties
#   2. Generates a self-signed TLS certificate (if not present)
#   3. Updates config.properties for HTTPS + PASSWORD auth
#   4. Sets up internal-communication.shared-secret (critical for multi-node!)
#   5. Restarts Trino
#
# IMPORTANT: Run this on ALL nodes (coordinator + workers) with the SAME
# shared secret. Use SSM send-command with all instance IDs for this.
#
# Usage:
#   configure_auth.sh <databricks-workspace-url> [shared-secret] [https-port]
#
# Example:
#   # On coordinator:
#   SECRET=$(openssl rand -base64 32)
#   bash configure_auth.sh https://myworkspace.cloud.databricks.com "$SECRET" 9443
#
#   # On each worker (SAME secret!):
#   bash configure_auth.sh https://myworkspace.cloud.databricks.com "$SECRET" 9443
# =============================================================================
set -euo pipefail

DATABRICKS_HOST="${1:?Usage: $0 <databricks-workspace-url> [shared-secret] [https-port]}"
SHARED_SECRET="${2:-$(openssl rand -base64 32)}"
HTTPS_PORT="${3:-9443}"

TRINO_CONF="/etc/trino/conf"
TRINO_CONF_DIST="/etc/trino/conf.dist"

echo "============================================"
echo "  Configure Trino Authentication"
echo "============================================"
echo "  Databricks Host:  $DATABRICKS_HOST"
echo "  HTTPS Port:       $HTTPS_PORT"
echo "  Shared Secret:    ${SHARED_SECRET:0:8}..."
echo "============================================"

# --- Determine if this is the coordinator ---
IS_COORDINATOR="false"
for CONF_DIR in "$TRINO_CONF" "$TRINO_CONF_DIST"; do
    if [ -f "$CONF_DIR/config.properties" ]; then
        if grep -q "^coordinator=true" "$CONF_DIR/config.properties" 2>/dev/null; then
            IS_COORDINATOR="true"
        fi
    fi
done
echo "[INFO] This node is coordinator: $IS_COORDINATOR"

# --- Create password-authenticator.properties (coordinator only) ---
if [ "$IS_COORDINATOR" = "true" ]; then
    for CONF_DIR in "$TRINO_CONF" "$TRINO_CONF_DIST"; do
        if [ -d "$CONF_DIR" ]; then
            sudo tee "$CONF_DIR/password-authenticator.properties" > /dev/null << EOF
password-authenticator.name=databricks
databricks.host=$DATABRICKS_HOST
databricks.cache-ttl-sec=300
databricks.cache-max=1000
EOF
            echo "[INFO] Created $CONF_DIR/password-authenticator.properties"
        fi
    done
fi

# --- Generate self-signed TLS certificate (coordinator only) ---
if [ "$IS_COORDINATOR" = "true" ]; then
    KEYSTORE_DIR="/etc/trino/ssl"
    KEYSTORE_PATH="$KEYSTORE_DIR/trino-keystore.jks"
    KEYSTORE_PASS="trino-$(openssl rand -hex 8)"

    if [ ! -f "$KEYSTORE_PATH" ]; then
        sudo mkdir -p "$KEYSTORE_DIR"
        HOSTNAME=$(hostname -f)

        # Find Java keytool
        TRINO_PID=$(pgrep -f "io.trino.server.TrinoServer" || true)
        if [ -n "$TRINO_PID" ]; then
            KEYTOOL="$(dirname "$(readlink -f /proc/$TRINO_PID/exe 2>/dev/null)")/keytool"
        fi
        KEYTOOL="${KEYTOOL:-keytool}"

        sudo "$KEYTOOL" -genkeypair \
            -alias trino \
            -keyalg RSA \
            -keysize 2048 \
            -validity 365 \
            -keystore "$KEYSTORE_PATH" \
            -storepass "$KEYSTORE_PASS" \
            -keypass "$KEYSTORE_PASS" \
            -dname "CN=$HOSTNAME, OU=Trino, O=TrinoDatabricksAuth, L=NA, ST=NA, C=US" \
            -ext "SAN=DNS:$HOSTNAME,DNS:localhost,IP:127.0.0.1" \
            -noprompt

        sudo chown trino:trino "$KEYSTORE_PATH" 2>/dev/null || true
        sudo chmod 600 "$KEYSTORE_PATH"
        echo "[INFO] Generated self-signed certificate: $KEYSTORE_PATH"
    else
        echo "[INFO] Keystore already exists: $KEYSTORE_PATH"
        # Read the existing password from config
        KEYSTORE_PASS=$(grep "http-server.https.keystore.key=" "$TRINO_CONF/config.properties" 2>/dev/null | cut -d= -f2 || echo "$KEYSTORE_PASS")
    fi
fi

# --- Update config.properties on ALL nodes ---
for CONF_DIR in "$TRINO_CONF" "$TRINO_CONF_DIST"; do
    CONFIG="$CONF_DIR/config.properties"
    [ -f "$CONFIG" ] || continue

    echo "[INFO] Updating $CONFIG"
    sudo cp "$CONFIG" "$CONFIG.bak.$(date +%s)"

    # Add shared secret (required on ALL nodes for internal JWT communication)
    if grep -q "^internal-communication.shared-secret" "$CONFIG"; then
        sudo sed -i "s|^internal-communication.shared-secret=.*|internal-communication.shared-secret=$SHARED_SECRET|" "$CONFIG"
    else
        echo "internal-communication.shared-secret=$SHARED_SECRET" | sudo tee -a "$CONFIG"
    fi

    # Coordinator-only settings
    if [ "$IS_COORDINATOR" = "true" ]; then
        # Enable PASSWORD auth
        if ! grep -q "^http-server.authentication.type" "$CONFIG"; then
            echo "http-server.authentication.type=PASSWORD" | sudo tee -a "$CONFIG"
        fi

        # Allow HTTP for internal communication (workers don't use HTTPS)
        if ! grep -q "^http-server.authentication.allow-insecure-over-http" "$CONFIG"; then
            echo "http-server.authentication.allow-insecure-over-http=true" | sudo tee -a "$CONFIG"
        fi

        # HTTPS settings
        if ! grep -q "^http-server.https.enabled" "$CONFIG"; then
            echo "http-server.https.enabled=true" | sudo tee -a "$CONFIG"
        fi

        if grep -q "^http-server.https.port" "$CONFIG"; then
            sudo sed -i "s|^http-server.https.port=.*|http-server.https.port=$HTTPS_PORT|" "$CONFIG"
        else
            echo "http-server.https.port=$HTTPS_PORT" | sudo tee -a "$CONFIG"
        fi

        if ! grep -q "^http-server.https.keystore.path" "$CONFIG"; then
            echo "http-server.https.keystore.path=$KEYSTORE_PATH" | sudo tee -a "$CONFIG"
            echo "http-server.https.keystore.key=$KEYSTORE_PASS" | sudo tee -a "$CONFIG"
        fi
    fi
done

# --- Restart Trino ---
echo "[INFO] Restarting Trino..."
TRINO_PID=$(pgrep -f "io.trino.server.TrinoServer" || true)
if [ -n "$TRINO_PID" ]; then
    sudo kill "$TRINO_PID"
    sleep 5
    pgrep -f "io.trino.server.TrinoServer" && sudo kill -9 "$(pgrep -f io.trino.server.TrinoServer)" && sleep 3 || true
fi

sudo -u trino /usr/lib/trino/bin/launcher start --etc-dir "$TRINO_CONF" 2>&1

echo ""
echo "============================================"
echo "  Configuration Complete"
echo "============================================"
echo ""
if [ "$IS_COORDINATOR" = "true" ]; then
    echo "  Coordinator configured with:"
    echo "    - HTTPS on port $HTTPS_PORT"
    echo "    - PASSWORD authentication enabled"
    echo "    - Databricks host: $DATABRICKS_HOST"
    echo ""
    echo "  Shared secret (use this for ALL workers):"
    echo "    $SHARED_SECRET"
else
    echo "  Worker configured with shared secret."
fi
echo ""
echo "  Allow 30-60s for Trino to restart."
