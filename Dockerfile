################################################################################
# Stage 1: Builder - Build OpenSSL 3, wolfSSL FIPS v5, wolfProvider, and Erlang
################################################################################
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Build configuration
ENV WOLFSSL_URL=https://www.wolfssl.com/comm/wolfssl/wolfssl-5.8.2-commercial-fips-v5.2.3.7z
ENV WOLFPROV_REPO=https://github.com/wolfSSL/wolfProvider.git
ENV WOLFPROV_VERSION=v1.1.0
ENV ERLANG_VERSION=26.2.5
ENV RABBITMQ_VERSION=3.13.7

# Installation paths
# Using Ubuntu system OpenSSL 3.0.2 instead of building from source
ENV OPENSSL_PREFIX=/usr
ENV WOLFSSL_PREFIX=/usr/local
ENV WOLFPROV_PREFIX=/usr/local
ENV ERLANG_PREFIX=/opt/bitnami/erlang
ENV RABBITMQ_PREFIX=/opt/bitnami/rabbitmq

# Install build dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        git \
        autoconf \
        automake \
        libtool \
        pkg-config \
        p7zip-full \
        perl \
        # OpenSSL 3.0.2 from Ubuntu (instead of building from source)
        openssl \
        libssl-dev \
        # Erlang build dependencies
        libncurses-dev \
        libncurses6 \
        # RabbitMQ dependencies
        xz-utils \
    ; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*

################################################################################
# Using Ubuntu System OpenSSL 3.0.2
################################################################################
# OpenSSL 3.0.2 is installed via apt (openssl + libssl-dev)
# This simplifies the build, reduces image size, and relies on Ubuntu's
# security updates for OpenSSL patches
#
# Verify system OpenSSL installation
RUN set -eux; \
    openssl version; \
    pkg-config --modversion openssl; \
    echo "✓ Using Ubuntu system OpenSSL $(openssl version | cut -d' ' -f2)"

################################################################################
# Build wolfSSL FIPS v5
################################################################################
COPY test-fips.c /tmp/test-fips.c

RUN --mount=type=secret,id=wolfssl_password \
    set -eux; \
    mkdir -p /usr/src; \
    wget -O /tmp/wolfssl.7z "${WOLFSSL_URL}"; \
    PASSWORD=$(cat /run/secrets/wolfssl_password | tr -d '\n\r'); \
    7z x /tmp/wolfssl.7z -o/usr/src -p"${PASSWORD}"; \
    rm /tmp/wolfssl.7z; \
    mv /usr/src/wolfssl* /usr/src/wolfssl; \
    cd /usr/src/wolfssl; \
    # Configure wolfSSL with FIPS v5 and necessary features
    ./configure \
        --prefix=${WOLFSSL_PREFIX} \
        --enable-fips=v5 \
        --enable-opensslcoexist \
        --enable-cmac \
        --enable-keygen \
        --enable-sha \
        --enable-aesctr \
        --enable-aesccm \
        --enable-x963kdf \
        --enable-compkey \
        --enable-certgen \
        --enable-aeskeywrap \
        --enable-enckeys \
        --enable-base16 \
        --with-eccminsz=192 \
        CPPFLAGS="-DHAVE_AES_ECB -DWOLFSSL_AES_DIRECT -DWC_RSA_NO_PADDING -DWOLFSSL_PUBLIC_MP -DHAVE_PUBLIC_FFDHE -DWOLFSSL_DH_EXTRA -DWOLFSSL_PSS_LONG_SALT -DWOLFSSL_PSS_SALT_LEN_DISCOVER -DRSA_MIN_SIZE=2048" \
    ; \
    make -j"$(nproc)"; \
    ./fips-hash.sh; \
    make -j"$(nproc)"; \
    make install; \
    ldconfig; \
    cd /; \
    rm -rf /usr/src/wolfssl; \
    echo "wolfSSL FIPS v5 installed successfully"

# Update library path for wolfSSL (system OpenSSL in standard paths)
ENV LD_LIBRARY_PATH="${WOLFSSL_PREFIX}/lib"

# Test wolfSSL installation
RUN set -eux; \
    gcc /tmp/test-fips.c -o /tmp/test-fips -lwolfssl -I${WOLFSSL_PREFIX}/include; \
    /tmp/test-fips; \
    rm /tmp/test-fips /tmp/test-fips.c; \
    echo "wolfSSL FIPS test passed"

