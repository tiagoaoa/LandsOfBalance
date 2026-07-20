#!/bin/bash
# Deploy Lands of Balance game server to scherbius.vitorpy.com
# Usage: ./deploy.sh

set -e

SERVER_HOST="scherbius.vitorpy.com"
SERVER_USER="tiago"
REMOTE_DIR="/home/tiago/lob_server"
SERVICE_NAME="lob-game-server"

echo "=== Deploying Lands of Balance Server ==="
echo "Target: ${SERVER_USER}@${SERVER_HOST}"
echo ""

# Create remote directory
echo "[1/5] Creating remote directory..."
ssh ${SERVER_USER}@${SERVER_HOST} "mkdir -p ${REMOTE_DIR}"

# Copy server source files
echo "[2/5] Copying server files..."
scp game_server.c Makefile ${SERVER_USER}@${SERVER_HOST}:${REMOTE_DIR}/

# Copy systemd service file
echo "[3/5] Copying systemd service file..."
scp lob-game-server.service ${SERVER_USER}@${SERVER_HOST}:${REMOTE_DIR}/

# Compile on remote server
echo "[4/5] Compiling server on remote host..."
ssh ${SERVER_USER}@${SERVER_HOST} "cd ${REMOTE_DIR} && make clean && make game_server"

# Install systemd service (requires sudo)
echo "[5/5] Installing systemd service..."
ssh ${SERVER_USER}@${SERVER_HOST} << 'ENDSSH'
cd /home/tiago/lob_server

# Copy service file to systemd directory
sudo cp lob-game-server.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable lob-game-server

# Start/restart the service
sudo systemctl restart lob-game-server

# Show status
sudo systemctl status lob-game-server --no-pager
ENDSSH

echo ""
echo "=== Deployment Complete ==="
echo "Server running at ${SERVER_HOST}:7777"
echo ""
echo "Useful commands:"
echo "  Check status:  ssh ${SERVER_USER}@${SERVER_HOST} 'sudo systemctl status ${SERVICE_NAME}'"
echo "  View logs:     ssh ${SERVER_USER}@${SERVER_HOST} 'sudo journalctl -u ${SERVICE_NAME} -f'"
echo "  Restart:       ssh ${SERVER_USER}@${SERVER_HOST} 'sudo systemctl restart ${SERVICE_NAME}'"
echo "  Stop:          ssh ${SERVER_USER}@${SERVER_HOST} 'sudo systemctl stop ${SERVICE_NAME}'"
