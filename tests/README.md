# Testing Guide for RabbitMQ FIPS Implementation

## Test Script Overview

This directory contains two main test scripts with **different execution contexts**:

| Script | Where to Run | Command |
|--------|--------------|---------|
| `quick-test.sh` | **FROM HOST** | `./tests/quick-test.sh <image-name>` |
| `crypto-path-validation.sh` | **INSIDE CONTAINER** | `docker exec <container> /tests/crypto-path-validation.sh` |

⚠️ **CRITICAL:** Running `crypto-path-validation.sh` directly on your host will cause **false test failures** because it will use your host's Erlang instead of the container's FIPS-enabled environment. Always use `docker exec` for this script.

---

## Quick Start

### Option 1: Automated Quick Test (Recommended for Initial Validation)

Run the automated test script to verify all critical functionality:

```bash
cd rabbitmq/3.13.7-ubuntu-22.04

# Make sure you've built the image first
# (see BUILD FIRST section below if you haven't)

# Run quick test suite (runs FROM HOST, spawns test containers automatically)
./tests/quick-test.sh rabbitmq-fips:3.13.7-ubuntu-22.04
```

**Execution Context:** ⚠️ Run this script **FROM HOST** - it automatically spawns and manages test containers

**Expected Runtime:** ~2-3 minutes

**What it tests:**
- ✓ Image structure (no system OpenSSL, FIPS libraries present)
- ✓ FIPS validation (all 5 checks pass)
- ✓ OE validation (kernel, CPU, entropy)
- ✓ OpenSSL configuration (wolfProvider loaded)
- ✓ Erlang crypto module (FIPS mode enabled, MD5 blocked)
- ✓ RabbitMQ (version, server status, library linkage)
- ✓ Full entrypoint validation
- ✓ Container startup and AMQP connection

---

### Option 2: Non-FIPS Algorithm Detection (Recommended for Compliance Verification)

Run the comprehensive algorithm checking script to verify 100% FIPS compliance:

```bash
cd rabbitmq/3.13.7-ubuntu-22.04

# Run non-FIPS algorithm detection script
./tests/check-non-fips-algorithms.sh rabbitmq-fips:3.13.7-ubuntu-22.04
```

**Expected Runtime:** ~2-3 minutes

**What it tests:**
- ✓ Non-FIPS algorithms BLOCKED (MD5, MD4, RC4, DES, Blowfish, etc.)
- ✓ FIPS algorithms WORKING (SHA-256, AES, 3DES, etc.)
- ✓ OpenSSL layer enforcement
- ✓ RabbitMQ TLS cipher suite verification
- ✓ RabbitMQ AMQP operations with FIPS crypto
- ✓ Erlang crypto module FIPS compliance
- ✓ 100% FIPS compliance verification

**Use this script when:**
- Verifying no non-FIPS algorithms can be used
- Preparing for FedRAMP 3PAO audit
- Validating security compliance requirements
- Testing after configuration changes

---

### Option 3: Manual Step-by-Step Testing

For detailed testing and troubleshooting, follow the comprehensive test plan:

```bash
# Open the test plan document
less tests/TEST-PLAN.md

# Or view in your browser/editor
code tests/TEST-PLAN.md
```

The test plan includes:
- Detailed test procedures for each component
- Expected outputs for each test
- Troubleshooting guidance
- Test result documentation template

---

## BUILD FIRST

If you haven't built the image yet:

```bash
cd rabbitmq/3.13.7-ubuntu-22.04

# Ensure wolfSSL password file exists
# (You should have received this password from wolfSSL)
echo "YOUR_WOLFSSL_PASSWORD" > wolfssl_password.txt
chmod 600 wolfssl_password.txt

# Build the image
export DOCKER_BUILDKIT=1
docker buildx build \
  --secret id=wolfssl_password,src=wolfssl_password.txt \
  --tag rabbitmq-fips:3.13.7-ubuntu-22.04 \
  --file Dockerfile \
  .
```

**Build time:** 25-35 minutes depending on your hardware

---

## Testing Phases

### Phase 1: Build Verification
- Image builds successfully
- No non-FIPS libraries included (system OpenSSL removed)
- All FIPS components present

### Phase 2: FIPS Validation
- FIPS compile-time flags
- FIPS Known Answer Tests (CAST)
- SHA-256 cryptographic operations
- Entropy source and RNG validation

### Phase 3: Operating Environment
- Kernel version validation (>= 6.8.x)
- CPU architecture check (x86_64)
- Hardware feature detection (RDRAND, AES-NI)

