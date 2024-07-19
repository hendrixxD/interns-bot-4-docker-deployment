#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status.

# Script arguments (with fallbacks to environment variables)
BRANCH_NAME=${1:-deploy_branch}  # The branch to deploy (default: deploy_branch)
PR_NUMBER=${2:-1}  # The pull request number (default: 1)
REPO_NAME=${3:-flask-example}  # The repository name (default: flask-example)
REPO_URL=${REPO_URL:-https://github.com/Mayorhack/flask-example}  # Repository URL
SSH_USER=${SSH_USER:-}  # SSH user for remote deployment
SSH_HOST=${SSH_HOST:-}  # SSH host for remote deployment
SSH_KEY=${SSH_KEY:-}  # SSH key for remote deployment

# Common variables
BASE_DIR="$HOME/Desktop/DEV/HNG11/interns-bot-4-docker-deployment/my-first-app"  # Base directory
PROJECT_DIR="${BASE_DIR}/${REPO_NAME}"  # Directory for the repository
PR_DIR="${PROJECT_DIR}/PR-${PR_NUMBER}"  # Directory for the specific pull request
DOCKERFILE_PATH="${BASE_DIR}/Dockerfile"  # Path to the Dockerfile
CONTAINER_NAME="${REPO_NAME}-pr-${PR_NUMBER}"  # Container name
LOG_DIR="$HOME/Desktop/deploy_logs"  # Directory for logs
LOG_FILE="${LOG_DIR}/deploy_${REPO_NAME}_${PR_NUMBER}_$(date +%Y%m%d_%H%M%S).log"  # Log file

# Ensure Docker permissions
sudo usermod -aG docker $USER  # Add the current user to the Docker group

# Check Docker permissions
if groups "$(whoami)" | grep -q '\bdocker\b'; then
    DOCKER_CMD="docker"  # Use docker command directly if the user is in the Docker group
else
    DOCKER_CMD="sudo docker"  # Use sudo docker command if the user is not in the Docker group
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Cleanup function to stop and remove the container and clean up directories
cleanup() {
    log_message "Performing cleanup..."
    if [ -n "$SSH_USER" ] && [ -n "$SSH_HOST" ]; then
        # If SSH details are provided, perform remote cleanup
        ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" << EOF
            set -e
            # Stop and remove the container
            $DOCKER_CMD stop $CONTAINER_NAME 2>/dev/null || true
            $DOCKER_CMD rm $CONTAINER_NAME 2>/dev/null || true
            
            # Remove the Docker image
            $DOCKER_CMD rmi $CONTAINER_NAME 2>/dev/null || true
            
            # Remove the PR directory
            rm -rf $PR_DIR
            
            # Remove the project directory if it's empty
            rmdir $PROJECT_DIR 2>/dev/null || true
EOF
    else
        # If no SSH details, perform local cleanup
        $DOCKER_CMD stop $CONTAINER_NAME 2>/dev/null || true
        $DOCKER_CMD rm $CONTAINER_NAME 2>/dev/null || true
        $DOCKER_CMD rmi $CONTAINER_NAME 2>/dev/null || true
        rm -rf "$PR_DIR"
        rmdir "$PROJECT_DIR" 2>/dev/null || true
    fi
    log_message "Cleanup completed."
}

# Set trap to call cleanup on script exit
trap cleanup EXIT

# Function to find an available port
find_available_port() {
    local port=5000
    while [ $port -le 65535 ]; do
        if ! docker ps -a | grep -q ":$port->"; then
            echo $port
            return 0
        fi
        ((port++))
    done
    return 1
}

# Function to deploy (common for both local and remote)
deploy() {
    local is_remote=$1

    log_message "Starting deployment..."

    # Create base and project directories if they don't exist
    mkdir -p "$PROJECT_DIR"

    # Remove PR directory if it exists, then create it
    if [ -d "$PR_DIR" ]; then
        log_message "PR directory already exists. Removing it..."
        rm -rf "$PR_DIR"
    fi
    mkdir -p "$PR_DIR"

    # Clone repository
    log_message "Cloning repository..."
    git clone "$REPO_URL" "$PR_DIR"
    cd "$PR_DIR"
    git checkout "$BRANCH_NAME"
    git pull origin "$BRANCH_NAME"

    # Debugging: Check if Dockerfile exists in the base directory
    if [ ! -f "$DOCKERFILE_PATH" ]; then
        log_message "Error: Dockerfile not found in the base directory: $DOCKERFILE_PATH"
        exit 1
    else
        log_message "Dockerfile found at: $DOCKERFILE_PATH"
    fi

    # Copy Dockerfile to the PR directory
    cp "$DOCKERFILE_PATH" "$PR_DIR/Dockerfile"

    # Debugging: Verify Dockerfile copied successfully
    if [ ! -f "$PR_DIR/Dockerfile" ]; then
        log_message "Error: Failed to copy Dockerfile to PR directory."
        exit 1
    else
        log_message "Dockerfile copied successfully to PR directory."
    fi

    # Find an available port
    PORT=$(find_available_port)
    if [ $? -ne 0 ]; then
        log_message "Error: No available ports found."
        exit 1
    fi

    # Build and run the container
    log_message "Building and running container on port $PORT..."
    $DOCKER_CMD build -t $CONTAINER_NAME -f "$PR_DIR/Dockerfile" "$PR_DIR"
    $DOCKER_CMD run -d --name "$CONTAINER_NAME" -p "$PORT:5000" $CONTAINER_NAME

    log_message "Deployment for PR #${PR_NUMBER} completed successfully. Container is accessible on port $PORT."

    # Check Docker daemon status
    if ! $DOCKER_CMD info >/dev/null 2>&1; then
        log_message "Warning: Docker daemon is not running or user doesn't have permission to access it."
        log_message "Please ensure Docker is running and the user has the necessary permissions."
    fi
}

# Function to deploy locally
deploy_local() {
    deploy false
}

# Function to deploy remotely
deploy_remote() {
    log_message "Starting remote deployment..."

    # Ensure correct SSH key permissions
    chmod 600 "$SSH_KEY"

    # SSH into the remote server and execute the deployment
    ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" << EOF
        set -e
        $(declare -f log_message)
        $(declare -f find_available_port)
        $(declare -f deploy)
        LOG_FILE="$LOG_FILE"
        BRANCH_NAME="$BRANCH_NAME"
        PR_NUMBER="$PR_NUMBER"
        REPO_NAME="$REPO_NAME"
        REPO_URL="$REPO_URL"
        BASE_DIR="$BASE_DIR"
        PROJECT_DIR="$PROJECT_DIR"
        PR_DIR="$PR_DIR"
        DOCKERFILE_PATH="$DOCKERFILE_PATH"
        CONTAINER_NAME="$CONTAINER_NAME"

        deploy true
EOF
}

# Main execution
log_message "Starting deployment process for PR #${PR_NUMBER} of ${REPO_NAME}"

if [ -n "$SSH_USER" ] && [ -n "$SSH_HOST" ] && [ -n "$SSH_KEY" ]; then
    log_message "SSH details provided. Initiating remote deployment..."
    deploy_remote
else
    log_message "No SSH details provided. Initiating local deployment..."
    deploy_local
fi

log_message "Deployment process completed."
