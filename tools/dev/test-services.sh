#!/usr/bin/env bash
# Run `mvn verify` (incl. Testcontainers) for the services inside a throwaway Maven container
# that talks to the Docker engine through its socket. Made for Docker Engine in WSL2 without
# Docker Desktop: no Java needed in WSL, and sources are copied, so nothing is written to the repo.
#
# From Windows (Git Bash):  MSYS_NO_PATHCONV=1 wsl -d Ubuntu-D -- bash "/mnt/d/New Projects/Cloud_Bridge/tools/dev/test-services.sh"
# From WSL:                 bash tools/dev/test-services.sh [api-gateway order-service inventory-service]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICES=("${@:-api-gateway order-service inventory-service}")
docker volume create cb-m2 >/dev/null          # Maven cache shared across runs
status=0
for svc in ${SERVICES[*]}; do
  echo "===== $svc"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$REPO/services/$svc":/src:ro \
    -v cb-m2:/root/.m2 \
    -e TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal \
    --add-host host.docker.internal:host-gateway \
    maven:3-eclipse-temurin-21 \
    bash -c 'cp -r /src /work && cd /work && mvn -B -q verify > /tmp/build.log 2>&1; rc=$?
             cat target/surefire-reports/*.txt target/failsafe-reports/*.txt 2>/dev/null
             [ $rc -ne 0 ] && tail -60 /tmp/build.log
             exit $rc' || status=1
done
exit $status
