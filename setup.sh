#!/bin/bash

# By default, the pull variable is true
HACER_PULL=true

# Check if the "-np" parameter was passed
for arg in "$@"; do
  if [ "$arg" == "-np" ]; then
    HACER_PULL=false
  fi
done

# Execute pull only if the variable remains true
if [ "$HACER_PULL" = true ]; then
    echo "Starting image download from Docker Hub..."
    docker compose pull
else
    echo "Skipping docker compose pull (using local image)..."
fi

# Start up the container
docker compose up -d

# Wait a few seconds for sshd to fully start before copying the key
echo "Waiting for SSH service to be ready..."
sleep 5

# Verify if the container is actually running
if [ "$(docker inspect -f '{{.State.Running}}' nyc-taxi 2>/dev/null)" = "true" ]; then
    # Copy and secure the public key
    docker compose cp ~/.ssh/id_ed25519.pub nyc-taxi:/root/.ssh/authorized_keys
    docker compose exec nyc-taxi-app chown root:root /root/.ssh/authorized_keys
    docker compose exec nyc-taxi-app chmod 600 /root/.ssh/authorized_keys
    echo "Ready! Connect with: ssh NycTaxi"
else
    echo "ERROR: The container nyc-taxi stopped unexpectedly."
    echo "Check the reasons by running: docker logs nyc-taxi"
fi
