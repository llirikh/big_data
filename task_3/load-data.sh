#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: run without sudo as the ubuntu user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARQUET_LOCAL="${1:-${SCRIPT_DIR}/test/test.zstd.parquet}"
PARQUET_NAME="$(basename "${PARQUET_LOCAL}")"

NN_HOST="team-02-nn"

HIVE_VERSION="4.0.0-alpha-2"
HIVE_HOME="/home/hadoop/apache-hive-${HIVE_VERSION}-bin"
HADOOP_VERSION="3.4.0"
HADOOP_HOME_REMOTE="/home/hadoop/hadoop-${HADOOP_VERSION}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

log() { printf '\n=== %s ===\n' "$*"; }

SECRETS_FILE="${SCRIPT_DIR}/secrets/secrets.sh"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "ERROR: no ${SECRETS_FILE}" >&2; exit 1
fi
source "${SECRETS_FILE}"
: "${SUDO_PASS:?need SUDO_PASS in secrets.sh}"

remote_sudo() {
  local host="$1"; shift
  { printf '%s\n' "${SUDO_PASS}"; [[ -t 0 ]] || cat; } |
    ssh "${SSH_OPTS[@]}" "ubuntu@${host}" "sudo -S -p '' $*"
}

log "1/5 check parquet"
if [[ ! -f "${PARQUET_LOCAL}" ]]; then
  cat >&2 <<EOF
ERROR: ${PARQUET_LOCAL} not found on JumpNode.

    python3 task_3/test/gen_parquet.py
    scp -i ~/.ssh/big_data/id_rsa task_3/test/test.zstd.parquet \\
        ubuntu@178.236.25.99:~/task_3/test/
EOF
  exit 1
fi
remote_sudo "${NN_HOST}" "true" </dev/null

log "2/5 scp parquet to nn"
scp "${SSH_OPTS[@]}" "${PARQUET_LOCAL}" "ubuntu@${NN_HOST}:/tmp/${PARQUET_NAME}"
remote_sudo "${NN_HOST}" "bash -s" <<REMOTE
set -euo pipefail
install -o hadoop -g hadoop -m 0644 /tmp/${PARQUET_NAME} /home/hadoop/${PARQUET_NAME}
rm -f /tmp/${PARQUET_NAME}
REMOTE

log "3/5 hdfs put"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${PATH}

hdfs dfs -mkdir -p /raw
hdfs dfs -test -e /raw/${PARQUET_NAME} && hdfs dfs -rm -skipTrash /raw/${PARQUET_NAME} || true
hdfs dfs -put /home/hadoop/${PARQUET_NAME} /raw/
hdfs dfs -ls /raw/${PARQUET_NAME}
REMOTE

log "4/5 create table + load"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export HIVE_HOME=${HIVE_HOME}
export PATH=\${HADOOP_HOME}/bin:\${PATH}:\${HIVE_HOME}/bin

beeline -u jdbc:hive2://${NN_HOST}:5433 -n scott -p tiger --silent=false <<'SQL'
DROP TABLE IF EXISTS test_table;

CREATE TABLE test_table (
  user_id    BIGINT,
  session_id BIGINT,
  event_ts   TIMESTAMP,
  event_type STRING,
  country    STRING,
  device     STRING,
  revenue    DOUBLE,
  is_premium BOOLEAN
)
STORED AS PARQUET;

LOAD DATA INPATH '/raw/${PARQUET_NAME}' INTO TABLE test_table;
SQL
REMOTE

log "5/5 verify"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export HIVE_HOME=${HIVE_HOME}
export PATH=\${HADOOP_HOME}/bin:\${PATH}:\${HIVE_HOME}/bin

beeline -u jdbc:hive2://${NN_HOST}:5433 -n scott -p tiger --silent=false <<'SQL'
SELECT COUNT(*) AS rows FROM test_table;
SELECT event_type, COUNT(*) AS n
  FROM test_table
 GROUP BY event_type
 ORDER BY n DESC;
SELECT * FROM test_table LIMIT 5;
SQL
REMOTE

echo
echo "=== Done. test_table is populated. ==="