### Phase 4: Erlang Crypto Module
- Erlang FIPS mode enabled
- SHA-256 hashing via Erlang crypto
- MD5 blocking (FIPS enforcement)
- AES encryption

### Phase 5: RabbitMQ Runtime
- Container starts successfully
- RabbitMQ server initializes
- FIPS validation passes on startup
- AMQP connections work
- Management UI accessible

---

## Quick Manual Tests

### Test 1: FIPS Startup Check

```bash
docker run --rm rabbitmq-fips:3.13.7-ubuntu-22.04 \
  /usr/local/bin/fips-startup-check
```

**Expected:** All 4 validation checks pass

---

### Test 2: Verify No System OpenSSL (NEW - CRITICAL)

```bash
docker run --rm --entrypoint="" rabbitmq-fips:3.13.7-ubuntu-22.04 \
  find /usr/lib /lib -name "libssl.so*" -o -name "libcrypto.so*" 2>/dev/null
```

**Expected:** No output (no system OpenSSL found)

**Why This Matters:** System OpenSSL creates a FIPS boundary violation. This test confirms the critical security fix is working.

---

### Test 3: Verify wolfProvider Loaded

```bash
docker run --rm rabbitmq-fips:3.13.7-ubuntu-22.04 \
  openssl list -providers
```

**Expected:** Shows "wolfprov" provider

---

### Test 4: Erlang FIPS Mode Check

```bash
docker run --rm rabbitmq-fips:3.13.7-ubuntu-22.04 \
  erl -noshell -eval 'io:format("~p~n", [crypto:info_fips()]), halt().'
```

**Expected:** `enabled`

---

### Test 5: Erlang Linkage to FIPS OpenSSL

```bash
docker run --rm --entrypoint="" rabbitmq-fips:3.13.7-ubuntu-22.04 \
  sh -c 'ldd /opt/bitnami/erlang/lib/crypto-*/priv/lib/crypto.so | grep ssl'
```

**Expected:** Shows `/usr/local/openssl/lib64/libssl.so.3` (FIPS OpenSSL, not system)

---

### Test 6: Full Container Startup

```bash
# Start container
docker run -d --name test-rabbitmq \
  -e RABBITMQ_USERNAME=admin \
  -e RABBITMQ_PASSWORD=testpass \
  rabbitmq-fips:3.13.7-ubuntu-22.04

# Wait 30 seconds for startup
sleep 30

# Check logs for FIPS validation
docker logs test-rabbitmq 2>&1 | grep "FIPS Validation"

# Check RabbitMQ status
docker exec test-rabbitmq rabbitmqctl status

# Test basic FIPS script
docker exec test-rabbitmq /usr/local/bin/test-rabbitmq-fips.sh

# Cleanup
docker stop test-rabbitmq && docker rm test-rabbitmq
```

---

## Test Results Interpretation

### All Tests Pass ✓
Your implementation is working correctly! Proceed to:
1. Complete remaining documentation tasks
2. Prepare for 3PAO audit
3. Deploy to staging environment

### Some Tests Fail ✗
1. Review the specific error messages
2. Check the troubleshooting section in TEST-PLAN.md
3. Verify build logs for warnings
4. Check that host kernel is >= 6.8.x
5. Verify wolfSSL password is correct
6. **NEW:** If system OpenSSL test fails, rebuild with updated Dockerfile

---

## Common Issues

### Issue: "crypto-path-validation.sh tests failing - MD5 not blocked" ⚠️ COMMON
**Problem:** Running `./tests/crypto-path-validation.sh` directly on host
**Solution:** This script MUST run inside container:
```bash
# ✓ CORRECT
docker exec test-rabbitmq /tests/crypto-path-validation.sh

# ✗ WRONG - Uses host Erlang!
./tests/crypto-path-validation.sh
```

### Issue: "Image not found"
**Solution:** Build the image first (see BUILD FIRST above)

### Issue: "FIPS validation failed"
**Solution:** Check kernel version: `uname -r` (must be >= 6.8.x)

### Issue: "wolfProvider not found"
**Solution:** Check build logs for errors during wolfProvider installation

### Issue: "Erlang FIPS mode not enabled"
**Solution:**
```bash
# Verify sys.config exists and is correct
docker exec test-rabbitmq cat /opt/bitnami/rabbitmq/etc/sys.config
# Should show: [{crypto, [{fips_mode, true}]}].
```

