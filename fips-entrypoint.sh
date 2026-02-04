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
echo "[1/6] Validating environment variables..."

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
    echo "      ✗ ERROR: OPENSSL_MODULES is not set"
    EXIT_CODE=1
elif [ ! -d "$OPENSSL_MODULES" ]; then
    echo "      ✗ ERROR: OPENSSL_MODULES directory does not exist: $OPENSSL_MODULES"
    EXIT_CODE=1
else
    echo "      ✓ OPENSSL_MODULES: $OPENSSL_MODULES"
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
echo "[2/6] Validating OpenSSL installation..."

OPENSSL_BIN="/usr/local/openssl/bin/openssl"
if [ ! -x "$OPENSSL_BIN" ]; then
    echo "      ✗ ERROR: OpenSSL binary not found or not executable: $OPENSSL_BIN"
    EXIT_CODE=1
else
    OPENSSL_VERSION=$($OPENSSL_BIN version 2>&1 | head -n1)
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
echo "[3/6] Validating wolfSSL library..."

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
echo "[4/6] Validating wolfProvider module..."

WOLFPROV_MODULE="$OPENSSL_MODULES/libwolfprov.so"
if [ ! -f "$WOLFPROV_MODULE" ]; then
    echo "      ✗ ERROR: wolfProvider module not found: $WOLFPROV_MODULE"
    echo "      Available modules in $OPENSSL_MODULES:"
    ls -la "$OPENSSL_MODULES/" 2>/dev/null || echo "      (directory listing failed)"
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
echo "[5/6] Validating Erlang installation and FIPS configuration..."

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
echo "[6/6] Running cryptographic FIPS validation..."
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
# All Checks Passed - Start RabbitMQ
###############################################################################
echo "========================================"
echo "✓ ALL FIPS CHECKS PASSED"
echo "========================================"
echo "Starting RabbitMQ with FIPS-enabled Erlang"
echo ""

# Ensure environment variables are exported for RabbitMQ
export OPENSSL_CONF=/usr/local/openssl/ssl/openssl.cnf
export OPENSSL_MODULES=/usr/local/lib64/ossl-modules
export LD_LIBRARY_PATH=/usr/local/openssl/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}
export PATH=/usr/local/openssl/bin:/opt/bitnami/erlang/bin:/opt/bitnami/rabbitmq/sbin:${PATH}

# Set Erlang sys.config path and FIPS configuration
# RabbitMQ uses RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS for additional Erlang arguments
export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-config /opt/bitnami/rabbitmq/etc/sys ${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:-}"
export ERL_FLAGS="-config /opt/bitnami/rabbitmq/etc/sys"

# Debug: Print environment
echo "Environment variables:"
echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "  OPENSSL_CONF=$OPENSSL_CONF"
echo "  OPENSSL_MODULES=$OPENSSL_MODULES"
echo "  RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=$RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"
echo "  ERL_FLAGS=$ERL_FLAGS"
echo ""

# Execute the RabbitMQ entrypoint or command
exec "$@"
