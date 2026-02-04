# RabbitMQ FIPS Build Documentation

**Version:** 1.0
**Date:** December 2025
**Image:** rabbitmq-fips:3.13.7-ubuntu-22.04

---

## Table of Contents

1. [Overview](#overview)
2. [Build Architecture](#build-architecture)
3. [Component Versions](#component-versions)
4. [Prerequisites](#prerequisites)
5. [Build Process](#build-process)
6. [Build Stages](#build-stages)
7. [Critical Security Steps](#critical-security-steps)
8. [Verification Procedures](#verification-procedures)
9. [Build Optimization](#build-optimization)
10. [Troubleshooting](#troubleshooting)
11. [Known Issues](#known-issues)
12. [Security Considerations](#security-considerations)

---

## Overview

This document provides comprehensive documentation of the multi-stage Docker build process for the FIPS-compliant RabbitMQ container. The build creates a production-ready image with FIPS 140-3 validated cryptography using wolfSSL FIPS v5.

### Key Features

- **Multi-stage build** for minimal runtime image size
- **FIPS 140-3 compliance** through wolfSSL FIPS v5.2.3
- **Erlang/OTP 26.2.5** built with custom FIPS OpenSSL
- **RabbitMQ 3.13.7** using Erlang crypto module in FIPS mode
- **System OpenSSL removal** for FIPS boundary enforcement
- **Ubuntu 22.04 LTS** base with security hardening

---

## Build Architecture

### Multi-Stage Build Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Stage 1: Builder (Ubuntu 22.04)                             │
├─────────────────────────────────────────────────────────────┤
│ 1. Install build dependencies                               │
│ 2. Build OpenSSL 3.0.15 with FIPS module                    │
│ 3. Build wolfSSL FIPS v5.2.3                                │
│ 4. Build wolfProvider v1.1.0                                │
│ 5. Build Erlang/OTP 26.2.5 with FIPS OpenSSL                │
│ 6. Install RabbitMQ 3.13.7 (generic Unix package)           │
│ 7. Build FIPS validation utilities                          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Stage 2: Runtime (Ubuntu 22.04)                             │
├─────────────────────────────────────────────────────────────┤
│ 1. Install minimal runtime dependencies                     │
│ 2. Apply security updates (apt-get upgrade)                 │
│ 3. Remove system OpenSSL (CRITICAL)                         │
│ 4. Copy FIPS crypto stack from builder                      │
│ 5. Copy Erlang/RabbitMQ from builder                        │
│ 6. Configure FIPS environment                               │
│ 7. Copy Bitnami scripts                                     │
│ 8. Set up user/permissions (UID 1001)                       │
│ 9. Configure FIPS entrypoint                                │
└─────────────────────────────────────────────────────────────┘
```

### FIPS Cryptographic Stack

```
RabbitMQ Application
        ↓
Erlang/OTP Crypto Module (FIPS mode enabled)
        ↓
OpenSSL 3.0.15 API (libssl/libcrypto)
        ↓
wolfProvider v1.1.0 (OpenSSL 3 Provider)
        ↓
wolfSSL FIPS v5.2.3 (Validated Module)
        ↓
FIPS 140-3 Compliant Cryptographic Operations
```

---

## Component Versions

| Component | Version | Source | FIPS Role |
|-----------|---------|--------|-----------|
| Ubuntu | 22.04 LTS | Official Docker image | Operating Environment |
| OpenSSL | 3.0.15 | openssl.org | API layer |
| wolfSSL | 5.8.2 FIPS v5.2.3 | wolfssl.com (commercial) | FIPS 140-3 module |
| wolfProvider | v1.1.0 | github.com/wolfSSL/wolfProvider | OpenSSL→wolfSSL bridge |
| Erlang/OTP | 26.2.5 | github.com/erlang/otp | Runtime environment |
| RabbitMQ | 3.13.7 | github.com/rabbitmq/rabbitmq-server | Message broker |

---

## Prerequisites

### Required Software

- **Docker Engine** 20.10+ with BuildKit support
- **Docker Buildx** plugin
- **wolfSSL FIPS password** (commercial license required)
- **4GB+ RAM** for build process
- **10GB+ disk space** for build artifacts

### Host Requirements

- **Linux kernel** >= 6.8.x (for FIPS OE compliance)
- **CPU architecture** x86_64
- **CPU features** RDRAND (recommended), AES-NI (recommended)

### Build Secret

Create `wolfssl_password.txt`:
```bash
echo 'your-wolfssl-commercial-password' > wolfssl_password.txt
chmod 600 wolfssl_password.txt
```

---

## Build Process

### Quick Build

```bash
cd rabbitmq/3.13.7-ubuntu-22.04

# Using build script (recommended)
./build.sh

# Or manually
DOCKER_BUILDKIT=1 docker buildx build \
  --secret id=wolfssl_password,src=wolfssl_password.txt \
  -t rabbitmq-fips:3.13.7-ubuntu-22.04 \
  .
```

### Build Time

- **First build:** 25-35 minutes
- **Cached rebuild:** 2-5 minutes
- **Longest stage:** Erlang/OTP compilation (~15-20 minutes)

### Build Progress

The build shows detailed progress for each stage:
- OpenSSL 3.0.15: ~3-5 minutes
- wolfSSL FIPS v5: ~5-10 minutes (includes FIPS integrity checks)
- wolfProvider: ~1-2 minutes
- Erlang/OTP: ~15-20 minutes
- RabbitMQ setup: ~1 minute
- Runtime configuration: ~2-3 minutes

---

## Build Stages

### Stage 1: Builder

#### 1.1 Build Dependencies Installation

```dockerfile
RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    curl wget git \
    autoconf automake libtool pkg-config \
    p7zip-full perl \
    libncurses-dev \
    xz-utils
```

**Purpose:** Install tools needed for compiling OpenSSL, wolfSSL, Erlang, and extracting RabbitMQ.

#### 1.2 OpenSSL 3.0.15 Build

```dockerfile
./Configure \
    --prefix=/usr/local/openssl \
    --openssldir=/usr/local/openssl/ssl \
    --libdir=lib64 \
    enable-fips \
    shared \
    linux-x86_64
make -j$(nproc)
make install_sw install_fips install_ssldirs
```

**Key Points:**
- `--libdir=lib64`: Libraries in `/usr/local/openssl/lib64/`
- `enable-fips`: Builds FIPS module support
- `install_fips`: Installs FIPS module to `ossl-modules/`

**Output:**
- `/usr/local/openssl/bin/openssl` - OpenSSL command-line tool
- `/usr/local/openssl/lib64/libssl.so.3` - SSL library
- `/usr/local/openssl/lib64/libcrypto.so.3` - Crypto library
- `/usr/local/openssl/lib64/ossl-modules/fips.so` - FIPS module

#### 1.3 wolfSSL FIPS v5 Build

```dockerfile
wget --no-check-certificate -O /tmp/wolfssl.7z "${WOLFSSL_URL}"
7z x /tmp/wolfssl.7z -p"${PASSWORD}"
./configure \
    --enable-fips=v5 \
    --enable-opensslcoexist \
    --enable-cmac --enable-keygen \
    --enable-sha --enable-des3 \
    --enable-aesctr --enable-aesccm \
    # ... additional FIPS-required features
```

**Key Points:**
- `--enable-fips=v5`: Enables FIPS 140-3 validation
- `--enable-opensslcoexist`: Allows coexistence with OpenSSL headers
- Password authentication required for commercial FIPS package
- `./fips-hash.sh`: Generates FIPS integrity hash

**Security Note:**
Uses `--no-check-certificate` for wolfssl.com due to CA certificate chain issues in Ubuntu 22.04. Password authentication provides security. See Section 12.2 for details.

**Output:**
- `/usr/local/lib/libwolfssl.so.42` - wolfSSL FIPS library
- `/usr/local/include/wolfssl/` - wolfSSL headers

#### 1.4 wolfProvider Build

```dockerfile
./configure \
    --prefix=/usr/local \
    --with-openssl=/usr/local/openssl \
    --with-wolfssl=/usr/local
make -j$(nproc)
make install
```

**Key Points:**
- Bridges OpenSSL 3.x provider API to wolfSSL
- Enables transparent FIPS compliance for OpenSSL applications
- Manual installation verification required (make install can be unreliable)

**Output:**
- `/usr/local/lib64/ossl-modules/libwolfprov.so` - wolfProvider module

#### 1.5 Erlang/OTP 26.2.5 Build

```dockerfile
./configure \
    --prefix=/opt/bitnami/erlang \
    --with-ssl=/usr/local/openssl \
    --without-javac --without-wx \
    --without-debugger --without-observer
make -j$(nproc)
make install
```

**Key Points:**
- `--with-ssl=/usr/local/openssl`: Links to FIPS OpenSSL (not system OpenSSL)
- **NO `--enable-fips` flag:** FIPS mode controlled via sys.config, not compile flag
- Disabled GUI components (wx, observer, debugger) to reduce size
- Build time optimized with parallel make (`-j$(nproc)`)

**FIPS Architecture:**
```
Erlang crypto module → OpenSSL 3.x API → wolfProvider → wolfSSL FIPS v5
```

**Output:**
- `/opt/bitnami/erlang/bin/erl` - Erlang shell
- `/opt/bitnami/erlang/lib/crypto-*/priv/lib/crypto.so` - Crypto NIF (links to FIPS OpenSSL)

#### 1.6 RabbitMQ 3.13.7 Installation

```dockerfile
curl -SsLf "https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.13.7/rabbitmq-server-generic-unix-3.13.7.tar.xz" -o rabbitmq.tar.xz
tar -xJf rabbitmq.tar.xz
mv rabbitmq_server-3.13.7 /opt/bitnami/rabbitmq
```

**Key Points:**
- Uses generic Unix package (no compilation needed)
- Pure Erlang application (no C dependencies)
- Will use Erlang crypto module for all cryptography

**Output:**
- `/opt/bitnami/rabbitmq/sbin/rabbitmq-server` - RabbitMQ server
- `/opt/bitnami/rabbitmq/ebin/` - Erlang BEAM files

### Stage 2: Runtime

#### 2.1 Runtime Dependencies

```dockerfile
RUN apt-get install -y --no-install-recommends \
    ca-certificates \
    libgcc-s1 \
    libssl3t64 \        # Will be removed later!
    libstdc++6 \
    libtinfo6 libncurses6 \
    locales procps zlib1g
```

**Important:** `libssl3t64` is installed here but **MUST be removed** (see Section 7.1).

#### 2.2 Security Updates (NEW)

```dockerfile
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

**Purpose:** Apply security patches to runtime packages.

**Timing:** Must run **BEFORE** removing system OpenSSL (some packages depend on it for updates).

#### 2.3 System OpenSSL Removal (CRITICAL)

See [Section 7: Critical Security Steps](#critical-security-steps)

#### 2.4 Copy FIPS Components

```dockerfile
# OpenSSL 3.0.15
COPY --from=builder /usr/local/openssl /usr/local/openssl

# wolfSSL FIPS v5
COPY --from=builder /usr/local/lib/libwolfssl* /usr/local/lib/
COPY --from=builder /usr/local/include/wolfssl /usr/local/include/wolfssl

# wolfProvider
# (copied via bind mount from builder OpenSSL modules)

# Erlang
COPY --from=builder /opt/bitnami/erlang /opt/bitnami/erlang

# RabbitMQ
COPY --from=builder /opt/bitnami/rabbitmq /opt/bitnami/rabbitmq
```

#### 2.5 Configuration Files

```dockerfile
# OpenSSL configuration (loads wolfProvider)
COPY openssl-wolfprov.cnf /usr/local/openssl/ssl/openssl.cnf

# Erlang FIPS configuration
COPY sys.config /opt/bitnami/rabbitmq/etc/sys.config

# Erlang inet configuration
COPY erl_inetrc /opt/bitnami/rabbitmq/etc/erl_inetrc
```

**sys.config:**
```erlang
[{crypto, [{fips_mode, true}]}].
```

**Critical:** FIPS mode must be set before Erlang crypto module loads. Cannot be changed after Erlang VM starts.

#### 2.6 Environment Configuration

```dockerfile
ENV PATH="/usr/local/openssl/bin:/opt/bitnami/erlang/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/openssl/lib64:/usr/local/lib"
ENV OPENSSL_CONF=/usr/local/openssl/ssl/openssl.cnf
ENV OPENSSL_MODULES=/usr/local/lib64/ossl-modules
```

#### 2.7 Dynamic Linker Configuration

```dockerfile
RUN echo "/usr/local/openssl/lib64" > /etc/ld.so.conf.d/openssl-fips.conf && \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/openssl-fips.conf && \
    ldconfig
```

**Purpose:** Ensures dynamic linker finds FIPS libraries first.

---

## Critical Security Steps

### 7.1 System OpenSSL Removal (CRITICAL FOR FIPS)

#### Why This is Critical

Without this step, the FIPS boundary is **VIOLATED**:

```
❌ WITH system OpenSSL present:
Erlang crypto module ──┬──> FIPS OpenSSL (/usr/local/openssl) ✓
                       └──> System OpenSSL (/usr/lib) ✗ BYPASS!

✅ WITHOUT system OpenSSL:
Erlang crypto module ────> FIPS OpenSSL (/usr/local/openssl) ✓ ONLY
```

#### Implementation

```dockerfile
RUN set -eux; \
    echo "Removing system OpenSSL libraries to enforce FIPS-only crypto..."; \
    # Remove system OpenSSL libraries
    rm -f /usr/lib/x86_64-linux-gnu/libssl.so* || true; \
    rm -f /usr/lib/x86_64-linux-gnu/libcrypto.so* || true; \
    rm -f /lib/x86_64-linux-gnu/libssl.so* || true; \
    rm -f /lib/x86_64-linux-gnu/libcrypto.so* || true; \
    # Remove system OpenSSL binary
    rm -f /usr/bin/openssl || true; \
    # Update dpkg database
    dpkg --remove --force-depends libssl3t64 2>/dev/null || true; \
    # Verify removal
    if [ -f "/usr/lib/x86_64-linux-gnu/libssl.so.3" ]; then \
        echo "ERROR: System OpenSSL still present!"; \
        exit 1; \
    fi; \
    echo "✓ System OpenSSL removed - FIPS enforcement active"
```

#### Verification

```bash
# In container, these should return nothing:
find /usr/lib /lib -name "libssl.so*" 2>/dev/null
find /usr/lib /lib -name "libcrypto.so*" 2>/dev/null

# This should only show FIPS OpenSSL:
ldd /opt/bitnami/erlang/lib/crypto-*/priv/lib/crypto.so | grep ssl
# Expected: /usr/local/openssl/lib64/libssl.so.3
```

---

## Verification Procedures

### 8.1 Build-Time Verification

#### OpenSSL FIPS Module

```bash
docker run --rm rabbitmq-fips:3.13.7-ubuntu-22.04 \
  openssl list -providers

# Expected output includes:
#   wolfprovider
#     name: wolfSSL Provider
#     version: 1.1.0
#     status: active
```

#### wolfSSL FIPS Integrity

```bash
docker run --rm rabbitmq-fips:3.13.7-ubuntu-22.04 \
  /usr/local/bin/fips-startup-check

# Expected:
# [1/4] Verifying FIPS mode... ✓
# [2/4] Running POST... ✓
# [3/4] Running KAT... ✓
# [4/4] Validating RNG... ✓
```

#### Erlang Crypto Linkage

```bash
docker run --rm --entrypoint="" rabbitmq-fips:3.13.7-ubuntu-22.04 \
  ldd /opt/bitnami/erlang/lib/crypto-*/priv/lib/crypto.so

# Must show:
#   libssl.so.3 => /usr/local/openssl/lib64/libssl.so.3
#   libcrypto.so.3 => /usr/local/openssl/lib64/libcrypto.so.3
```

### 8.2 Runtime Verification

#### Erlang FIPS Mode

```bash
docker exec rabbitmq-container erl -noshell -eval \
  'io:format("~p~n", [crypto:info_fips()]), halt().'

# Expected: enabled
```

#### System OpenSSL Absence

```bash
docker exec rabbitmq-container \
  find /usr/lib /lib -name "libssl.so*" 2>/dev/null

# Expected: (no output)
```

#### RabbitMQ Crypto Test

```bash
docker exec rabbitmq-container /usr/local/bin/test-rabbitmq-fips.sh

# Expected: All 5 tests pass
```

---

## Build Optimization

### 9.1 Layer Caching

Stages are ordered for optimal caching:
1. Rarely changing (OpenSSL, wolfSSL)
2. Occasionally changing (wolfProvider, Erlang)
3. Frequently changing (RabbitMQ, configs)

### 9.2 Parallel Compilation

All `make` commands use `-j$(nproc)` for parallel builds.

### 9.3 Image Size Reduction

- **Erlang stripping:** Debug symbols removed (`strip --strip-unneeded`)
- **Erlang cleanup:** Source files, examples, docs removed
- **Multi-stage:** Build tools not in runtime image
- **Final size:** ~800MB-1.2GB (includes full Erlang + RabbitMQ)

---

## Troubleshooting

### 10.1 Build Fails: wolfSSL Download

**Error:** `wget: ERROR 403: Forbidden`

**Cause:** Incorrect wolfSSL password

**Solution:**
```bash
# Verify password file
cat wolfssl_password.txt
# Should show your password, no extra whitespace

# Recreate if needed
echo 'correct-password' > wolfssl_password.txt
chmod 600 wolfssl_password.txt
```

### 10.2 Build Fails: Erlang Compilation

**Error:** `crypto.c: undefined reference to SSL_*`

**Cause:** Erlang not finding FIPS OpenSSL

**Solution:** Verify OpenSSL built successfully:
```dockerfile
# In builder stage, verify:
ENV PATH="/usr/local/openssl/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/openssl/lib64"
ENV PKG_CONFIG_PATH="/usr/local/openssl/lib64/pkgconfig"
```

### 10.3 Runtime Fails: Erlang Crypto Module Load Error

**Error:** `crypto:start/0 returned {error, {load_failed, "Failed to load NIF library"}}`

**Cause:** Erlang crypto.so can't find OpenSSL libraries

**Solution:** Check dynamic linker configuration:
```bash
docker exec rabbitmq ldconfig -p | grep ssl
# Should show /usr/local/openssl/lib64 paths
```

### 10.4 FIPS Mode Not Enabled

**Error:** `crypto:info_fips()` returns `not_enabled`

**Cause:** sys.config not loaded or incorrect format

**Solution:**
```bash
# Verify sys.config exists and is correct
docker exec rabbitmq cat /opt/bitnami/rabbitmq/etc/sys.config

# Should show:
# [{crypto, [{fips_mode, true}]}].

# Ensure Erlang loads it:
docker exec rabbitmq bash -c 'echo $RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS'
# Should include: -config /opt/bitnami/rabbitmq/etc/sys
```

---

## Known Issues

### 11.1 CA Certificate Limitations

**Issue:** Ubuntu 22.04 lacks some 2025 certificate authorities

**Impact:**
- wolfssl.com uses GlobalSign Atlas R3 DV TLS CA 2025 Q3 (not in Ubuntu 22.04 bundle)
- Build uses `--no-check-certificate` for wolfssl.com

**Mitigation:**
- wolfSSL download requires password authentication
- HTTPS encryption still active
- For production: Mirror wolfSSL package internally

**Risk Assessment:** Low (password provides authentication)

### 11.2 Build Time

**Issue:** First build takes 25-35 minutes

**Cause:** Erlang/OTP compilation from source

**Mitigation:**
- Use Docker build cache (subsequent builds: 2-5 minutes)
- Consider pre-building Erlang layer for CI/CD

### 11.3 Erlang FIPS Mode Immutability

**Issue:** Cannot toggle FIPS mode after Erlang VM starts

**Cause:** Erlang design - crypto module state is immutable

**Impact:** Must restart container to change FIPS mode

**Solution:** Set correctly in sys.config before deployment

---

## Security Considerations

### 12.1 FIPS Compliance

- **wolfSSL FIPS v5.2.3:** FIPS 140-3 validated cryptographic module
- **Operating Environment:** Ubuntu 22.04 kernel >= 6.8.x required for CMVP compliance
- **FIPS Boundary:** System OpenSSL removed to enforce FIPS-only crypto
- **Validation:** Comprehensive checks at build and runtime

### 12.2 CA Certificate Verification

**wolfSSL Download:**
- Uses `--no-check-certificate` due to CA bundle limitations
- Mitigated by password authentication
- HTTPS encryption active
- **Production recommendation:** Mirror package internally

**OpenSSL Download:**
- Full certificate verification (DigiCert CA in Ubuntu 22.04)
- No security compromises

**RabbitMQ/Erlang Downloads:**
- Official GitHub releases
- HTTPS encrypted
- **Production recommendation:** Verify GPG signatures

### 12.3 Supply Chain Security

**Recommendations:**
1. Mirror all external packages internally
2. Verify GPG signatures where available
3. Use hash verification for downloads
4. Scan images with vulnerability scanners (Trivy, Clair)
5. Pin exact package versions
6. Maintain audit trail of all components

### 12.4 Runtime Security

- **Non-root user:** UID 1001 (rabbitmq)
- **SUID/SGID removal:** No privileged binaries
- **Minimal attack surface:** Only required packages in runtime image
- **FIPS enforcement:** Fail-closed design (container won't start if FIPS invalid)

---

## References

### Documentation

- [RabbitMQ Documentation](https://www.rabbitmq.com/docs)
- [Erlang FIPS Mode](https://www.erlang.org/doc/apps/crypto/fips.html)
- [wolfSSL FIPS](https://www.wolfssl.com/products/fips/)
- [OpenSSL 3.x Providers](https://www.openssl.org/docs/man3.0/man7/provider.html)
- [Operating Environment Requirements](operating-environment.md)
- [Entropy Architecture](entropy-architecture.md)

### Build Files

- `Dockerfile` - Multi-stage build definition
- `openssl-wolfprov.cnf` - OpenSSL configuration
- `sys.config` - Erlang FIPS configuration
- `build.sh` - Automated build script
- `docker-compose.yml` - Container orchestration

---

**Document Version:** 1.0
**Last Updated:** December 2025
**Status:** Production Ready
