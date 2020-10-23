#!/usr/bin/env bash
#
# Run Besu using docker compose
#
##################################################

# Parameters that can override
GIT_REPOSITORY=${GIT_REPOSITORY:-https://github.com/cdivitotawela/aws-teku-network}
GIT_BRANCH=${GIT_BRANCH:-master}
BESU_DATA_PATH=${BESU_DATA_PATH:-/var/lib/besu}

# Local parameters
LOG_FILE="/tmp/besu-setup.log"


##################################################
# Logging functions
##################################################
log()
{
  echo "$(date '+%Y-%m-%d %H:%M') $1" >> $LOG_FILE
}

error()
{
  log "ERROR: $1"
  exit 1
}


##################################################
# Main
##################################################

# Echo message to indicate the log file location
echo "Logs written to file $LOG_FILE"

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
  log "User has sudo access. Creating data host path $BESU_DATA_PATH"
  sudo mkdir -p $BESU_DATA_PATH && sudo chmod 777 $BESU_DATA_PATH || error "Failed to create the Besu data mount at $BESU_DATA_PATH"
else
  # User does not have sudo access. Lets try to create without sudo
  mkdir -p $BESU_DATA_PATH && chmod 777 $BESU_DATA_PATH || {
    log "Cannot create Besu data path at $BESU_DATA_PATH"
    BESU_DATA_PATH="${PROJECT_BASE}/besu-data"
    log "Creating Besu data path at $BESU_DATA_PATH"
    mkdir -p $BESU_DATA_PATH && chmod 777 $BESU_DATA_PATH || error "Failed to create the Besu data mount at $BESU_DATA_PATH"
  }
fi

# Adding host data path volume mount in compose file.
# This allows to maintain a clean docker-compose file which can run on its own.
UPDATED_COMPOSE_FILE="$PROJECT_BASE/besu/docker-compose-updated.yml"
sed "/^\ *volumes:\ *$/a \      - ${BESU_DATA_PATH}:/opt/besu/data" $PROJECT_BASE/besu/docker-compose.yml > $UPDATED_COMPOSE_FILE

# Start Besu client
log "Starting Besu docker container"
docker-compose -f $UPDATED_COMPOSE_FILE up -d || error "Failed to start the compose stack"