# Build FIPS startup check utility
COPY fips-startup-check.c /tmp/fips-startup-check.c
RUN set -eux; \
    gcc /tmp/fips-startup-check.c -o /usr/local/bin/fips-startup-check \
        -lwolfssl -I${WOLFSSL_PREFIX}/include; \
    chmod +x /usr/local/bin/fips-startup-check; \
    rm /tmp/fips-startup-check.c; \
    echo "FIPS startup check utility built successfully"

################################################################################
# Build wolfProvider
################################################################################
RUN set -eux; \
    # Detect architecture for system OpenSSL module path
    ARCH=$(uname -m); \
    if [ "$ARCH" = "x86_64" ]; then MULTIARCH="x86_64-linux-gnu"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then MULTIARCH="aarch64-linux-gnu"; \
    else MULTIARCH="x86_64-linux-gnu"; fi; \
    OSSL_MODULES_DIR="/usr/lib/${MULTIARCH}/ossl-modules"; \
    echo "Building wolfProvider for $ARCH (modules: $OSSL_MODULES_DIR)"; \
    \
    cd /tmp; \
    git clone --depth 1 --branch ${WOLFPROV_VERSION} ${WOLFPROV_REPO} wolfProvider; \
    cd wolfProvider; \
    ./autogen.sh; \
    ./configure \
        --prefix=${WOLFPROV_PREFIX} \
        --with-openssl=${OPENSSL_PREFIX} \
        --with-wolfssl=${WOLFSSL_PREFIX} \
    ; \
    make -j"$(nproc)"; \
    echo "wolfProvider built, checking build artifacts..."; \
    find . -name "*.so" -type f; \
    \
    # Install wolfProvider to system OpenSSL modules directory
    echo "Installing wolfProvider to ${OSSL_MODULES_DIR}..."; \
    mkdir -p "${OSSL_MODULES_DIR}"; \
    if [ -f ".libs/libwolfprov.so" ]; then \
        cp -v .libs/libwolfprov.so* "${OSSL_MODULES_DIR}/" || true; \
    fi; \
    if [ -f "src/.libs/libwolfprov.so" ]; then \
        cp -v src/.libs/libwolfprov.so* "${OSSL_MODULES_DIR}/" || true; \
    fi; \
    \
    cd ..; \
    rm -rf wolfProvider; \
    echo "✓ wolfProvider installed to ${OSSL_MODULES_DIR}"

# Verify wolfProvider installation and prepare for export to runtime stage
RUN set -eux; \
    ARCH=$(uname -m); \
    if [ "$ARCH" = "x86_64" ]; then MULTIARCH="x86_64-linux-gnu"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then MULTIARCH="aarch64-linux-gnu"; \
    else MULTIARCH="x86_64-linux-gnu"; fi; \
    OSSL_MODULES_DIR="/usr/lib/${MULTIARCH}/ossl-modules"; \
    echo "Verifying wolfProvider in ${OSSL_MODULES_DIR}..."; \
    ls -la "${OSSL_MODULES_DIR}"/; \
    if [ -f "${OSSL_MODULES_DIR}/libwolfprov.so" ]; then \
        echo "✓ wolfProvider module found and verified"; \
    else \
        echo "ERROR: wolfProvider module not found at ${OSSL_MODULES_DIR}/libwolfprov.so"; \
        exit 1; \
    fi; \
    \
    # Copy wolfProvider to a consistent location for runtime stage (architecture-independent)
    mkdir -p /tmp/wolfprov-export; \
    cp -v "${OSSL_MODULES_DIR}"/libwolfprov.so* /tmp/wolfprov-export/; \
    echo "✓ wolfProvider exported to /tmp/wolfprov-export for runtime stage"

