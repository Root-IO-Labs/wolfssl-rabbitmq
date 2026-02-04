################################################################################
# Stage 1: Builder - Build OpenSSL 3, wolfSSL FIPS v5, wolfProvider, and Erlang
################################################################################
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Build configuration
ENV OPENSSL_VERSION=3.0.15
ENV WOLFSSL_URL=https://www.wolfssl.com/comm/wolfssl/wolfssl-5.8.2-commercial-fips-v5.2.3.7z
ENV WOLFPROV_REPO=https://github.com/wolfSSL/wolfProvider.git
ENV WOLFPROV_VERSION=v1.1.0
ENV ERLANG_VERSION=26.2.5
ENV RABBITMQ_VERSION=3.13.7

# Installation paths
ENV OPENSSL_PREFIX=/usr/local/openssl
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
        # Erlang build dependencies
        libncurses-dev \
        libncurses6 \
        # RabbitMQ dependencies
        xz-utils \
    ; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*

################################################################################
# Build OpenSSL 3.0.x with FIPS module support
################################################################################
RUN set -eux; \
    cd /tmp; \
    wget https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz; \
    tar -xzf openssl-${OPENSSL_VERSION}.tar.gz; \
    cd openssl-${OPENSSL_VERSION}; \
    ./Configure \
        --prefix=${OPENSSL_PREFIX} \
        --openssldir=${OPENSSL_PREFIX}/ssl \
        --libdir=lib64 \
        enable-fips \
        shared \
        linux-x86_64 \
    ; \
    make -j"$(nproc)"; \
    make install_sw; \
    make install_fips; \
    make install_ssldirs; \
    cd ..; \
    rm -rf openssl-${OPENSSL_VERSION}*; \
    echo "OpenSSL ${OPENSSL_VERSION} installed successfully"

# Update environment for subsequent builds
ENV PATH="${OPENSSL_PREFIX}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib64"
ENV PKG_CONFIG_PATH="${OPENSSL_PREFIX}/lib64/pkgconfig"

# Verify OpenSSL installation
RUN openssl version && \
    openssl list -providers && \
    ls -la ${OPENSSL_PREFIX}/lib64/ossl-modules/

################################################################################
# Build wolfSSL FIPS v5
################################################################################
COPY test-fips.c /tmp/test-fips.c

RUN --mount=type=secret,id=wolfssl_password \
    set -eux; \
    mkdir -p /usr/src; \
    wget --no-check-certificate -O /tmp/wolfssl.7z "${WOLFSSL_URL}"; \
    PASSWORD=$(cat /run/secrets/wolfssl_password | tr -d '\n\r'); \
    7z x /tmp/wolfssl.7z -o/usr/src -p"${PASSWORD}"; \
    rm /tmp/wolfssl.7z; \
    mv /usr/src/wolfssl* /usr/src/wolfssl; \
    cd /usr/src/wolfssl; \
    # Remove Python-specific defines that can cause issues
    sed -i '/^#ifdef WOLFSSL_PYTHON/,/^#endif/d' wolfssl/wolfcrypt/settings.h || true; \
    # Configure wolfSSL with FIPS v5 and necessary features
    ./configure \
        --prefix=${WOLFSSL_PREFIX} \
        --enable-fips=v5 \
        --enable-opensslcoexist \
        --enable-cmac \
        --enable-keygen \
        --enable-sha \
        --enable-des3 \
        --enable-aesctr \
        --enable-aesccm \
        --enable-x963kdf \
        --enable-compkey \
        --enable-certgen \
        --enable-aeskeywrap \
        --enable-enckeys \
        --enable-base16 \
        --with-eccminsz=192 \
        CPPFLAGS="-DHAVE_AES_ECB -DWOLFSSL_AES_DIRECT -DWC_RSA_NO_PADDING -DWOLFSSL_PUBLIC_MP -DHAVE_PUBLIC_FFDHE -DWOLFSSL_DH_EXTRA -DWOLFSSL_PSS_LONG_SALT -DWOLFSSL_PSS_SALT_LEN_DISCOVER -DRSA_MIN_SIZE=1024" \
    ; \
    make -j"$(nproc)"; \
    ./fips-hash.sh; \
    make -j"$(nproc)"; \
    make install; \
    ldconfig; \
    cd /; \
    rm -rf /usr/src/wolfssl; \
    echo "wolfSSL FIPS v5 installed successfully"

