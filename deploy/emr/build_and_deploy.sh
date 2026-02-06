#!/bin/bash
# =============================================================================
# build_and_deploy.sh — Build and deploy the Databricks auth plugin on EMR
#
# This script runs ON the EMR cluster (via EMR Step or SSM). It:
#   1. Installs Maven (if not present)
#   2. Detects EMR's Trino SPI JAR and Java version
#   3. Builds the plugin against the exact SPI
#   4. Deploys to Trino's plugin directory
#   5. Restarts Trino
#
# Usage:
#   # As an EMR Step:
#   aws s3 cp build_and_deploy.sh s3://your-bucket/build_and_deploy.sh
#   aws s3 cp plugin-source.tar.gz s3://your-bucket/plugin-source.tar.gz
#   aws emr add-steps --cluster-id j-XXXXX --steps \
#     "Type=CUSTOM_JAR,Name=DeployAuth,Jar=s3://us-west-2.elasticmapreduce/libs/script-runner/script-runner.jar,\
#      Args=[s3://your-bucket/build_and_deploy.sh,s3://your-bucket/plugin-source.tar.gz],ActionOnFailure=CONTINUE"
#
#   # Or via SSM Run Command:
#   aws ssm send-command --instance-ids i-XXXXX --document-name AWS-RunShellScript \
#     --parameters '{"commands":["bash /tmp/build_and_deploy.sh /tmp/plugin-source.tar.gz"]}'
# =============================================================================
set -euo pipefail

PLUGIN_SOURCE_ARCHIVE="${1:-}"
PLUGIN_DIR_NAME="databricks-auth"

echo "============================================"
echo "  Trino Databricks Auth — Build & Deploy"
echo "============================================"

# --- Detect Java ---
# EMR ships multiple Java versions. Find the one Trino actually uses.
TRINO_PID=$(pgrep -f "io.trino.server.TrinoServer" || true)
if [ -n "$TRINO_PID" ]; then
    TRINO_JAVA=$(readlink -f /proc/"$TRINO_PID"/exe 2>/dev/null || true)
    if [ -n "$TRINO_JAVA" ]; then
        export JAVA_HOME=$(dirname "$(dirname "$TRINO_JAVA")")
        echo "[INFO] Detected Trino's Java: $JAVA_HOME"
    fi
fi

# Fallback: find the newest Java
if [ -z "${JAVA_HOME:-}" ] || [ ! -d "$JAVA_HOME" ]; then
    JAVA_HOME=$(ls -d /usr/lib/jvm/java-*-amazon-corretto* 2>/dev/null | sort -V | tail -1)
    echo "[INFO] Fallback Java: $JAVA_HOME"
fi
export PATH="$JAVA_HOME/bin:$PATH"
echo "[INFO] Java version: $(java -version 2>&1 | head -1)"

# --- Install Maven ---
MAVEN_DIR="/tmp/apache-maven-3.9.6"
if [ ! -d "$MAVEN_DIR" ]; then
    echo "[INFO] Installing Maven..."
    cd /tmp
    wget -q https://archive.apache.org/dist/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.tar.gz
    tar xzf apache-maven-3.9.6-bin.tar.gz
fi
export PATH="$MAVEN_DIR/bin:$PATH"

# --- Find Trino SPI JAR ---
TRINO_SPI_JAR=$(ls /usr/lib/trino/lib/trino-spi-*.jar 2>/dev/null | head -1)
if [ -z "$TRINO_SPI_JAR" ]; then
    echo "[ERROR] Cannot find trino-spi JAR in /usr/lib/trino/lib/"
    exit 1
fi

# Extract version from filename (e.g., trino-spi-476-amzn-1.jar -> 476-amzn-1)
SPI_VERSION=$(basename "$TRINO_SPI_JAR" | sed 's/trino-spi-//' | sed 's/\.jar//')
echo "[INFO] Found Trino SPI: $TRINO_SPI_JAR (version: $SPI_VERSION)"

