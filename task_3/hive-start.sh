#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
  echo "ERROR: run without sudo as the ubuntu user" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/conf"

JN_HOST="team-02-jn"
NN_HOST="team-02-nn"
DN01_HOST="team-02-dn-01"

HIVE_VERSION="4.0.0-alpha-2"
HIVE_DIR="apache-hive-${HIVE_VERSION}-bin"
HIVE_TGZ="${HIVE_DIR}.tar.gz"
HIVE_URL="https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_TGZ}"
HIVE_HOME="/home/hadoop/${HIVE_DIR}"

JDBC_VERSION="42.7.4"
JDBC_JAR="postgresql-${JDBC_VERSION}.jar"
JDBC_URL="https://jdbc.postgresql.org/download/${JDBC_JAR}"

HADOOP_VERSION="3.4.0"
HADOOP_HOME_REMOTE="/home/hadoop/hadoop-${HADOOP_VERSION}"

PG_VERSION="16"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

log() { printf '\n=== %s ===\n' "$*"; }

SECRETS_FILE="${SCRIPT_DIR}/secrets/secrets.sh"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "ERROR: no ${SECRETS_FILE}" >&2
  exit 1
fi
source "${SECRETS_FILE}"
if [[ -z "${SUDO_PASS:-}"   || "${SUDO_PASS}"   == "CHANGE_ME" ]]; then
  echo "ERROR: set SUDO_PASS in ${SECRETS_FILE}" >&2; exit 1
fi
if [[ -z "${HIVE_DB_PASS:-}" || "${HIVE_DB_PASS}" == "CHANGE_ME" ]]; then
  echo "ERROR: set HIVE_DB_PASS in ${SECRETS_FILE}" >&2; exit 1
fi

remote_sudo() {
  local host="$1"; shift
  { printf '%s\n' "${SUDO_PASS}"; [[ -t 0 ]] || cat; } |
    ssh "${SSH_OPTS[@]}" "ubuntu@${host}" "sudo -S -p '' $*"
}

log "0/8 sanity"
for f in postgresql.conf pg_hba.conf hive-site.xml; do
  [[ -f "${CONF_DIR}/${f}" ]] || { echo "ERROR: no ${CONF_DIR}/${f}" >&2; exit 1; }
done
remote_sudo "${DN01_HOST}" "true" </dev/null
remote_sudo "${NN_HOST}"   "true" </dev/null

log "1/8 postgres on dn-01"
remote_sudo "${DN01_HOST}" "bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s postgresql >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y postgresql
fi
systemctl enable --now postgresql
REMOTE

log "2/8 metastore db + hive role"
remote_sudo "${DN01_HOST}" "-u postgres psql -v ON_ERROR_STOP=1 -d postgres" <<SQL
SELECT 'CREATE DATABASE metastore'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='metastore')\gexec

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='hive') THEN
    CREATE ROLE hive LOGIN PASSWORD '${HIVE_DB_PASS}';
  ELSE
    ALTER ROLE hive WITH LOGIN PASSWORD '${HIVE_DB_PASS}';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE "metastore" TO hive;
ALTER DATABASE metastore OWNER TO hive;
SQL

log "3/8 push postgres configs"
scp "${SSH_OPTS[@]}" \
    "${CONF_DIR}/postgresql.conf" \
    "${CONF_DIR}/pg_hba.conf" \
    "ubuntu@${DN01_HOST}:/tmp/"
remote_sudo "${DN01_HOST}" "bash -s" <<REMOTE
set -euo pipefail
install -o postgres -g postgres -m 0644 /tmp/postgresql.conf ${PG_CONF_DIR}/postgresql.conf
install -o postgres -g postgres -m 0640 /tmp/pg_hba.conf    ${PG_CONF_DIR}/pg_hba.conf
rm -f /tmp/postgresql.conf /tmp/pg_hba.conf
systemctl restart postgresql
REMOTE

log "4/8 postgres-client on nn"
remote_sudo "${NN_HOST}" "bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s postgresql-client-${PG_VERSION} >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y postgresql-client-${PG_VERSION}
fi
REMOTE
ssh "${SSH_OPTS[@]}" "ubuntu@${NN_HOST}" \
  "PGPASSWORD='${HIVE_DB_PASS}' psql -h ${DN01_HOST} -p 5432 -U hive -d metastore -c '\\q'"

log "5/8 hive on nn"
RENDERED_HIVE_SITE="$(mktemp)"
trap 'rm -f "${RENDERED_HIVE_SITE}"' EXIT
sed "s|__HIVE_DB_PASS__|${HIVE_DB_PASS}|g" \
    "${CONF_DIR}/hive-site.xml" > "${RENDERED_HIVE_SITE}"

