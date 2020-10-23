#!/bin/bash
#
# Teku container entrypoint
#
# Mandatory Environment Variables:
# - TEKU_ETH1_IP : Ip of the Ethereum1 client Instance
#
# #####################################################

# Configuration file related parameters
TEKU_NETWORK_TYPE="${TEKU_NETWORK_TYPE:-minimal}"
TEKU_ETH1_ENDPOINT="http://${TEKU_ETH1_IP}:8545"
TEKU_ETH1_DEPOSIT_CONTRACT="${TEKU_ETH1_DEPOSIT_CONTRACT:-0xdddddddddddddddddddddddddddddddddddddddd}"
TEKU_ETH1_PRIVATE_KEY="${TEKU_ETH1_PRIVATE_KEY:-8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63}"
TEKU_VALIDATOR_COUNT="${TEKU_VALIDATOR_COUNT:-64}"
TEKU_DEPOSIT_AMOUNT="${TEKU_DEPOSIT_AMOUNT:-32000000000}"
TEKU_BOOT_NODE_ENODE="${TEKU_BOOT_NODE_ENODE}"

CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-/tmp/teku.yml}"
CONFIG_FILE=/opt/teku/teku.yml

# Passwords are hard-coded as this will only be used in testing
KEY_PATH='/opt/teku/keys'
PASSWORD_FILE=/opt/teku/password.txt

#############################
# Logging functions
#############################
log()
{
  echo "$(date '+%Y-%m-%d %H:%M') $1"
}

error()
{
  log "ERROR: $1"
  exit 1
}

config_update()
{

  local KEY="$1"
  local VALUE="$2"
  local QUOTES=${3:-true}
  local COMMENT="$4"

  # Add quotes if specified.
  [[ $QUOTES == 'true' ]] && VALUE="\"${VALUE}\""

  log "Insert/Update key $KEY"

  if [[ $(grep -c $KEY $CONFIG_TEMPLATE) -ne 0 ]]
  then
    # Update value
    sed -i "s|^${KEY}\:.*|${KEY}\: ${VALUE}|g" $CONFIG_FILE
  else
    # Insert value
    [[ -n $COMMENT ]] && echo "# $COMMENT" >> $CONFIG_FILE
    echo ${KEY}: ${VALUE} >> $CONFIG_FILE
  fi
}


#############################
# Main
#############################

log "Configuring Teku Client"

# Validations
[[ -z $TEKU_ETH1_IP ]] && \
  error "Environment variable TEKU_ETH1_IP is not set" || \
  log "Eth1 client url [$TEKU_ETH1_ENDPOINT]"

[[ -z $TEKU_P2P_ADVERTISE_IP ]] && \
  error "Environment variable TEKU_P2P_ADVERTISE_IP is not set" || \
  log "P2P Advertise IP [$TEKU_P2P_ADVERTISE_IP]"


# Create key path to store validator keys
mkdir -p $KEY_PATH

# Save password to a file
echo "$(date '+%s')$RANDOM" > $PASSWORD_FILE

# Variables for validator key generation
counter=$(eval echo {1..$TEKU_VALIDATOR_COUNT})
validator_key_files=''
validator_key_password_files=''

# Save command output in tempfile
tmp_file=$(mktemp)

# Loop through validator key generation
log "Starting the validator generation and registration"
for count in $counter
do
  # Register validator keys
  yes | /opt/teku/bin/teku validator generate-and-register \
                           --eth1-private-key=$TEKU_ETH1_PRIVATE_KEY \
                           --deposit-amount-gwei=$TEKU_DEPOSIT_AMOUNT \
                           --eth1-endpoint=$TEKU_ETH1_ENDPOINT \
                           --keys-output-path=$KEY_PATH \
                           --eth1-deposit-contract-address=$TEKU_ETH1_DEPOSIT_CONTRACT \
                           --network=minimal \
                           --encrypted-keystore-validator-password-file=$PASSWORD_FILE \
                           --encrypted-keystore-withdrawal-password-file=$PASSWORD_FILE > $tmp_file || error "Failed to generate and register validator key"


  key_file=$(grep "_validator.json" $tmp_file | sed 's/.*\[\(.*_validator.json\)\].*/\1/g')
  validator_key_files="$validator_key_files $key_file"
  validator_key_password_files="$validator_key_password_files $PASSWORD_FILE"

  # Log after processing every 4
  [[ $(expr $count % 4 ) -eq 0 ]] && log "Registered ${count}/${TEKU_VALIDATOR_COUNT} validators"
done
log "Complete validator generation and registration"

# Convert to CSV list of values. Assume no leading and training spaces
validator_key_files=$(echo $validator_key_files | sed 's/ /,/g')
validator_key_password_files=$(echo $validator_key_password_files | sed 's/ /,/g')


# Copy and update configuration file
cat $CONFIG_TEMPLATE > $CONFIG_FILE
config_update 'network' "${TEKU_NETWORK_TYPE}"
config_update 'eth1-deposit-contract-address' "${TEKU_ETH1_DEPOSIT_CONTRACT}"
config_update 'eth1-endpoint' "${TEKU_ETH1_ENDPOINT}"
config_update 'p2p-advertised-ip' "${TEKU_P2P_ADVERTISE_IP}"
config_update 'validators-key-files' "${validator_key_files}" 'true' 'Validator key configuration'
config_update 'validators-key-password-files' "${validator_key_password_files}"

# Configure boot node configuration
[[ -n $TEKU_BOOT_NODE_ENODE ]] && config_update 'p2p-discovery-bootnodes' "['${TEKU_BOOT_NODE_ENODE}']" 'false'

log "Starting teku client"
exec /opt/teku/bin/teku -c $CONFIG_FILE
