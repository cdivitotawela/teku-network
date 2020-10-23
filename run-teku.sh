#!/usr/bin/env bash
#
# Run Teku using docker compose
#
##########################################

# Parameters that must provide
TEKU_P2P_ADVERTISE_IP=${TEKU_P2P_ADVERTISE_IP:-}
TEKU_ETH1_IP=${TEKU_ETH1_IP:-}

# Parameters that can override
GIT_REPOSITORY=${GIT_REPOSITORY:-https://github.com/cdivitotawela/aws-teku-network}
GIT_BRANCH=${GIT_BRANCH:-master}
TEKU_IS_BOOT_NODE=${TEKU_IS_BOOT_NODE:-true}
TEKU_BOOT_NODE_IP=${TEKU_BOOT_NODE_IP:-}
TEKU_DATA_PATH=${TEKU_DATA_PATH:-/var/lib/teku}

# Local parameters
LOG_FILE="/tmp/teku-setup.log"
TEKU_REST_API_PORT=5051


# Logging functions
log()
{
  echo "$(date '+%Y-%m-%d %H:%M')  $1" >> $LOG_FILE
}

error()
{
  log "$1"
  exit 1
}


###############
# Main
###############

# Echo message to indicate the log file location
echo "Logs written to file $LOG_FILE"

# Validations
[[ -z $TEKU_ETH1_IP ]] && error "Variable TEKU_ETH1_IP is empty. Teku needs to connect to Besu node."



# Check whether run from a cloned repository or remotely
if [[ -d ./.git ]]
then
    # Set the project base path to script full path
    log "Local git repository available"
    PROJECT_BASE=$(dirname $0)
    [[ $PROJECT_BASE == '.' ]] && PROJECT_BASE=$(pwd)
else
    # Looks like script run remotely
    log "Running script remotely"

    # Make sure user has not set empty variables
    [[ -z $GIT_REPOSITORY ]] && error "Variable $GIT_REPOSITORY  is empty"
    [[ -z $GIT_BRANCH ]] && error "Variable $GIT_BRANCH is empty"

    # Check git installed. Its pre-requisite
    git --version > /dev/null 2>&1 || error "Git is not installed"

    # Create working directory
    PROJECT_BASE=$(mktemp -d /tmp/ethereum-XXXX)
    log "Using working directory $PROJECT_BASE"

    # Clone the project
    log "Clone repository $GIT_REPOSITORY and change branch to $GIT_BRANCH"
    cd $PROJECT_BASE
    git clone $GIT_REPOSITORY . > /dev/null || error "Cloning the repository"
    git checkout $GIT_BRANCH > /dev/null || error "Changing to branch $GIT_BRANCH"
fi


# Check user has sudo access
sudo -n id > /dev/null 2>&1 && SUDO_ACCESS=true

# Check whether user has sudo access. If no data mount for Besu created in /tmp folder
if [[ $SUDO_ACCESS == 'true' ]]
then
  log "User has sudo access. Creating data host path $TEKU_DATA_PATH"
  sudo mkdir -p $TEKU_DATA_PATH && sudo chmod 777 $TEKU_DATA_PATH || error "Failed to create the Besu data mount at $TEKU_DATA_PATH"
else
  # User does not have sudo access. Lets try to create without sudo
  mkdir -p $TEKU_DATA_PATH && chmod 777 $TEKU_DATA_PATH > /dev/null 2>&1 || {
    log "Cannot create Teku data path at $TEKU_DATA_PATH Try creating at $PROJECT_BASE"
    TEKU_DATA_PATH="${PROJECT_BASE}/teku-data"
    log "Creating Teku data path at $TEKU_DATA_PATH"
    mkdir -p $TEKU_DATA_PATH && chmod 777 $TEKU_DATA_PATH || error "Failed to create the Besu data mount at $TEKU_DATA_PATH"
  }
fi


# Determine the advertised address if not provided externally
if [[ -z $TEKU_P2P_ADVERTISE_IP ]]
then
    ## Check for AWS metadata. Timeout set to 1s
    curl -I -m 1 -s --fail http://169.254.169.254 > /dev/null 2>&1 && {
      TEKU_P2P_ADVERTISE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
      log "AWS Environment. Retrieved instance ip $TEKU_P2P_ADVERTISE_IP"
    }

    ## No ip set yet. Retrieve it from the hostname command
    [[ -z $TEKU_P2P_ADVERTISE_IP ]] && {
      TEKU_P2P_ADVERTISE_IP=$(hostname -i)
      log "Retreieved instance ip $TEKU_P2P_ADVERTISE_IP"
    }
fi

# If this is not the boot node, TEKU_BOOT_NODE_IP must be provided to connect to network
if [[ $TEKU_IS_BOOT_NODE != 'true' ]]
then
  # Must have boot node ip
  [[ -z $TEKU_BOOT_NODE_IP ]] && error "This is not the boot node. Must set environment variable TEKU_BOOT_NODE_IP for this node to connect to the network"
  log "Teku boot node ip [$TEKU_BOOT_NODE_IP]"

  # jq must be installed
  jq --version > /dev/null 2>&1 || error "Tool jq is missing"

  # Waiting for the boot node to be available. Max wait 30min
  # Boot node can take some time to start as it also needs to generate the validators keys and register
  max_retry=180
  while [[ $max_retry -gt 0 ]]
  do
    log "Checking Teku boot node is ready. Remaining retries $max_retry"
    max_retry=$(expr $max_retry - 1)
    curl --fail -I -s -m 1 http://${TEKU_BOOT_NODE_IP}:${TEKU_REST_API_PORT}/eth/v1/node/identity > /dev/null 2>&1 && \
      max_retry=0 || \
      sleep 10
  done

  # Final check and output to log file for debug pi
  curl -v --fail -I -s -m 1 http://${TEKU_BOOT_NODE_IP}:${TEKU_REST_API_PORT}/eth/v1/node/identity >> $LOG_FILE 2>&1 || error "Teku Boot node API not ready"

  # Extract enode information
  TEKU_BOOT_NODE_ENODE=$(curl -s http://${TEKU_BOOT_NODE_IP}:${TEKU_REST_API_PORT}/eth/v1/node/identity | jq -r '.data.enr')
  [[ -z $TEKU_BOOT_NODE_ENODE ]] && error "Failed to set TEKU_BOOT_NODE_ENODE"
  [[ $TEKU_BOOT_NODE_ENODE == 'null' ]] && error "Failed to set TEKU_BOOT_NODE_ENODE"
fi

# Adding host data path volume mount in compose file.
# This allows to maintain a clean docker-compose file which can run on its own.
UPDATED_COMPOSE_FILE="$PROJECT_BASE/teku/docker-compose-updated.yml"
sed "/^\ *volumes:\ *$/a \      - ${TEKU_DATA_PATH}:/opt/teku/data" $PROJECT_BASE/teku/docker-compose.yml > $UPDATED_COMPOSE_FILE

# Export data for docker-compose
export TEKU_DATA_PATH
export TEKU_P2P_ADVERTISE_IP
export TEKU_BOOT_NODE_ENODE
export TEKU_ETH1_IP

log "TEKU_BOOT_NODE_ENODE=$TEKU_BOOT_NODE_ENODE"
log "TEKU_ETH1_IP=$TEKU_ETH1_IP"
log "TEKU_DATA_PATH=$TEKU_DATA_PATH"
log "TEKU_P2P_ADVERTISE_IP=$TEKU_P2P_ADVERTISE_IP"

# Start Teku client
log "Starting Teku docker container"
docker-compose -f $UPDATED_COMPOSE_FILE up -d || error "Failed to start the compose stack"
