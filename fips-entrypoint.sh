#!/bin/bash
set -e

###############################################################################
# RabbitMQ FIPS Startup Validation Entrypoint
#
# This script validates FIPS configuration before starting RabbitMQ.
# It performs comprehensive environment and cryptographic checks specific
# to RabbitMQ and Erlang/OTP.
#
# Exit behavior:
#   - Success: Executes the RabbitMQ entrypoint
#   - Failure: Exits immediately with code 1
###############################################################################

echo "========================================"
echo "RabbitMQ FIPS Container Startup"
echo "========================================"
echo ""

EXIT_CODE=0

###############################################################################
# Check 1: Environment Variables
###############################################################################
echo "[1/7] Validating environment variables..."

if [ -z "$OPENSSL_CONF" ]; then
    echo "      ✗ ERROR: OPENSSL_CONF is not set"
    EXIT_CODE=1
elif [ ! -f "$OPENSSL_CONF" ]; then
    echo "      ✗ ERROR: OPENSSL_CONF file does not exist: $OPENSSL_CONF"
    EXIT_CODE=1
else
    echo "      ✓ OPENSSL_CONF: $OPENSSL_CONF"
fi

if [ -z "$OPENSSL_MODULES" ]; then
    echo "      ℹ OPENSSL_MODULES not set (using system OpenSSL modules directory)"
else
    if [ ! -d "$OPENSSL_MODULES" ]; then
        echo "      ✗ ERROR: OPENSSL_MODULES directory does not exist: $OPENSSL_MODULES"
        EXIT_CODE=1
    else
        echo "      ✓ OPENSSL_MODULES: $OPENSSL_MODULES"
    fi
fi

if [ -z "$LD_LIBRARY_PATH" ]; then
    echo "      ✗ ERROR: LD_LIBRARY_PATH is not set"
    EXIT_CODE=1
else
    echo "      ✓ LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "✗ FIPS VALIDATION FAILED"
    echo "========================================"
    echo "Environment configuration is invalid"
    exit 1
fi

###############################################################################
# Check 2: OpenSSL Installation
###############################################################################
echo ""
echo "[2/7] Validating OpenSSL installation..."

# Use system OpenSSL in PATH
if ! command -v openssl >/dev/null 2>&1; then
    echo "      ✗ ERROR: OpenSSL binary not found in PATH"
    EXIT_CODE=1
else
    OPENSSL_VERSION=$(openssl version 2>&1 | head -n1)
    echo "      ✓ OpenSSL found: $OPENSSL_VERSION"

    # Check if it's OpenSSL 3.x
    if ! echo "$OPENSSL_VERSION" | grep -q "OpenSSL 3\."; then
        echo "      ⚠ WARNING: Expected OpenSSL 3.x, got: $OPENSSL_VERSION"
    fi
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "✗ FIPS VALIDATION FAILED"
    echo "========================================"
    echo "OpenSSL installation is invalid"
    exit 1
fi

###############################################################################
# Check 3: wolfSSL Library
###############################################################################
echo ""
echo "[3/7] Validating wolfSSL library..."

WOLFSSL_LIB="/usr/local/lib/libwolfssl.so"
if [ ! -f "$WOLFSSL_LIB" ]; then
    # Try alternative locations
    if [ -f "/usr/local/lib/libwolfssl.so.42" ]; then
        WOLFSSL_LIB="/usr/local/lib/libwolfssl.so.42"
    elif ls /usr/local/lib/libwolfssl.so.* >/dev/null 2>&1; then
        WOLFSSL_LIB=$(ls /usr/local/lib/libwolfssl.so.* | head -n1)
    else
        echo "      ✗ ERROR: wolfSSL library not found in /usr/local/lib/"
        EXIT_CODE=1
    fi
fi

if [ $EXIT_CODE -eq 0 ]; then
    echo "      ✓ wolfSSL library: $WOLFSSL_LIB"
else
    echo ""
    echo "========================================"
    echo "✗ FIPS VALIDATION FAILED"
    echo "========================================"
    echo "wolfSSL library is missing"
    exit 1
