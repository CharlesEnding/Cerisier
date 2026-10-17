#!/usr/bin/env bash
set -euo pipefail

sudo chown -R "$USER":"$USER" ~/Cerisier
chmod -R a+rwX ~/Cerisier
chmod +x bin/server/cerisier_server 
