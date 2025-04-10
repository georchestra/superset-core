#!/bin/bash

# Disable SCARF analytics reporting
export SCARF_ANALYTICS=false

# Use Node 20 (code "iron")
source ~/.nvm/nvm.sh
nvm install lts/iron
nvm use lts/iron

# Install dependencies from `package-lock.json`
npm --prefix superset-frontend prune
npm --prefix superset-frontend install
npm --prefix superset-frontend run build

# Build i18n support
npm --prefix superset-frontend run build-translation
pybabel compile -d superset/translations | true
