# RabbitMQ FIPS-enabled Docker Image

This Docker image provides **RabbitMQ 3.13.7** with **FIPS 140-3 compliant cryptography** using **wolfSSL FIPS v5** and **wolfProvider** on **Ubuntu 22.04**.

## Build Variants

Two Dockerfile variants are available:

| Dockerfile | Description | FIPS 140-3 | DISA STIG/CIS |
|-----------|-------------|------------|---------------|
| `Dockerfile` | FIPS 140-3 compliant image | Yes | No |
| `Dockerfile.hardened` | FIPS 140-3 + DISA STIG/CIS hardened image | Yes | Yes |

## Architecture

```
RabbitMQ → Erlang/OTP Crypto Module → OpenSSL 3.x API → wolfProvider → wolfSSL FIPS v5
```

### Components

- **Base OS**: Ubuntu 22.04
- **Erlang/OTP**: 26.2.5 (built with `--enable-fips`)
- **RabbitMQ**: 3.13.7 (generic Unix package)
- **OpenSSL**: 3.0.15 (with FIPS module support)
- **wolfSSL**: 5.8.2 FIPS v5 (FIPS 140-3 validated cryptographic module)
- **wolfProvider**: v1.1.0 (OpenSSL 3.x provider for wolfSSL)

## FIPS Compliance

This image achieves FIPS 140-3 compliance through:

1. **wolfSSL FIPS v5** - FIPS 140-3 validated cryptographic module
2. **wolfProvider** - Bridges OpenSSL 3.x API to wolfSSL FIPS backend
3. **Erlang FIPS Mode** - Configured via `sys.config` to use only FIPS-approved algorithms
4. **Startup Validation** - Comprehensive FIPS checks before RabbitMQ starts

### FIPS Features

- All cryptographic operations use wolfSSL FIPS v5
- Non-FIPS algorithms (MD5, etc.) are blocked
- TLS 1.2+ support with FIPS-approved cipher suites
- Automatic FIPS validation on container startup

## Building the Image

### Prerequisites

1. **wolfSSL Password File**: Create `wolfssl_password.txt` with your wolfSSL FIPS package password
2. **Docker** with BuildKit support
3. **Docker Compose** (optional, for easier deployment)

### Required Files

**Standard FIPS Build:**
- `Dockerfile` - FIPS 140-3 compliant image
- `wolfssl_password.txt` - wolfSSL FIPS package password

**Hardened FIPS Build:**
- `Dockerfile.hardened` - FIPS 140-3 + DISA STIG/CIS hardened image
- `build-hardened.sh` - Build script for hardened variant
- `wolfssl_password.txt` - wolfSSL FIPS package password

### Build Standard FIPS Image with Docker

```bash
# Build the standard FIPS image
DOCKER_BUILDKIT=1 docker build \
  --secret id=wolfssl_password,src=wolfssl_password.txt \
  -t rabbitmq-fips:3.13.7-ubuntu-22.04 .
```

### Build Hardened FIPS Image with Build Script

```bash
# Build the hardened FIPS + STIG/CIS image
chmod +x build-hardened.sh
./build-hardened.sh
```

The `build-hardened.sh` script performs pre-build checks and builds using `Dockerfile.hardened`.

### Manual Build of Hardened Image

```bash
# Build hardened image manually with Docker
DOCKER_BUILDKIT=1 docker build \
  --secret id=wolfssl_password,src=wolfssl_password.txt \
  -t rabbitmq:3.13.7-ubuntu-22.04-fips \
  -f Dockerfile.hardened .
```

### Build with Docker Compose

```bash
# Build and start
docker-compose up -d --build

# View logs
docker-compose logs -f rabbitmq-fips

# Stop
docker-compose down
```

## Running the Container

### Using Docker

```bash
docker run -d \
  --name rabbitmq-fips \
  -p 5672:5672 \
  -p 15672:15672 \
  -e RABBITMQ_USERNAME=admin \
  -e RABBITMQ_PASSWORD=admin123 \
  rabbitmq-fips:3.13.7-ubuntu-22.04
```

### Using Docker Compose

```bash
docker-compose up -d
```

## Testing FIPS Mode

### Automatic Startup Validation

The container automatically validates FIPS configuration on startup:

```bash
docker logs rabbitmq-fips
```

Look for:
```
========================================
✓ ALL FIPS CHECKS PASSED
========================================
```

### Manual FIPS Testing

Run the included test script:

```bash
# Execute test script inside running container
docker exec rabbitmq-fips /usr/local/bin/test-rabbitmq-fips.sh
```

The test script validates:
1. OpenSSL 3.x and wolfProvider are loaded
2. Erlang crypto module FIPS mode is enabled
3. SHA-256 cryptographic operations work correctly
4. RabbitMQ server is running
5. Non-FIPS algorithms (MD5) are blocked

