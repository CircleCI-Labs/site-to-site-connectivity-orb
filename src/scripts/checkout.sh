#!/bin/bash

echo "Cloning repository from: $REPO_URL"

mkdir ~/.ssh || true
ssh-keyscan -p $TCP_PORT $TCP_ADDR >> ~/.ssh/known_hosts
GIT_TERMINAL_PROMPT=0 git clone $REPO_URL

echo "Repository cloned successfully."