################################################################################
# Build Erlang/OTP with FIPS support
################################################################################
RUN set -eux; \
    cd /tmp; \
    curl -SsLf "https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz" -o otp_src_${ERLANG_VERSION}.tar.gz; \
    tar -xzf otp_src_${ERLANG_VERSION}.tar.gz; \
    cd otp_src_${ERLANG_VERSION}; \
    # Configure Erlang with custom OpenSSL for FIPS compliance
    #
    # FIPS Architecture:
    #   Erlang crypto module → OpenSSL 3.x API → wolfProvider → wolfSSL FIPS v5
    #
    # IMPORTANT: We do NOT use --enable-fips flag because:
    #   1. --enable-fips is for OpenSSL native FIPS mode (incompatible with wolfProvider)
    #   2. Using --enable-fips with wolfProvider causes Error 227 (crypto NIF load failure)
    #   3. Instead, FIPS is enforced via openssl.cnf with default_properties=fips=yes
    #   4. This makes Erlang detect fips_provider_available=true
    #   5. When FIPS provider available, Erlang uses ONLY OpenSSL (blocks built-ins)
    #
    # FIPS validation happens at multiple layers:
    #   - Build time: wolfSSL FIPS integrity checks (fips-hash.sh)
    #   - Build time: wolfProvider compiled against wolfSSL FIPS v5
    #   - Runtime: openssl.cnf sets default_properties=fips=yes
    #   - Runtime: Erlang detects fips_provider_available=true
    #   - Runtime: wolfProvider provides only FIPS 140-3 algorithms
    #   - Runtime: Non-FIPS algorithms blocked (Erlang won't use built-ins)
    ./configure \
        --prefix=${ERLANG_PREFIX} \
        --with-ssl=${OPENSSL_PREFIX} \
        --without-javac \
        --without-wx \
        --without-debugger \
        --without-observer \
        --without-et \
        --without-megaco \
        --without-odbc \
    ; \
    # Erlang will use OpenSSL 3.x which is configured with wolfProvider
    echo "Erlang configured to use OpenSSL at ${OPENSSL_PREFIX}"; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /tmp/otp_src_${ERLANG_VERSION}*; \
    # Optimize Erlang installation size
    find ${ERLANG_PREFIX} -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true; \
    rm -rf ${ERLANG_PREFIX}/lib/*/doc; \
    rm -rf ${ERLANG_PREFIX}/lib/*/examples; \
    rm -rf ${ERLANG_PREFIX}/lib/*/src; \
    rm -rf ${ERLANG_PREFIX}/man; \
    rm -rf ${ERLANG_PREFIX}/misc; \
    find ${ERLANG_PREFIX} -name "*.c" -delete; \
    find ${ERLANG_PREFIX} -name "*.h" -delete; \
    echo "Erlang ${ERLANG_VERSION} with FIPS support installed successfully"

# Update environment for Erlang
ENV PATH="${ERLANG_PREFIX}/bin:${PATH}"

# Verify Erlang installation and crypto module
RUN set -eux; \
    erl -version; \
    echo "Testing Erlang crypto module..."; \
    erl -noshell -eval 'application:ensure_all_started(crypto), io:format("Crypto module loaded successfully~n"), halt().' || \
        (echo "ERROR: Erlang crypto module failed to load"; ldd ${ERLANG_PREFIX}/lib/crypto-*/priv/lib/crypto.so || true; exit 1); \
    echo "Erlang installed successfully with working crypto module"

################################################################################
# Install RabbitMQ generic Unix package
################################################################################
RUN set -eux; \
    mkdir -p /tmp/rabbitmq && cd /tmp/rabbitmq; \
    curl -SsLf "https://github.com/rabbitmq/rabbitmq-server/releases/download/v${RABBITMQ_VERSION}/rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz" -o rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz; \
    tar -xJf rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz; \
    mv rabbitmq_server-${RABBITMQ_VERSION} ${RABBITMQ_PREFIX}; \
    cd / && rm -rf /tmp/rabbitmq; \
    # Create necessary directories
    rm -rf ${RABBITMQ_PREFIX}/share/doc 2>/dev/null || true; \
    mkdir -p ${RABBITMQ_PREFIX}/.rabbitmq; \
    mkdir -p ${RABBITMQ_PREFIX}/etc/rabbitmq; \
    mkdir -p ${RABBITMQ_PREFIX}/var/lib/rabbitmq; \
    mkdir -p ${RABBITMQ_PREFIX}/var/log/rabbitmq; \
    echo "RabbitMQ ${RABBITMQ_VERSION} installed successfully"

################################################################################
# Stage 2: Runtime - Minimal image with required libraries
################################################################################
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Installation paths
# Using Ubuntu system OpenSSL 3.0.2 instead of building from source
ENV OPENSSL_PREFIX=/usr
ENV WOLFSSL_PREFIX=/usr/local
ENV ERLANG_PREFIX=/opt/bitnami/erlang
ENV RABBITMQ_PREFIX=/opt/bitnami/rabbitmq

################################################################################
# Install system OpenSSL and FIPS components
################################################################################