### Expected Output

```
========================================
RabbitMQ FIPS Validation Test
========================================

[1/5] Testing OpenSSL and wolfProvider...
      ✓ OpenSSL 3.x detected
      ✓ wolfProvider is loaded

[2/5] Testing Erlang crypto module FIPS mode...
      Erlang crypto FIPS status: enabled
      ✓ Erlang FIPS mode is enabled

[3/5] Testing Erlang cryptographic operations (SHA-256)...
      ✓ SHA-256 hash correct: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08

[4/5] Testing RabbitMQ server status...
      ✓ RabbitMQ server is running
      ✓ RabbitMQ version: 3.13.7

[5/5] Testing that non-FIPS algorithms are blocked...
      ✓ MD5 is correctly blocked (FIPS enforced)

========================================
✓ FIPS VALIDATION TESTS PASSED
========================================
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENSSL_CONF` | `/usr/local/openssl/ssl/openssl.cnf` | OpenSSL configuration file |
| `OPENSSL_MODULES` | `/usr/local/lib64/ossl-modules` | OpenSSL provider modules directory |
| `LD_LIBRARY_PATH` | `/usr/local/openssl/lib64:/usr/local/lib` | Library search path |
| `RABBITMQ_USERNAME` | - | RabbitMQ admin username |
| `RABBITMQ_PASSWORD` | - | RabbitMQ admin password |
| `RABBITMQ_PLUGINS` | - | Comma-separated list of plugins to enable |

### Erlang FIPS Configuration

FIPS mode is configured in `/opt/bitnami/rabbitmq/etc/sys.config`:

```erlang
[
    {crypto, [
        {fips_mode, true}
    ]}
].
```

This must be set **before** the Erlang crypto module loads.

### OpenSSL Configuration

OpenSSL is configured in `/usr/local/openssl/ssl/openssl.cnf` to load wolfProvider:

```ini
[provider_sect]
wolfprov = wolfprov_sect

[wolfprov_sect]
module = /usr/local/lib64/ossl-modules/libwolfprov.so
activate = 1
```

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 4369 | TCP | Erlang Port Mapper Daemon (EPMD) |
| 5672 | TCP | AMQP (non-TLS) |
| 5671 | TCP | AMQPS (TLS) |
| 15672 | TCP | Management UI (HTTP) |
| 15671 | TCP | Management UI (HTTPS) |
| 25672 | TCP | Inter-node and CLI communication |

## Access RabbitMQ

### Management UI

Open browser: http://localhost:15672

Default credentials (if configured):
- Username: `admin`
- Password: `admin123`

### AMQP Client

Connect to `amqp://admin:admin123@localhost:5672/`

## Limitations

### FIPS Mode Constraints

1. **TLS Version**: Limited to TLS 1.2+ (no TLS 1.0/1.1)
2. **Algorithms**: Only FIPS-approved algorithms available:
   - ✓ SHA-256, SHA-384, SHA-512
   - ✓ AES (128/192/256-bit)
   - ✓ RSA (≥2048-bit)
   - ✗ MD5, SHA-1 (for signatures)
   - ✗ DES, RC4
3. **Certificates**: Must use SHA-2 family hashing (SHA-256/384/512)
4. **Runtime Changes**: Cannot enter/leave FIPS mode after Erlang starts

### Build Time

- Erlang compilation: ~15-20 minutes
- wolfSSL compilation: ~5-10 minutes
- Total build time: ~25-35 minutes (first build)

### Build Artifacts

**Standard FIPS Build:**
- Image: `rabbitmq-fips:3.13.7-ubuntu-22.04`
- Size: ~500-600 MB

**Hardened FIPS Build:**
- Image: `rabbitmq:3.13.7-ubuntu-22.04-fips`
- Size: ~500-600 MB
- Includes additional security hardening configurations in `/etc/security`, `/etc/pam.d`, `/etc/audit`

## Troubleshooting

### Container Fails to Start

Check logs:
```bash
docker logs rabbitmq-fips
```

Common issues:
1. **wolfProvider not found**: Ensure build completed successfully
2. **FIPS validation failed**: Check that wolfSSL password was correct
3. **Erlang crypto error**: Verify sys.config is properly formatted

### FIPS Mode Not Enabled

Verify Erlang FIPS mode:
```bash
docker exec rabbitmq-fips erl -noshell -eval 'io:format("~p~n", [crypto:info_fips()]), halt().'
```

Should output: `enabled` or `true`

### Algorithm Not Supported Error

This is **expected in FIPS mode**. Non-FIPS algorithms (MD5, etc.) are intentionally blocked.

Use FIPS-approved alternatives:
- MD5 → SHA-256
- SHA-1 → SHA-256
- DES → AES

## Directory Structure