### Issue: "System OpenSSL found" (NEW)
**Solution:** Rebuild image with updated Dockerfile that includes system OpenSSL removal step

### Issue: "Container exits immediately"
**Solution:** Check container logs: `docker logs <container_id>`

---

## Comprehensive Testing

### Crypto Path Validation

For comprehensive validation that RabbitMQ uses only FIPS cryptography, run the crypto path validation script **INSIDE a running container**:

```bash
# First, ensure you have a running RabbitMQ container
docker run -d --name test-rabbitmq \
  -e RABBITMQ_USERNAME=admin \
  -e RABBITMQ_PASSWORD=testpass \
  rabbitmq-fips:3.13.7-ubuntu-22.04

# Wait for RabbitMQ to start (30-60 seconds)
sleep 45

# Run the comprehensive crypto validation (INSIDE the container)
docker exec test-rabbitmq /tests/crypto-path-validation.sh
```

**Execution Context:** ⚠️ **CRITICAL** - This script **MUST run INSIDE a container** using `docker exec`.

**Do NOT run directly on host** (e.g., `./tests/crypto-path-validation.sh`) as it will use your host's Erlang installation instead of the FIPS-enabled container environment, causing false failures (MD5 not blocked, tests fail).

**What it tests:**
- Binary linkage (Erlang → FIPS OpenSSL)
- OpenSSL provider configuration (wolfProvider loaded)
- Erlang crypto module FIPS operations (SHA-256, MD5 blocking, AES)
- RabbitMQ runtime crypto tests
- Library path verification (LD_LIBRARY_PATH, OPENSSL_CONF)
- Environment configuration (OPENSSL_MODULES)
- System OpenSSL absence (CRITICAL security check)

---

## Getting Help

1. **Review logs:** Check `docker logs <container_id>` for detailed error messages
2. **Review build logs:** Check `build.log` if you saved it during build
3. **Check documentation:**
   - `docs/build-documentation.md` - Build process details
   - `docs/operating-environment.md` - OE requirements
   - `docs/entropy-architecture.md` - RNG/entropy details
4. **Consult TEST-PLAN.md:** Detailed troubleshooting section

---

## Test Files

| File | Purpose | Execution Context | Runtime |
|------|---------|-------------------|---------|
| `quick-test.sh` | Automated test script for rapid validation | **Run from HOST** - spawns containers | ~2-3 min |
| `check-non-fips-algorithms.sh` | **NEW:** Non-FIPS algorithm detection & verification | **Run from HOST** - spawns containers | ~2-3 min |
| `crypto-path-validation.sh` | Comprehensive crypto path testing | **Run INSIDE container** via `docker exec` | ~2-3 min |
| `TEST-PLAN.md` | Comprehensive manual test procedures | Reference document | Manual |
| `README.md` | This file - testing quick start guide | Reference document | Reference |

### Script Comparison

**When to use which script:**

- **`quick-test.sh`** - First run after building image. Validates basic FIPS setup.
- **`check-non-fips-algorithms.sh`** - Before audit/production. Verifies 100% compliance (no non-FIPS algorithms).
- **`crypto-path-validation.sh`** - Deep dive validation. Checks crypto library paths and linkage.
- **All three together** - Complete validation suite for production deployment.

### Usage Summary

```bash
# ✓ CORRECT - quick-test.sh runs from host
./tests/quick-test.sh rabbitmq-fips:3.13.7-ubuntu-22.04

# ✓ CORRECT - check-non-fips-algorithms.sh runs from host
./tests/check-non-fips-algorithms.sh rabbitmq-fips:3.13.7-ubuntu-22.04

# ✓ CORRECT - crypto-path-validation.sh runs inside container
docker exec test-rabbitmq /tests/crypto-path-validation.sh

# ✗ WRONG - Don't run crypto-path-validation.sh on host
./tests/crypto-path-validation.sh  # Will use host Erlang, not container!
```

---

## Detailed Test Example: Non-FIPS Algorithm Detection

The `check-non-fips-algorithms.sh` script provides comprehensive FIPS compliance verification:

### What Gets Tested

**Non-FIPS Algorithms (Must be BLOCKED):** 9 tests
- **Hash functions:** MD5, MD4, MD2, RIPEMD160 (4 tests)
- **Encryption:** RC4, DES (single), Blowfish, CAST5 (4 tests)
- **Cipher suites:** MD5-based TLS ciphers (1 test)