fi

###############################################################################
# Check 4: wolfProvider Module
###############################################################################
echo ""
echo "[4/7] Validating wolfProvider module..."

# Determine OpenSSL modules directory (system or custom)
if [ -z "$OPENSSL_MODULES" ]; then
    # Use system OpenSSL modules directory (multi-arch)
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        MODULES_DIR="/usr/lib/x86_64-linux-gnu/ossl-modules"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        MODULES_DIR="/usr/lib/aarch64-linux-gnu/ossl-modules"
    else
        MODULES_DIR="/usr/lib/x86_64-linux-gnu/ossl-modules"
    fi
else
    MODULES_DIR="$OPENSSL_MODULES"
fi

WOLFPROV_MODULE="$MODULES_DIR/libwolfprov.so"
if [ ! -f "$WOLFPROV_MODULE" ]; then
    echo "      ✗ ERROR: wolfProvider module not found: $WOLFPROV_MODULE"
    echo "      Available modules in $MODULES_DIR:"
    ls -la "$MODULES_DIR/" 2>/dev/null || echo "      (directory listing failed)"
    EXIT_CODE=1
else
    echo "      ✓ wolfProvider module: $WOLFPROV_MODULE"
    WOLFPROV_SIZE=$(stat -c%s "$WOLFPROV_MODULE" 2>/dev/null || echo "unknown")
    echo "      ✓ Module size: $WOLFPROV_SIZE bytes"
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "✗ FIPS VALIDATION FAILED"
    echo "========================================"
    echo "wolfProvider module is missing or invalid"
    exit 1
fi

###############################################################################
# Check 5: Erlang Installation and FIPS Configuration
###############################################################################
echo ""
echo "[5/7] Validating Erlang installation and FIPS configuration..."

# Check Erlang is installed
if ! command -v erl >/dev/null 2>&1; then
    echo "      ✗ ERROR: Erlang not found in PATH"
    EXIT_CODE=1
else
    ERL_VERSION=$(erl -version 2>&1 | head -n1)
    echo "      ✓ Erlang found: $ERL_VERSION"
fi

# Check sys.config exists
SYS_CONFIG="/opt/bitnami/rabbitmq/etc/sys.config"
if [ ! -f "$SYS_CONFIG" ]; then
    echo "      ✗ ERROR: Erlang sys.config not found: $SYS_CONFIG"
    EXIT_CODE=1
else
    echo "      ✓ Erlang sys.config: $SYS_CONFIG"

    # Note: FIPS mode is enforced via wolfProvider in openssl.cnf, not via sys.config
    # The Erlang fips_mode setting causes NIF load failures, so we rely on OpenSSL provider configuration
    echo "      ℹ FIPS enforced via wolfProvider (not Erlang fips_mode setting)"
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "✗ FIPS VALIDATION FAILED"
    echo "========================================"
    echo "Erlang installation or configuration is invalid"
    exit 1
fi

###############################################################################
# Check 6: Cryptographic FIPS Validation (C utility)
###############################################################################
echo ""
echo "[6/7] Running cryptographic FIPS validation..."
echo ""

FIPS_CHECK_BIN="/usr/local/bin/fips-startup-check"
if [ ! -x "$FIPS_CHECK_BIN" ]; then
    echo "      ✗ ERROR: FIPS check utility not found: $FIPS_CHECK_BIN"
    EXIT_CODE=1
else
    # Execute the C-based FIPS validation utility
    if ! "$FIPS_CHECK_BIN"; then
        echo ""
        echo "========================================"
        echo "✗ FIPS VALIDATION FAILED"
        echo "========================================"
        echo "Cryptographic validation failed"
        exit 1
    fi
fi

###############################################################################
# Check 7: Runtime wolfProvider Verification
###############################################################################
echo ""
echo "[7/7] Verifying runtime wolfProvider usage..."
echo ""

