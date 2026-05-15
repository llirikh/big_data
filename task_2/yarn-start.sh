#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: run bash without sudo and by ubuntu user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"

NN_HOST="team-02-nn"
DN_HOSTS=("team-02-dn-00" "team-02-dn-01")
ALL_HOSTS=("${NN_HOST}" "${DN_HOSTS[@]}")

HADOOP_VERSION="3.4.0"
HADOOP_HOME="/home/hadoop/hadoop-${HADOOP_VERSION}"
HADOOP_CONF_DIR="${HADOOP_HOME}/etc/hadoop"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

log() { printf '\n=== %s ===\n' "$*"; }

# 0. Get secrets
SECRETS_FILE="${SCRIPT_DIR}/secrets/secrets.sh"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "ERROR: no ${SECRETS_FILE}" >&2
  echo "        cp secrets/secrets.example.sh secrets/secrets.sh" >&2
  echo "        chmod 600 secrets/secrets.sh && vim secrets/secrets.sh" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${SECRETS_FILE}"
if [[ -z "${SUDO_PASS:-}" || "${SUDO_PASS}" == "CHANGE_ME" ]]; then
  echo "ERROR: update SUDO_PASS in ${SECRETS_FILE}" >&2
  exit 1
fi

remote_sudo() {
  local host="$1"; shift
  { printf '%s\n' "${SUDO_PASS}"; [[ -t 0 ]] || cat; } |
    ssh "${SSH_OPTS[@]}" "ubuntu@${host}" "sudo -S -p '' $*"
}

log "0/6  Check sudo-password on ${NN_HOST}"
if ! remote_sudo "${NN_HOST}" "true" </dev/null; then
  echo "ERROR: sudo-password is wrong" >&2
  exit 1
fi

log "1/6  Check local configs ${CONFIGS_DIR}"
for f in mapred-site.xml yarn-site.xml; do
  if [[ ! -f "${CONFIGS_DIR}/${f}" ]]; then
    echo "ERROR: no ${CONFIGS_DIR}/${f}" >&2
    exit 1
  fi
done

log "2/6  Share configs to ${NN_HOST}"
ssh "${SSH_OPTS[@]}" "ubuntu@${NN_HOST}" 'mkdir -p /tmp/yarn-conf'
scp "${SSH_OPTS[@]}" \
    "${CONFIGS_DIR}/mapred-site.xml" \
    "${CONFIGS_DIR}/yarn-site.xml" \
    "ubuntu@${NN_HOST}:/tmp/yarn-conf/"

log "3/6  Move configs to ${HADOOP_CONF_DIR} by hadoop user"
remote_sudo "${NN_HOST}" "bash -c '
  set -euo pipefail
  install -o hadoop -g hadoop -m 0644 \
      /tmp/yarn-conf/mapred-site.xml ${HADOOP_CONF_DIR}/mapred-site.xml
  install -o hadoop -g hadoop -m 0644 \
      /tmp/yarn-conf/yarn-site.xml  ${HADOOP_CONF_DIR}/yarn-site.xml
  rm -rf /tmp/yarn-conf
'" </dev/null

log "4/6  Share configs to DataNodes and start YARN + HistoryServer"

remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<'REMOTE'
set -euo pipefail
export HADOOP_HOME="/home/hadoop/hadoop-3.4.0"
export PATH="${HADOOP_HOME}/bin:${HADOOP_HOME}/sbin:${PATH}"
CONF="${HADOOP_HOME}/etc/hadoop"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

for dn in team-02-dn-00 team-02-dn-01; do
  echo "  -> scp configs to ${dn}"
  scp ${SSH_OPTS} "${CONF}/mapred-site.xml" "${dn}:${CONF}/mapred-site.xml"
  scp ${SSH_OPTS} "${CONF}/yarn-site.xml"  "${dn}:${CONF}/yarn-site.xml"
done

echo "  -> start-yarn.sh"
"${HADOOP_HOME}/sbin/start-yarn.sh"

echo "  -> mapred --daemon start historyserver (идемпотентно)"
mapred --daemon stop historyserver >/dev/null 2>&1 || true
mapred --daemon start historyserver
REMOTE

log "5/6  Check jps on all nodes"
for host in "${ALL_HOSTS[@]}"; do
  echo "--- ${host} ---"
  remote_sudo "${host}" "-i -u hadoop jps" </dev/null
done

log "6/6  Done"
cat <<'TIP'
Set the tunnel on your local:
  ssh -i ~/.ssh/big_data/id_rsa \
      -L 9870:192.168.10.13:9870  \
      -L 8088:192.168.10.13:8088  \
      -L 19888:192.168.10.13:19888 \
      ubuntu@178.236.25.99

  NameNode       : http://localhost:9870
  ResourceManager: http://localhost:8088
  HistoryServer  : http://localhost:19888
TIP
