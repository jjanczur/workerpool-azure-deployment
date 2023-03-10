#!/bin/bash
# Tested on: Canonical, Ubuntu, 22.04 LTS, amd64 jammy image build on 2022-09-12

# Function that prints messages
function message() {
  echo "[$1] $2"
  if [ "$1" == "ERROR" ]; then
    # read -p "Press [Enter] to exit..."
    exit 1
  fi
}

# Function which checks exit status and stops execution
function checkExitStatus() {
  if [ "$1" -eq 0 ]; then
    message "OK" ""
  else
    message "ERROR" "$2"
  fi
}

# Source .env and read env variables from it
echo "Reading .env "
set -a
source .env
set +a

echo "                                                                "
echo "________________________________________________________________"
echo "## Start Setup script ##                                        "
echo "                                                                "

sudo apt-get update -y 
sudo apt-get -y install jq 
sudo apt-get -y install git-all &&

echo "                                                                "
echo "________________________________________________________________"
echo "## Installing docker  ##                                        "
echo "                                                                "

# Install docker

sudo apt-get -y install docker.io &&
sudo service docker start &&
# Allow running docker without sudo 
# Reboot instance or logout and login again
sudo usermod -a -G docker "$USER" &&

echo "                                                                "
echo "________________________________________________________________"
echo "## Installing docker compose ##                                 "
echo "                                                                "

sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose &&
sudo chmod +x /usr/local/bin/docker-compose &&

# Configure Docker to start on boot
sudo systemctl enable docker.service &&
sudo systemctl enable containerd.service


echo "                                                                "
echo "________________________________________________________________"
echo "## Installing nvm  ##                                           "
echo "                                                                "

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

nvm install v16
nvm use v16
nvm ls

echo "                                                                "
echo "________________________________________________________________"
echo "## Installing iexec  ##                                         "
echo "                                                                "

npm i -g iexec &&

echo "                                                                "
echo "________________________________________________________________"
echo "## Preparing the workerpool ##                                      "
echo "                                                                "

# Clone docker Scripts
git clone https://github.com/jjanczur/workerpool-azure-deployment.git
checkExitStatus $?  "Can't pull https://github.com/jjanczur/workerpool-azure-deployment.git"

cd workerpool-azure-deployment/workerpool || exit
checkExitStatus $?  "Can't cd to non existing location workerpool-azure-deployment"

PROD_CORE_WALLET_PASSWORD=${PROD_CORE_WALLET_PASSWORD:-mySecretPassword}

# Init iExec
message "INFO" "Initializing iExec."
iexec init --skip-wallet
checkExitStatus $?  "Can't init iexec"

# Change the chain from viviani to bellecour
message "INFO" "Changing chain to bellecour."
jq '.default = "bellecour"' chain.json > temp.json && mv temp.json chain.json
checkExitStatus $?  "Can't change chain to bellecour"

# Import wallet
message "INFO" "Importing the wallet."
iexec wallet import "$PRIVATE_KEY" --password "$PROD_CORE_WALLET_PASSWORD" --keystoredir .
checkExitStatus $?  "Can't import the wallet"

mv UTC--* workerpool_wallet.json && # rename the wallet

# Deploy workerpool
message "INFO" "Deploying the workerpool."
iexec workerpool init --wallet-file workerpool_wallet.json --password "$PROD_CORE_WALLET_PASSWORD" --keystoredir .
checkExitStatus $?  "Can't init workerpool"

jq --arg desc "$GRAFANA_HOME_NAME" '.workerpool.description = $desc' iexec.json > tmp_file && mv tmp_file iexec.json
checkExitStatus $? "Can't change the name of the pool."

# You can deploy only a single pool from one wallet - handle this scenario with deploying already existing pool
if iexec workerpool deploy --wallet-file workerpool_wallet.json --password "$PROD_CORE_WALLET_PASSWORD" --keystoredir . --chain bellecour 2>&1 >/dev/null; then
  message "INFO" "Pool Deployed to blockchain."
  PROD_POOL_ADDRESS=$(jq -r '.workerpool."134"' deployed.json)
else
  response=$(iexec workerpool deploy --wallet-file workerpool_wallet.json --password "$PROD_CORE_WALLET_PASSWORD" --keystoredir . --chain bellecour 2>&1 >/dev/null)
  PROD_POOL_ADDRESS=$(echo "$response" | grep -o 'deployed at address [^ ]*' | sed 's/deployed at address //')

  # Check if we got the address or the error is connected to something else
  if [ ${#PROD_POOL_ADDRESS} -ne 42 ]; then
    message "ERROR" "Could not deploy the pool: $response"
  fi
fi

# Fetch the IP address of the current machine
PROD_CHAIN_ADAPTER_HOST=$(curl -4 icanhazip.com)
checkExitStatus $?  "Can't check the IP address of the VM"

echo "                                                                "
echo "________________________________________________________________"
echo "## Starting the worker ##                                       "

# Start Workerpool

echo "PROD_CORE_WALLET_PASSWORD=$PROD_CORE_WALLET_PASSWORD" >> .env
echo "WORKER_PASS_ADDRESS=$WORKER_PASS_ADDRESS" >> .env

echo "PROD_CHAIN_ADAPTER_HOST=$PROD_CHAIN_ADAPTER_HOST" >> .env
echo "PROD_CHAIN_ADAPTER_PASSWORD=$PROD_CHAIN_ADAPTER_PASSWORD" >> .env
echo "PROD_GRAFANA_ADMIN_PASSWORD=$PROD_GRAFANA_ADMIN_PASSWORD" >> .env
echo "PROD_MONGO_PASSWORD=$PROD_MONGO_PASSWORD" >> .env

echo "PROD_POOL_ADDRESS=$PROD_POOL_ADDRESS" >> .env

echo "GRAFANA_HOME_NAME=$GRAFANA_HOME_NAME" >> .env



newgrp docker << END
docker-compose up -d
END