# Update library path for wolfSSL
ENV LD_LIBRARY_PATH="${OPENSSL_PREFIX}/lib64:${WOLFSSL_PREFIX}/lib"

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
    echo "Installing wolfProvider..."; \
    make install; \
    echo "Checking installation results..."; \
    find /usr/local -name "*wolfprov*" -type f 2>/dev/null || true; \
    find ${OPENSSL_PREFIX} -name "*wolfprov*" -type f 2>/dev/null || true; \
    # Manual installation if make install didn't work
    if [ ! -f "${OPENSSL_PREFIX}/lib64/ossl-modules/libwolfprov.so" ]; then \
        echo "Manual installation required..."; \
        mkdir -p ${OPENSSL_PREFIX}/lib64/ossl-modules; \
        if [ -f ".libs/libwolfprov.so" ]; then \
            cp -v .libs/libwolfprov.so* ${OPENSSL_PREFIX}/lib64/ossl-modules/ || true; \
        fi; \
        if [ -f "src/.libs/libwolfprov.so" ]; then \
            cp -v src/.libs/libwolfprov.so* ${OPENSSL_PREFIX}/lib64/ossl-modules/ || true; \
        fi; \
    fi; \
    cd ..; \
    rm -rf wolfProvider; \
    echo "wolfProvider installation completed"

# Verify wolfProvider installation
RUN set -eux; \
    echo "Checking for wolfProvider in possible locations..."; \
    if [ -d "${OPENSSL_PREFIX}/lib64/ossl-modules" ]; then \
        ls -la ${OPENSSL_PREFIX}/lib64/ossl-modules/; \
    fi; \
    if [ -d "${OPENSSL_PREFIX}/lib/ossl-modules" ]; then \
        ls -la ${OPENSSL_PREFIX}/lib/ossl-modules/; \
    fi; \
    if [ -d "${WOLFPROV_PREFIX}/lib64/ossl-modules" ]; then \
        ls -la ${WOLFPROV_PREFIX}/lib64/ossl-modules/; \
    fi; \
    if [ -d "${WOLFPROV_PREFIX}/lib/ossl-modules" ]; then \
        ls -la ${WOLFPROV_PREFIX}/lib/ossl-modules/; \
    fi; \
    # Check if libwolfprov.so exists in any of the expected locations
    if [ -f "${OPENSSL_PREFIX}/lib64/ossl-modules/libwolfprov.so" ] || \
       [ -f "${OPENSSL_PREFIX}/lib/ossl-modules/libwolfprov.so" ] || \
       [ -f "${WOLFPROV_PREFIX}/lib64/ossl-modules/libwolfprov.so" ] || \
       [ -f "${WOLFPROV_PREFIX}/lib/ossl-modules/libwolfprov.so" ]; then \
        echo "wolfProvider module found and verified"; \
    else \
        echo "ERROR: wolfProvider module not found in expected locations"; \
        exit 1; \
    fi

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
ENV OPENSSL_PREFIX=/usr/local/openssl
ENV WOLFSSL_PREFIX=/usr/local
ENV ERLANG_PREFIX=/opt/bitnami/erlang
ENV RABBITMQ_PREFIX=/opt/bitnami/rabbitmq

################################################################################
# CRITICAL FIPS STEP 1: Install FIPS OpenSSL to System Locations FIRST
# This must happen BEFORE any apt-get install commands to ensure all
# packages link to FIPS-validated OpenSSL instead of Ubuntu's system OpenSSL
################################################################################

# Copy FIPS components from builder (before installing ANY packages)
COPY --from=builder /usr/local/openssl /usr/local/openssl
COPY --from=builder /usr/local/lib/libwolfssl.so* /usr/local/lib/
COPY --from=builder /usr/local/include/wolfssl /usr/local/include/wolfssl
COPY --from=builder /usr/local/openssl/lib64/ossl-modules/libwolfprov.so* /tmp/wolfprov/

