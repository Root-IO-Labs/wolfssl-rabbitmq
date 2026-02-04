#!/bin/bash
set -e

###############################################################################
# RabbitMQ FIPS Image Build Script
#
# This script builds the RabbitMQ FIPS-enabled Docker image with proper
# BuildKit configuration and secret handling.
###############################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "RabbitMQ FIPS Image Builder"
echo "========================================"
echo ""

# Configuration
IMAGE_NAME="rabbitmq-fips"
IMAGE_TAG="3.13.7-ubuntu-22.04"
WOLFSSL_PASSWORD_FILE="wolfssl_password.txt"

###############################################################################
# Check Prerequisites
###############################################################################
echo "Checking prerequisites..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ ERROR: Docker is not installed${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Docker is installed"

# Check if wolfSSL password file exists
if [ ! -f "$WOLFSSL_PASSWORD_FILE" ]; then
    echo -e "${RED}✗ ERROR: wolfSSL password file not found: $WOLFSSL_PASSWORD_FILE${NC}"
    echo ""
    echo "Please create the password file:"
    echo "  echo 'your-password-here' > $WOLFSSL_PASSWORD_FILE"
    exit 1
fi
echo -e "${GREEN}✓${NC} wolfSSL password file found"

# Check Docker BuildKit support
if ! docker buildx version &> /dev/null; then
    echo -e "${YELLOW}⚠${NC} Docker BuildKit not available, using legacy build"
    BUILDKIT=""
else
    echo -e "${GREEN}✓${NC} Docker BuildKit is available"
    BUILDKIT="DOCKER_BUILDKIT=1"
fi

echo ""
echo "========================================"
echo "Build Configuration"
echo "========================================"
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "BuildKit: ${BUILDKIT:-disabled}"
echo "wolfSSL Password File: ${WOLFSSL_PASSWORD_FILE}"
echo ""

###############################################################################
# Build the Image
###############################################################################
read -p "Start build? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Build cancelled."
    exit 0
fi

echo ""
echo "========================================"
echo "Building RabbitMQ FIPS Image"
echo "========================================"
echo ""
echo "This will take approximately 25-35 minutes..."
echo "  - Erlang compilation: ~15-20 min"
echo "  - wolfSSL compilation: ~5-10 min"
echo "  - Other components: ~5 min"
echo ""

START_TIME=$(date +%s)

# Build command
if [ -n "$BUILDKIT" ]; then
    eval $BUILDKIT docker build \
        --secret id=wolfssl_password,src="$WOLFSSL_PASSWORD_FILE" \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -t "${IMAGE_NAME}:latest" \
        --progress=plain \
        .
else
    echo -e "${YELLOW}WARNING: Building without BuildKit - secrets may not work properly${NC}"
    docker build \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -t "${IMAGE_NAME}:latest" \
        .
fi

BUILD_EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "========================================"
if [ $BUILD_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Build Successful${NC}"
    echo "========================================"
    echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "Build time: ${MINUTES}m ${SECONDS}s"
    echo ""
    echo "Next steps:"
    echo "  1. Run: docker run -d -p 5672:5672 -p 15672:15672 ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  2. Or:  docker-compose up -d"
    echo "  3. Test: docker exec <container> /usr/local/bin/test-rabbitmq-fips.sh"
else
    echo -e "${RED}✗ Build Failed${NC}"
    echo "========================================"
    echo "Build time: ${MINUTES}m ${SECONDS}s"
    echo ""
    echo "Check the build logs above for errors."
    echo "Common issues:"
    echo "  - Incorrect wolfSSL password"
    echo "  - Network connectivity issues"
    echo "  - Insufficient disk space or memory"
    exit 1
fi

echo ""