scp "${SSH_OPTS[@]}" "${RENDERED_HIVE_SITE}" "ubuntu@${NN_HOST}:/tmp/hive-site.xml"

remote_sudo "${NN_HOST}" "bash -s" <<REMOTE
set -euo pipefail
install -o hadoop -g hadoop -m 0640 /tmp/hive-site.xml /tmp/hive-site.staged
rm -f /tmp/hive-site.xml
REMOTE

remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
cd /home/hadoop

if [[ ! -d "${HIVE_DIR}" ]]; then
  if [[ ! -f "${HIVE_TGZ}" ]]; then
    wget -q "${HIVE_URL}"
  fi
  tar -xzf "${HIVE_TGZ}"
fi

if ! ls ${HIVE_HOME}/bin/postgresql-*.jar >/dev/null 2>&1; then
  cd ${HIVE_HOME}/bin
  wget -q "${JDBC_URL}"
  cd /home/hadoop
fi

install -m 0640 /tmp/hive-site.staged ${HIVE_HOME}/conf/hive-site.xml
rm -f /tmp/hive-site.staged

PROFILE=/home/hadoop/.profile
if ! grep -q 'HIVE_HOME=' "\${PROFILE}"; then
  cat >> "\${PROFILE}" <<'PROF'

export HIVE_HOME=/home/hadoop/${HIVE_DIR}
export HIVE_CONF_DIR=\$HIVE_HOME/conf
export HIVE_AUX_JARS_PATH=\$HIVE_HOME/lib/*
export PATH=\$PATH:\$HIVE_HOME/bin
PROF
fi
REMOTE

log "6/8 hdfs dirs + schematool"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export HIVE_HOME=${HIVE_HOME}
export HIVE_CONF_DIR=\${HIVE_HOME}/conf
export HIVE_AUX_JARS_PATH=\${HIVE_HOME}/lib/*
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${PATH}:\${HIVE_HOME}/bin

hdfs dfs -mkdir -p /tmp
hdfs dfs -mkdir -p /user/hive/warehouse
hdfs dfs -chmod g+w /tmp
hdfs dfs -chmod g+w /user/hive/warehouse

if PGPASSWORD='${HIVE_DB_PASS}' psql -h ${DN01_HOST} -U hive -d metastore -tAc \
     "SELECT 1 FROM information_schema.tables WHERE table_name='VERSION'" | grep -q 1
then
  echo "  schema already initialised"
else
  cd \${HIVE_HOME}
  bin/schematool -dbType postgres -initSchema
fi
REMOTE

log "7/8 start hiveserver2"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export HIVE_HOME=${HIVE_HOME}
export HIVE_CONF_DIR=\${HIVE_HOME}/conf
export HIVE_AUX_JARS_PATH=\${HIVE_HOME}/lib/*
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${PATH}:\${HIVE_HOME}/bin

pkill -u hadoop -f 'proc_hiveserver2|HiveServer2' >/dev/null 2>&1 || true
sleep 2

nohup hive \
  --hiveconf hive.server2.enable.doAs=false \
  --hiveconf hive.security.authorization.enabled=false \
  --service hiveserver2 \
  >> /tmp/hs2.log 2>> /tmp/hs2e.log < /dev/null &
disown || true

for i in \$(seq 1 60); do
  if ss -ltn 2>/dev/null | grep -q ':5433 '; then
    echo "  listening on :5433"
    break
  fi
  sleep 2
done

jps | grep -E 'RunJar|HiveServer2' || true
REMOTE

log "8/8 smoke-test"
remote_sudo "${NN_HOST}" "-i -u hadoop bash -s" <<REMOTE
set -euo pipefail
export HADOOP_HOME=${HADOOP_HOME_REMOTE}
export HIVE_HOME=${HIVE_HOME}
export PATH=\${HADOOP_HOME}/bin:\${PATH}:\${HIVE_HOME}/bin
beeline -u jdbc:hive2://${NN_HOST}:5433 -n scott -p tiger -e 'SHOW DATABASES;'
REMOTE

cat <<TIP

=== Done ===
HiveServer2 is up on ${NN_HOST}:5433.

  ssh -i ~/.ssh/big_data/id_rsa \\
      -L 9870:192.168.10.13:9870  \\
      -L 8088:192.168.10.13:8088  \\
      -L 19888:192.168.10.13:19888 \\
      -L 10002:192.168.10.13:10002 \\
      ubuntu@178.236.25.99
TIP