```
rabbitmq-fips/
├── Dockerfile                    # Standard FIPS build definition
├── Dockerfile.hardened           # FIPS + STIG/CIS hardened build definition
├── build-hardened.sh             # Build script for hardened variant
├── docker-compose.yml            # Docker Compose configuration
├── openssl-wolfprov.cnf          # OpenSSL configuration
├── sys.config                    # Erlang FIPS configuration
├── erl_inetrc                    # Erlang inet configuration
├── rabbitmq-env-fips.sh          # RabbitMQ FIPS environment wrapper
├── fips-entrypoint.sh            # FIPS validation entrypoint
├── test-fips.c                   # wolfSSL FIPS build-time test
├── fips-startup-check.c          # FIPS runtime validation utility
├── test-rabbitmq-fips.sh         # RabbitMQ FIPS test script
├── patches/                      # CVE patches for util-linux
│   ├── CVE-2021-3995.patch
│   ├── CVE-2021-3996.patch
│   ├── CVE-2022-0563.patch
│   └── CVE-2024-28085-v2.37.2.patch
├── rootfs/                       # RabbitMQ Bitnami scripts
│   └── opt/bitnami/scripts/
│       ├── rabbitmq/
│       │   ├── entrypoint.sh
│       │   ├── run.sh
│       │   └── setup.sh
│       └── librabbitmq.sh
└── prebuildfs/                   # Pre-build filesystem structure
```

## Implementation Approach

This RabbitMQ FIPS image follows the **same approach** as the Node.js FIPS implementation:

### Shared Components

1. **OpenSSL 3.0.15** - Same build configuration
2. **wolfSSL FIPS v5** - Identical FIPS cryptographic module
3. **wolfProvider v1.1.0** - Same OpenSSL provider bridge

### RabbitMQ-Specific Additions

1. **Erlang/OTP 26.2.5** - Built with `--enable-fips`
2. **Erlang sys.config** - FIPS mode configuration
3. **FIPS Entrypoint** - RabbitMQ-specific validation

### Compatibility

Both Node.js and RabbitMQ images share the **same underlying FIPS cryptography** (wolfSSL FIPS v5), ensuring consistent cryptographic behavior across different runtime environments.

## Security Considerations

### Standard FIPS Image (Dockerfile)

1. **Non-root User**: Container runs as user `1001` (rabbitmq)
2. **SUID/SGID Removed**: No setuid/setgid binaries in image
3. **Minimal Base**: Ubuntu 22.04 with minimal packages
4. **FIPS Enforcement**: Non-FIPS algorithms blocked at runtime

### Hardened FIPS Image (Dockerfile.hardened)

The hardened variant includes all standard FIPS security plus additional DISA STIG V2R1 and CIS Level 1 Server hardening:

1. **Password Policies**: 60-day max age, 7-day min age, 14-day warning, SHA512 hashing, 5-round salting
2. **Password Complexity**: 15-character minimum, 4 character classes required, dictionary checks
3. **Account Lockout**: 3 failed login attempts, 15-minute lockout, 4-second login delay
4. **Kernel Hardening**: ASLR enabled, core dumps disabled, dmesg restricted, ptrace scope limited
5. **Network Hardening**: IP forwarding disabled, ICMP redirects blocked, source routing disabled, SYN cookies enabled
6. **Audit Logging**: System call auditing for time changes, identity modifications, privileged actions
7. **PAM Hardening**: Faillock integration, lastlog tracking, su command restricted to sugroup
8. **File Permissions**: World-writable bits removed, UMASK 077, no orphaned files
9. **SSH Hardening**: Root login disabled, password auth disabled, FIPS-approved ciphers only
10. **Sudo Hardening**: PTY required, logging enabled, zero timestamp timeout
11. **CVE Patching**: util-linux upgraded with CVE-2021-3995, CVE-2021-3996, CVE-2022-0563, CVE-2024-28085 patches
12. **Crypto Library Removal**: All non-FIPS crypto libraries removed (GnuTLS, Nettle, libgcrypt)

## References

- [RabbitMQ Documentation](https://www.rabbitmq.com/docs)
- [Erlang FIPS Mode](https://www.erlang.org/doc/apps/crypto/fips.html)
- [wolfSSL FIPS](https://www.wolfssl.com/products/fips/)
- [OpenSSL 3.x Providers](https://www.openssl.org/docs/man3.0/man7/provider.html)

## License

This implementation follows the licenses of its components:
- RabbitMQ: Mozilla Public License 2.0
- Erlang/OTP: Apache License 2.0
- OpenSSL: Apache License 2.0
- wolfSSL: Commercial FIPS license required

## Support

For issues and questions:
1. Check RabbitMQ logs: `docker logs rabbitmq-fips`
2. Run FIPS test script: `docker exec rabbitmq-fips test-rabbitmq-fips.sh`
3. Verify build logs for any compilation errors
4. Ensure wolfSSL FIPS password is correct