**FIPS-Approved Algorithms (Must WORK):** 12 tests
- **Hash functions:** SHA-256, SHA-384, SHA-512 (3 tests)
- **Encryption:** AES-128, AES-256, AES-GCM, 3DES (4 tests)
- **RabbitMQ operations:** FIPS cipher suites, status, list vhosts, list users, Erlang crypto (5 tests)

**Test Layers:**
1. **OpenSSL CLI Layer** - Tests `openssl dgst`, `openssl enc` commands
2. **RabbitMQ Layer** - Tests TLS cipher suites, AMQP operations, and Erlang crypto module with FIPS crypto

### Running the Script

```bash
# Standard run with default image name
./tests/check-non-fips-algorithms.sh

# With custom image name
./tests/check-non-fips-algorithms.sh rabbitmq-fips:3.13.7-ubuntu-22.04

# Save results to file
./tests/check-non-fips-algorithms.sh rabbitmq-fips:3.13.7-ubuntu-22.04 | tee fips-compliance-report.txt
```

### Expected Output

```
================================================================================
         RabbitMQ FIPS - Non-FIPS Algorithm Detection
================================================================================

[1/5] OpenSSL Layer - Non-FIPS Algorithm Tests
  Testing MD5 hash (non-FIPS) ... ✓ BLOCKED (expected)
  Testing MD4 hash (non-FIPS) ... ✓ BLOCKED (expected)
  Testing RC4 encryption (non-FIPS) ... ✓ BLOCKED (expected)
  ...

[2/5] OpenSSL Layer - FIPS Algorithm Verification
  Testing SHA-256 hash (FIPS-approved) ... ✓ WORKS (expected)
  Testing AES-256-CBC encryption (FIPS-approved) ... ✓ WORKS (expected)
  ...

[3/5] Starting RabbitMQ Container
  ✓ Container started
  ✓ RabbitMQ ready (9s)

[4/5] RabbitMQ Layer - FIPS Cipher Suite Verification
  Testing FIPS-approved cipher suites available ... ✓ WORKS (expected)
  Testing non-FIPS ciphers blocked ... ✓ BLOCKED (expected)
  Testing RabbitMQ status command ... ✓ WORKS (expected)
  Testing RabbitMQ list vhosts ... ✓ WORKS (expected)
  Testing RabbitMQ list users ... ✓ WORKS (expected)
  Testing Erlang crypto module FIPS mode ... ✓ WORKS (expected)
  ...

[5/5] Compliance Report
  Non-FIPS algorithms blocked: 9/9 (100%)
  FIPS algorithms working: 12/12 (100%)

✓ ALL TESTS PASSED - 100% FIPS COMPLIANCE VERIFIED
```

### Interpreting Results

**✓ PASS (100% Compliance):**
- All non-FIPS algorithms are blocked
- All FIPS algorithms work correctly
- RabbitMQ operations use FIPS-approved cryptography
- Erlang crypto module operates in FIPS mode
- Image is ready for production/audit

**✗ FAIL (Compliance Issues):**
- Non-FIPS algorithms not fully blocked → Security risk
- FIPS algorithms not working → Functionality issue
- Review test output and check OpenSSL/RabbitMQ/Erlang configuration

---

## After Testing

Once all tests pass:

1. ✓ Document test results (use template in TEST-PLAN.md)
2. ✓ Save test logs for audit trail
3. ✓ Continue with deployment:
   - Configure TLS certificates
   - Set up clustering (if needed)
   - Configure monitoring
   - Prepare for production

---

## RabbitMQ-Specific Testing

### AMQP Connection Test

```bash
# Install amqp-tools if not present
sudo apt-get install -y amqp-tools

# Publish message
amqp-publish -u amqp://admin:testpass@localhost:5672/ \
  -r test.queue -b "FIPS test message"

# Consume message
amqp-consume -u amqp://admin:testpass@localhost:5672/ \
  -q test.queue cat
```

### Management UI Test

```bash
# Check Management UI is accessible
curl -u admin:testpass http://localhost:15672/api/overview

# Expected: JSON response with cluster info
```

### TLS/AMQPS Test (if TLS configured)

```bash
# Test AMQPS connection
openssl s_client -connect localhost:5671 \
  -CAfile /path/to/ca.crt \
  -cert /path/to/client.crt \
  -key /path/to/client.key

# Should show TLS 1.2+ and FIPS-compliant cipher suite
```

---

## Questions?

Refer to the main documentation in `docs/` directory or the comprehensive test plan in `TEST-PLAN.md`.

---

**Testing Version:** 1.0
**Last Updated:** December 2025
**Status:** Production Ready
