#!/bin/bash

REPO=$REPO
NAME=$NAME

cd /home/docker/actions-runner || exit

# Token management: Support both PAT_TOKEN and REG_TOKEN
if [ -n "$PAT_TOKEN" ]; then
  # Use PAT to generate registration token programmatically
  echo "Using PAT_TOKEN to generate registration token..."
  REG_TOKEN=$(curl -s -X POST -H "Authorization: token ${PAT_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO}/actions/runners/registration-token" | jq -r .token)

  if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    echo "Failed to generate registration token. Check your PAT_TOKEN and repository."
    exit 1
  fi
  echo "Registration token generated successfully."

elif [ -n "$REG_TOKEN" ]; then
  # Use provided registration token directly
  echo "Using provided REG_TOKEN..."

else
  echo "Error: Neither PAT_TOKEN nor REG_TOKEN is defined."
  echo "Please provide either PAT_TOKEN (for dynamic token generation) or REG_TOKEN (direct token)."
  exit 1
fi

echo "Registering runner..."
./config.sh --url https://github.com/${REPO} --token ${REG_TOKEN} --name ${NAME}

cleanup() {
  echo "Removing runner..."

  if [ -n "$PAT_TOKEN" ]; then
    # Generate a new removal token using PAT
    REMOVE_TOKEN=$(curl -s -X POST -H "Authorization: token ${PAT_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${REPO}/actions/runners/remove-token" | jq -r .token)
    ./config.sh remove --unattended --token ${REMOVE_TOKEN}
  else
    # Use the registration token for removal
    ./config.sh remove --unattended --token ${REG_TOKEN}
  fi
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
wait $!