# Install into local Maven repo
mvn install:install-file \
    -Dfile="$TRINO_SPI_JAR" \
    -DgroupId=io.trino \
    -DartifactId=trino-spi \
    -Dversion="$SPI_VERSION" \
    -Dpackaging=jar \
    -DgeneratePom=true -q

# --- Prepare source ---
BUILD_DIR="/tmp/trino-auth-build"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

if [ -n "$PLUGIN_SOURCE_ARCHIVE" ]; then
    echo "[INFO] Extracting source from: $PLUGIN_SOURCE_ARCHIVE"
    # If it's an S3 path, download first
    if [[ "$PLUGIN_SOURCE_ARCHIVE" == s3://* ]]; then
        aws s3 cp "$PLUGIN_SOURCE_ARCHIVE" /tmp/plugin-source.tar.gz
        PLUGIN_SOURCE_ARCHIVE="/tmp/plugin-source.tar.gz"
    fi
    tar xzf "$PLUGIN_SOURCE_ARCHIVE" -C "$BUILD_DIR" --strip-components=1 2>/dev/null || \
    tar xzf "$PLUGIN_SOURCE_ARCHIVE" -C "$BUILD_DIR" 2>/dev/null
else
    echo "[ERROR] No source archive provided."
    echo "Usage: $0 <path-or-s3-uri-to-plugin-source.tar.gz>"
    exit 1
fi

# --- Override pom.xml to use detected SPI version ---
cd "$BUILD_DIR"
if [ -d "plugin" ]; then
    cd plugin
fi

cat > pom.xml << POMEOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.databricks.trino</groupId>
    <artifactId>trino-databricks-auth</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>
    <properties>
        <maven.compiler.source>21</maven.compiler.source>
        <maven.compiler.target>21</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>
    <dependencies>
        <dependency>
            <groupId>io.trino</groupId>
            <artifactId>trino-spi</artifactId>
            <version>$SPI_VERSION</version>
            <scope>provided</scope>
        </dependency>
    </dependencies>
</project>
POMEOF

echo "[INFO] Building with SPI version: $SPI_VERSION"

# --- Build ---
mvn clean package -q 2>&1
JAR_PATH="target/trino-databricks-auth-1.0.0.jar"
if [ ! -f "$JAR_PATH" ]; then
    echo "[ERROR] Build failed — JAR not found"
    exit 1
fi
echo "[INFO] Build successful: $(ls -lh "$JAR_PATH")"

# --- Deploy ---
PLUGIN_INSTALL_DIR="/usr/lib/trino/plugin/$PLUGIN_DIR_NAME"
sudo mkdir -p "$PLUGIN_INSTALL_DIR"
sudo cp "$JAR_PATH" "$PLUGIN_INSTALL_DIR/"
sudo chown -R trino:trino "$PLUGIN_INSTALL_DIR" 2>/dev/null || true
echo "[INFO] Deployed to: $PLUGIN_INSTALL_DIR/"
ls -la "$PLUGIN_INSTALL_DIR/"

# --- Restart Trino ---
echo "[INFO] Restarting Trino..."
TRINO_PID=$(pgrep -f "io.trino.server.TrinoServer" || true)
if [ -n "$TRINO_PID" ]; then
    sudo kill "$TRINO_PID"
    sleep 5
    # Force kill if still running
    pgrep -f "io.trino.server.TrinoServer" && sudo kill -9 "$(pgrep -f io.trino.server.TrinoServer)" && sleep 3 || true
fi

sudo -u trino /usr/lib/trino/bin/launcher start --etc-dir /etc/trino/conf 2>&1
echo "[INFO] Trino restarting. Allow 30-60s for full startup."

echo ""
echo "============================================"
echo "  Build & Deploy Complete"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Wait ~60s for Trino to start"
echo "  2. Run: deploy/emr/configure_auth.sh to set up authentication"
echo "  3. Test: curl -sk https://localhost:9443/v1/info"
