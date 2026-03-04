#!/bin/bash
# FIPS Environment Configuration for RabbitMQ
# This file ensures FIPS-related environment variables are always set

# OpenSSL and wolfSSL library paths
# Using system OpenSSL 3.0.2 from Ubuntu with wolfProvider
export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="/etc/ssl/openssl.cnf"
# OPENSSL_MODULES not needed - system OpenSSL uses architecture-specific paths:
# /usr/lib/x86_64-linux-gnu/ossl-modules (x86_64)
# /usr/lib/aarch64-linux-gnu/ossl-modules (aarch64)

# Erlang FIPS configuration
# This must be set before Erlang VM starts
export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-config /opt/bitnami/rabbitmq/etc/sys ${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:-}"

# Source the original rabbitmq-env if it exists
if [ -f "/opt/bitnami/rabbitmq/sbin/rabbitmq-env-original" ]; then
    . "/opt/bitnami/rabbitmq/sbin/rabbitmq-env-original"
fi