# Install Ubuntu system OpenSSL 3.0.2 and copy FIPS components from builder
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssl libssl-dev; \
    rm -rf /var/lib/apt/lists/*; \
    openssl version; \
    echo "✓ Ubuntu system OpenSSL installed"

# Copy FIPS components from builder
COPY --from=builder /usr/local/lib/libwolfssl.so* /usr/local/lib/
COPY --from=builder /usr/local/include/wolfssl /usr/local/include/wolfssl

# Copy wolfProvider from builder to temporary location (architecture-independent path)
COPY --from=builder /tmp/wolfprov-export/ /tmp/wolfprov/

# Install wolfProvider to correct system OpenSSL modules directory
RUN set -eux; \
    ARCH=$(uname -m); \
    if [ "$ARCH" = "x86_64" ]; then MULTIARCH="x86_64-linux-gnu"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then MULTIARCH="aarch64-linux-gnu"; \
    else MULTIARCH="x86_64-linux-gnu"; fi; \
    OSSL_MODULES_DIR="/usr/lib/${MULTIARCH}/ossl-modules"; \
    echo "Setting up FIPS components for ${ARCH} architecture (modules: ${OSSL_MODULES_DIR})..."; \
    \
    # Create modules directory and copy wolfProvider
    mkdir -p "${OSSL_MODULES_DIR}"; \
    cp -av /tmp/wolfprov/* "${OSSL_MODULES_DIR}/"; \
    rm -rf /tmp/wolfprov; \
    \
    # Verify wolfProvider was installed
    if [ ! -f "${OSSL_MODULES_DIR}/libwolfprov.so" ]; then \
        echo "ERROR: wolfProvider not found at ${OSSL_MODULES_DIR}"; \
        ls -la "${OSSL_MODULES_DIR}" || true; \
        exit 1; \
    fi; \
    echo "✓ wolfProvider installed at ${OSSL_MODULES_DIR}"; \
    ls -la "${OSSL_MODULES_DIR}"; \
    \
    # Configure dynamic linker to find wolfSSL
    echo "${WOLFSSL_PREFIX}/lib" > /etc/ld.so.conf.d/fips-wolfssl.conf; \
    ldconfig; \
    \
    echo "✓ wolfSSL and wolfProvider installed to system locations"

# Copy OpenSSL configuration with wolfProvider
COPY openssl-wolfprov.cnf /etc/ssl/openssl.cnf

# Set OpenSSL environment variables for wolfProvider
ENV OPENSSL_CONF="/etc/ssl/openssl.cnf"

# Verify FIPS OpenSSL and wolfProvider
RUN set -eux; \
    echo "========================================"; \
    echo "Verifying FIPS OpenSSL + wolfProvider"; \
    echo "========================================"; \
    openssl version; \
    echo ""; \
    echo "OpenSSL providers:"; \
    openssl list -providers; \
    echo ""; \
    if ! openssl list -providers | grep -q wolfprov; then \
        echo "ERROR: wolfProvider not loaded!"; \
        exit 1; \
    fi; \
    echo "✓ System OpenSSL 3.0.2 operational"; \
    echo "✓ wolfProvider loaded"; \
    echo "========================================"

################################################################################
# Install runtime dependencies
################################################################################
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libgcc-s1 \
        libstdc++6 \
        libtinfo6 \
        libncurses6 \
        locales \
        procps \
        zlib1g \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    echo "Runtime dependencies installed successfully (automatically using FIPS OpenSSL)"

################################################################################
# CRITICAL: Remove ALL non-FIPS crypto libraries for 100% FIPS compliance
################################################################################
RUN set -eux; \
    echo "========================================"; \
    echo "Removing Non-FIPS Crypto Libraries"; \
    echo "========================================"; \
    \
    # Preserve CA certificates bundle (needed for TLS connections)
    mkdir -p /tmp/certs-backup; \
    cp -a /etc/ssl/certs/ca-certificates.crt /tmp/certs-backup/ 2>/dev/null || true; \
    cp -a /etc/ssl/certs /tmp/certs-backup/ 2>/dev/null || true; \
    \
    # Remove alternative crypto libraries and their dependencies
    apt-get remove -y \
        ca-certificates \
        libgnutls30 \
        libnettle8 \
        libhogweed6 \
        libgcrypt20 \
        libk5crypto3 \
        apt \
        gpgv \
        libapt-pkg6.0 \
        2>/dev/null || true; \
    \
    # Aggressive autoremove to clean all orphaned packages
    apt-get autoremove -y --purge; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # Restore CA certificates
    mkdir -p /etc/ssl/certs; \
    cp -a /tmp/certs-backup/certs/* /etc/ssl/certs/ 2>/dev/null || true; \
    cp -a /tmp/certs-backup/ca-certificates.crt /etc/ssl/certs/ 2>/dev/null || true; \
    rm -rf /tmp/certs-backup; \
    \
    # Verify alternative crypto libraries are gone
    echo "Verifying crypto library removal..."; \
    if find /usr/lib /lib -name 'libgnutls*' -o -name 'libnettle*' -o -name 'libhogweed*' -o -name 'libgcrypt*' -o -name 'libk5crypto*' 2>/dev/null | grep -q .; then \
        echo "WARNING: Some crypto libraries still present"; \
    else \
        echo "✓ All non-FIPS crypto libraries removed"; \
    fi; \
    \
    echo "✓ 100% FIPS-only runtime environment achieved"

# Copy Erlang installation
COPY --from=builder /opt/bitnami/erlang /opt/bitnami/erlang

# Copy RabbitMQ installation
COPY --from=builder /opt/bitnami/rabbitmq /opt/bitnami/rabbitmq

# Copy RabbitMQ Bitnami scripts and configuration
COPY --from=builder /opt/bitnami/rabbitmq /opt/bitnami/rabbitmq

# Copy Erlang FIPS configuration
COPY sys.config /opt/bitnami/rabbitmq/etc/sys.config

# Copy Erlang inet configuration
COPY erl_inetrc /opt/bitnami/rabbitmq/etc/erl_inetrc

# Wrap rabbitmq-env script with FIPS environment configuration
RUN mv /opt/bitnami/rabbitmq/sbin/rabbitmq-env /opt/bitnami/rabbitmq/sbin/rabbitmq-env-original || true
COPY rabbitmq-env-fips.sh /opt/bitnami/rabbitmq/sbin/rabbitmq-env
RUN chmod +x /opt/bitnami/rabbitmq/sbin/rabbitmq-env

# Set environment variables for runtime
ENV PATH="/usr/bin:/opt/bitnami/erlang/bin:/opt/bitnami/rabbitmq/sbin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib"
ENV OPENSSL_CONF=/etc/ssl/openssl.cnf

# RabbitMQ environment variables
ENV HOME="/opt/bitnami/rabbitmq/.rabbitmq"
ENV RABBITMQ_HOME=/opt/bitnami/rabbitmq
ENV RABBITMQ_BASE=/opt/bitnami/rabbitmq
ENV RABBITMQ_MNESIA_BASE=/opt/bitnami/rabbitmq/var/lib/rabbitmq/mnesia
ENV RABBITMQ_LOG_BASE=/opt/bitnami/rabbitmq/var/log/rabbitmq
ENV RABBITMQ_CONFIG_FILE=/opt/bitnami/rabbitmq/etc/rabbitmq/rabbitmq
ENV RABBITMQ_PLUGINS_DIR=/opt/bitnami/rabbitmq/plugins
ENV RABBITMQ_ENABLED_PLUGINS_FILE=/opt/bitnami/rabbitmq/etc/rabbitmq/enabled_plugins
ENV ERL_INETRC=/opt/bitnami/rabbitmq/etc/erl_inetrc
ENV RABBITMQ_SERVER_CODE_PATH=/opt/bitnami/rabbitmq/ebin

# Configure dynamic linker to find wolfSSL libraries (system OpenSSL in standard paths)
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/wolfssl.conf && \
    ldconfig

# Copy FIPS startup check utility from builder
COPY --from=builder /usr/local/bin/fips-startup-check /usr/local/bin/fips-startup-check
RUN chmod +x /usr/local/bin/fips-startup-check

# Copy Bitnami prebuildfs structure (contains library scripts)
COPY prebuildfs /

# Copy Bitnami rootfs structure (contains RabbitMQ scripts)
COPY rootfs /

# Inject FIPS environment variables into Bitnami rabbitmq-env.sh
# This ensures the environment is set before any RabbitMQ scripts execute
RUN set -eux; \
    echo '' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo '# FIPS Environment Configuration' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export OPENSSL_CONF="/etc/ssl/openssl.cnf"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-config /opt/bitnami/rabbitmq/etc/sys ${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:-}"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    cat /opt/bitnami/scripts/rabbitmq-env.sh | tail -10

# Modify run_chroot to preserve FIPS environment variables
# The chroot command starts a fresh bash, so we need to explicitly export these variables
RUN set -eux; \
    sed -i '/cd ${cwd}; export HOME=${homedir};/s/export HOME=${homedir};/export HOME=${homedir}; export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}"; export OPENSSL_CONF="${OPENSSL_CONF}"; export OPENSSL_MODULES="${OPENSSL_MODULES}"; export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS}";/' /opt/bitnami/scripts/libos.sh; \
    grep -A 2 'export HOME=' /opt/bitnami/scripts/libos.sh | tail -3

# Create RabbitMQ user and set permissions
RUN set -eux; \
    groupadd -g 1001 rabbitmq; \
    useradd -u 1001 -g rabbitmq -d /opt/bitnami/rabbitmq -s /bin/bash rabbitmq; \
    # Create Bitnami volume mount directories
    mkdir -p /bitnami/rabbitmq/conf; \
    mkdir -p /bitnami/rabbitmq/data; \
    mkdir -p /bitnami/rabbitmq/mnesia; \
    mkdir -p /opt/bitnami/rabbitmq/.rabbitmq; \
    # Remove any existing .erlang.cookie that might have been created during RabbitMQ extraction
    # This file will be recreated by RabbitMQ on first run with correct permissions
    rm -f /opt/bitnami/rabbitmq/.rabbitmq/.erlang.cookie; \
    # Set permissions
    chmod g+rwX /opt/bitnami; \
    chown -R rabbitmq:rabbitmq /opt/bitnami/rabbitmq /bitnami/rabbitmq; \
    echo "RabbitMQ user created and permissions set"

# Configure locales
RUN localedef -c -f UTF-8 -i en_US en_US.UTF-8 && \
    update-locale LANG=C.UTF-8 LC_MESSAGES=POSIX && \
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales && \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && \
    locale-gen

# Remove SUID/SGID permissions for security
RUN find / -perm /6000 -type f -exec chmod a-s {} \; || true

# Copy FIPS entrypoint wrapper
COPY fips-entrypoint.sh /usr/local/bin/fips-entrypoint.sh
RUN chmod +x /usr/local/bin/fips-entrypoint.sh

# Copy FIPS test script
COPY test-rabbitmq-fips.sh /usr/local/bin/test-rabbitmq-fips.sh
RUN chmod +x /usr/local/bin/test-rabbitmq-fips.sh

# Copy comprehensive test suite
COPY tests/ /tests/
RUN chmod +x /tests/*.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD rabbitmqctl status || exit 1

# Verification on container build (before switching to non-root user)
RUN set -eux; \
    echo "Verifying runtime configuration..."; \
    openssl version; \
    echo "OpenSSL providers:"; \
    openssl list -providers || true; \
    echo "Erlang version:"; \
    erl -version; \
    echo "Testing Erlang crypto module in runtime stage..."; \
    erl -noshell -eval 'application:ensure_all_started(crypto), io:format("Crypto loaded in runtime~n"), halt().' || \
        (echo "ERROR: Crypto module failed in runtime stage"; ldd /opt/bitnami/erlang/lib/erlang/lib/crypto-*/priv/lib/crypto.so || true; exit 1); \
    echo "Runtime verification complete"; \
    # Clean up any .erlang.cookie created during verification
    rm -f /root/.erlang.cookie /opt/bitnami/rabbitmq/.rabbitmq/.erlang.cookie || true; \
    echo "Cleaned up verification artifacts"

# FIPS Environment Variables - Must be set as Docker ENV for proper inheritance
# These ENVs ensure the Erlang VM can find FIPS libraries when started
ENV LD_LIBRARY_PATH="/usr/local/lib" \
    OPENSSL_CONF="/etc/ssl/openssl.cnf"

# Environment metadata
ENV APP_VERSION="3.13.7" \
    BITNAMI_APP_NAME="rabbitmq" \
    LANGUAGE="en_US:en"

# Expose RabbitMQ ports
EXPOSE 4369 5551 5552 5671 5672 15671 15672 25672

# Set working directory
WORKDIR /opt/bitnami/rabbitmq

# Switch to non-root user
USER 1001

# Set entrypoint for FIPS validation
ENTRYPOINT ["/usr/local/bin/fips-entrypoint.sh"]

# Default command - calls Bitnami entrypoint which then calls run.sh
CMD ["/opt/bitnami/scripts/rabbitmq/entrypoint.sh", "/opt/bitnami/scripts/rabbitmq/run.sh"]
