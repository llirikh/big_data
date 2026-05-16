#!/usr/bin/env bash

# sudo password of "ubuntu" on every cluster node
# (same value as ansible-playbook -K in task_1 and SUDO_PASS in task_2)
SUDO_PASS="CHANGE_ME"

# password used by the "hive" Postgres role and embedded in hive-site.xml.
# Anything non-empty works for the lab; it is shared between three places:
#   1. CREATE USER hive WITH PASSWORD ... on team-02-dn-01
#   2. hive-site.xml -> javax.jdo.option.ConnectionPassword
#   3. PGPASSWORD when hive-start.sh runs psql checks from jn / nn
HIVE_DB_PASS="CHANGE_ME"
