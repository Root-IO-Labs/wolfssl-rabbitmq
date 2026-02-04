#!/bin/bash
# FIPS Environment Configuration for RabbitMQ
# This file ensures FIPS-related environment variables are always set

# OpenSSL and wolfSSL library paths
export LD_LIBRARY_PATH="/usr/local/openssl/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="/usr/local/openssl/ssl/openssl.cnf"
export OPENSSL_MODULES="/usr/local/lib64/ossl-modules"

# Erlang FIPS configuration
# This must be set before Erlang VM starts
export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-config /opt/bitnami/rabbitmq/etc/sys ${RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS:-}"

# Source the original rabbitmq-env if it exists
if [ -f "/opt/bitnami/rabbitmq/sbin/rabbitmq-env-original" ]; then
    . "/opt/bitnami/rabbitmq/sbin/rabbitmq-env-original"
fi
