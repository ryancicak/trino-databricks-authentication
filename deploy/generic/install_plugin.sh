#!/bin/bash
# =============================================================================
# install_plugin.sh — Install the pre-built plugin on any Trino server
#
# For non-EMR deployments (Kubernetes, Docker, bare metal).
# Assumes the plugin JAR is already built.
#
# Usage:
#   install_plugin.sh <path-to-jar> [trino-plugin-dir]
#
# Example:
#   bash install_plugin.sh plugin/target/trino-databricks-auth-1.0.0.jar
#   bash install_plugin.sh plugin/target/trino-databricks-auth-1.0.0.jar /opt/trino/plugin
# =============================================================================
set -euo pipefail

JAR_PATH="${1:?Usage: $0 <path-to-jar> [trino-plugin-dir]}"
TRINO_PLUGIN_DIR="${2:-/usr/lib/trino/plugin}"
PLUGIN_DIR_NAME="databricks-auth"

INSTALL_DIR="$TRINO_PLUGIN_DIR/$PLUGIN_DIR_NAME"

echo "============================================"
echo "  Install Trino Databricks Auth Plugin"
echo "============================================"

if [ ! -f "$JAR_PATH" ]; then
    echo "[ERROR] JAR not found: $JAR_PATH"
    echo "Build it first: cd plugin && mvn clean package"
    exit 1
fi

echo "[INFO] Installing $JAR_PATH to $INSTALL_DIR/"

sudo mkdir -p "$INSTALL_DIR"
sudo cp "$JAR_PATH" "$INSTALL_DIR/"
sudo chown -R trino:trino "$INSTALL_DIR" 2>/dev/null || true

echo "[INFO] Installed:"
ls -la "$INSTALL_DIR/"

echo ""
echo "============================================"
echo "  Plugin Installed"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Create /etc/trino/conf/password-authenticator.properties:"
echo ""
echo "     password-authenticator.name=databricks"
echo "     databricks.host=https://your-workspace.cloud.databricks.com"
echo "     databricks.cache-ttl-sec=300"
echo "     databricks.cache-max=1000"
echo ""
echo "  2. Add to /etc/trino/conf/config.properties:"
echo ""
echo "     http-server.authentication.type=PASSWORD"
echo "     internal-communication.shared-secret=<generate-with-openssl-rand-base64-32>"
echo ""
echo "  3. Restart Trino"
echo ""
echo "See config/ directory for templates."