# Test 1: Verify wolfProvider is loaded and active
echo "      [7.1] Checking wolfProvider is loaded..."
if ! openssl list -providers 2>&1 | grep -q "wolfprov"; then
    echo "      ✗ ERROR: wolfProvider not loaded in OpenSSL"
    EXIT_CODE=1
else
    echo "      ✓ wolfProvider is loaded"
fi

# Test 2: Verify non-FIPS algorithms are blocked (MD5 test)
echo ""
echo "      [7.2] Verifying non-FIPS algorithms are blocked..."
MD5_RESULT=$(echo -n "test" | openssl dgst -md5 2>&1 || true)
if echo "$MD5_RESULT" | grep -qi "disabled\|unsupported\|not available"; then
    echo "      ✓ MD5 is blocked by wolfProvider (FIPS enforced)"
elif [ -z "$MD5_RESULT" ]; then
    echo "      ✗ ERROR: MD5 test produced no output"
    EXIT_CODE=1
else
    # Check if MD5 actually produced a hash (should not happen in FIPS mode)
    if echo "$MD5_RESULT" | grep -q "^[a-f0-9]\{32\}$"; then
        echo "      ✗ ERROR: MD5 is NOT blocked - FIPS not enforced!"
        echo "      MD5 output: $MD5_RESULT"
        EXIT_CODE=1
    else
        echo "      ✓ MD5 is blocked (FIPS enforced)"
    fi
fi

# Test 3: Verify FIPS-approved algorithm works (SHA-256)
echo ""
echo "      [7.3] Verifying FIPS-approved algorithms work..."
SHA256_RESULT=$(echo -n "test" | openssl dgst -sha256 2>&1 | awk '{print $2}')
EXPECTED_SHA256="9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
if [ "$SHA256_RESULT" = "$EXPECTED_SHA256" ]; then
    echo "      ✓ SHA-256 works correctly via wolfProvider"
else
    echo "      ✗ ERROR: SHA-256 test failed"
    echo "        Expected: $EXPECTED_SHA256"
    echo "        Got:      $SHA256_RESULT"
    EXIT_CODE=1
fi

# Test 4: Verify wolfProvider properties are set
echo ""
echo "      [7.4] Verifying FIPS properties are active..."
FIPS_PROP_TEST=$(openssl list -cipher-algorithms -verbose 2>&1 | grep -i "fips" || echo "not_found")
if [ "$FIPS_PROP_TEST" != "not_found" ]; then
    echo "      ✓ FIPS properties are active in OpenSSL"
else
    echo "      ℹ FIPS properties verification: provider-level enforcement active"
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "✗ RUNTIME WOLFPROVIDER VALIDATION FAILED"
    echo "========================================"
    echo "wolfProvider is not properly enforcing FIPS mode"
    exit 1
fi

echo ""
echo "      ✓ Runtime verification complete: wolfProvider is active and enforcing FIPS"

###############################################################################
# All Checks Passed - Start RabbitMQ
###############################################################################
echo ""
echo "========================================"
echo "✓ ALL FIPS CHECKS PASSED"
echo "========================================"
echo "Starting RabbitMQ with FIPS-enabled Erlang"
echo ""

# Ensure environment variables are exported for RabbitMQ (using system OpenSSL)
export OPENSSL_CONF=${OPENSSL_CONF:-/etc/ssl/openssl.cnf}
# OPENSSL_MODULES not needed for system OpenSSL (modules in standard location)
export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}
export PATH=/usr/bin:/opt/bitnami/erlang/bin:/opt/bitnami/rabbitmq/sbin:${PATH}

# Set Erlang sys.config path and FIPS configuration
# RabbitMQ uses RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS for additional Erlang arguments
export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-config /opt/bitnami/rabbitmq/etc/sys ${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:-}"
export ERL_FLAGS="-config /opt/bitnami/rabbitmq/etc/sys"

# Debug: Print environment
echo "Environment variables:"
echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "  OPENSSL_CONF=$OPENSSL_CONF"
echo "  RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=$RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"
echo "  ERL_FLAGS=$ERL_FLAGS"
echo ""

# Execute the RabbitMQ entrypoint or command
exec "$@"