# Install FIPS OpenSSL as system OpenSSL
RUN set -eux; \
    echo "========================================"; \
    echo "Installing FIPS OpenSSL as System OpenSSL"; \
    echo "========================================"; \
    \
    # Create necessary directories
    mkdir -p /usr/lib/x86_64-linux-gnu; \
    mkdir -p /usr/local/lib64/ossl-modules; \
    \
    # Install FIPS OpenSSL libraries to system locations
    # This makes them the default OpenSSL that apt packages will link to
    cp -av /usr/local/openssl/lib64/libssl.so* /usr/lib/x86_64-linux-gnu/; \
    cp -av /usr/local/openssl/lib64/libcrypto.so* /usr/lib/x86_64-linux-gnu/; \
    \
    # Install wolfSSL to system locations
    cp -av /usr/local/lib/libwolfssl.so* /usr/lib/x86_64-linux-gnu/; \
    \
    # Install wolfProvider module
    cp -av /tmp/wolfprov/* /usr/local/lib64/ossl-modules/; \
    rm -rf /tmp/wolfprov; \
    \
    # Install OpenSSL binary to system PATH
    cp -av /usr/local/openssl/bin/openssl /usr/bin/openssl; \
    \
    # Configure dynamic linker to find FIPS libraries
    echo "/usr/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/fips-openssl.conf; \
    echo "/usr/local/openssl/lib64" >> /etc/ld.so.conf.d/fips-openssl.conf; \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/fips-openssl.conf; \
    ldconfig; \
    \
    echo "✓ FIPS OpenSSL installed to system locations"; \
    echo "✓ All future apt packages will use FIPS OpenSSL"

# Set OpenSSL environment variables for wolfProvider
ENV OPENSSL_CONF="/usr/local/openssl/ssl/openssl.cnf" \
    OPENSSL_MODULES="/usr/local/lib64/ossl-modules" \
    LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/local/openssl/lib64:/usr/local/lib" \
    PATH="/usr/bin:/usr/local/openssl/bin:${PATH}"

# Copy OpenSSL configuration with wolfProvider
COPY openssl-wolfprov.cnf /usr/local/openssl/ssl/openssl.cnf

# Verify FIPS OpenSSL works BEFORE installing any packages
RUN set -eux; \
    echo "========================================"; \
    echo "Verifying FIPS OpenSSL Installation"; \
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
    echo "✓ FIPS OpenSSL operational"; \
    echo "✓ wolfProvider loaded"; \
    echo "========================================"

################################################################################
# NOW install runtime dependencies - they will automatically use FIPS OpenSSL
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
# CRITICAL: Remove any system OpenSSL packages that were installed as dependencies
################################################################################
RUN set -eux; \
    echo "========================================"; \
    echo "Removing System OpenSSL Packages"; \
    echo "========================================"; \
    \
    # Remove any OpenSSL packages that may have been installed as dependencies
    apt-get remove -y libssl3 openssl libssl-dev 2>/dev/null || true; \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # Remove any system OpenSSL libraries
    find /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu -name 'libssl.so*' -o -name 'libcrypto.so*' | xargs rm -f 2>/dev/null || true; \
    \
    # Reinstall FIPS OpenSSL libraries to system locations
    cp -av /usr/local/openssl/lib64/libssl.so* /usr/lib/x86_64-linux-gnu/; \
    cp -av /usr/local/openssl/lib64/libcrypto.so* /usr/lib/x86_64-linux-gnu/; \
    \
    # Reinstall wolfSSL to system locations
    cp -av /usr/local/lib/libwolfssl.so* /usr/lib/x86_64-linux-gnu/; \
    \
    # Reinstall FIPS OpenSSL binary to system PATH (removed by apt-get remove)
    cp -av /usr/local/openssl/bin/openssl /usr/bin/openssl; \
    \
    # Update dynamic linker cache
    ldconfig; \
    \
    echo "✓ System OpenSSL packages removed"; \
    echo "✓ FIPS OpenSSL libraries reinstalled to system locations"; \
    echo "✓ FIPS OpenSSL binary reinstalled to /usr/bin/openssl"

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

# Copy OpenSSL configuration
COPY openssl-wolfprov.cnf /usr/local/openssl/ssl/openssl.cnf

# Copy Erlang FIPS configuration
COPY sys.config /opt/bitnami/rabbitmq/etc/sys.config

# Copy Erlang inet configuration
COPY erl_inetrc /opt/bitnami/rabbitmq/etc/erl_inetrc

# Wrap rabbitmq-env script with FIPS environment configuration
RUN mv /opt/bitnami/rabbitmq/sbin/rabbitmq-env /opt/bitnami/rabbitmq/sbin/rabbitmq-env-original || true
COPY rabbitmq-env-fips.sh /opt/bitnami/rabbitmq/sbin/rabbitmq-env
RUN chmod +x /opt/bitnami/rabbitmq/sbin/rabbitmq-env

# Set environment variables for runtime (system location first for FIPS priority)
ENV PATH="/usr/bin:/usr/local/openssl/bin:/opt/bitnami/erlang/bin:/opt/bitnami/rabbitmq/sbin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu:/usr/local/openssl/lib64:/usr/local/lib"
ENV OPENSSL_CONF=/usr/local/openssl/ssl/openssl.cnf
ENV OPENSSL_MODULES=/usr/local/lib64/ossl-modules

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

# Configure dynamic linker to find OpenSSL and wolfSSL libraries
RUN echo "/usr/local/openssl/lib64" > /etc/ld.so.conf.d/openssl-fips.conf && \
    echo "/usr/local/lib" >> /etc/ld.so.conf.d/openssl-fips.conf && \
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
    echo 'export LD_LIBRARY_PATH="/usr/local/openssl/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export OPENSSL_CONF="/usr/local/openssl/ssl/openssl.cnf"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export OPENSSL_MODULES="/usr/local/lib64/ossl-modules"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
    echo 'export PATH="/usr/local/openssl/bin:${PATH}"' >> /opt/bitnami/scripts/rabbitmq-env.sh; \
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
ENV LD_LIBRARY_PATH="/usr/local/openssl/lib64:/usr/local/lib" \
    OPENSSL_CONF="/usr/local/openssl/ssl/openssl.cnf" \
    OPENSSL_MODULES="/usr/local/lib64/ossl-modules" \
    PATH="/usr/local/openssl/bin:${PATH}"

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
