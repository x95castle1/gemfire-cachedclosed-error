#!/usr/bin/env bash
# Starts a Geode locator and server in one container, creates the regions the client uses,
# then tails the server log so the container stays up.
set -euo pipefail

HOST_FOR_CLIENTS="${HOSTNAME_FOR_CLIENTS:-geode}"

cd /data
# gfsh talks to the JMX manager on localhost: the "geode" Service has no endpoints until this
# pod is Ready, which only happens after the regions exist.
gfsh \
  -e "start locator --name=locator --port=10334 --hostname-for-clients=${HOST_FOR_CLIENTS} --J=-Xmx256m --J=-Dgemfire.jmx-manager-hostname-for-clients=localhost" \
  -e "start server --name=server --server-port=40404 --hostname-for-clients=${HOST_FOR_CLIENTS} --locators=localhost[10334] --J=-Xmx512m" \
  -e "connect --jmx-manager=localhost[1099]" \
  -e "create region --name=Account --type=REPLICATE" \
  -e "create region --name=Config --type=REPLICATE" \
  -e "put --region=/Config --key=CONFIG_TIMESTAMPpsg --value=$(date +%s)"

touch /data/ready
exec tail -F /data/server/server.log
