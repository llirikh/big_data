# Установка Hive + загрузка Parquet

Перед началом: уже развёрнуты HDFS-кластер из [task_1](../task_1/README.md)
и YARN из [task_2](../task_2/README.md).

| Хост            | Роль для Hive                                       |
|-----------------|-----------------------------------------------------|
| `team-02-jn`    | место запуска скриптов                              |
| `team-02-nn`    | HiveServer2 + metastore-client + schematool         |
| `team-02-dn-01` | Postgres 16 c БД `metastore` для Hive Metastore     |

## Структура каталога

```
task_3/
├── README.md
├── hive-start.sh             # развёртывание Hive
├── load-data.sh              # загрузка test.zstd.parquet в Hive
├── conf/
│   ├── postgresql.conf       
│   ├── pg_hba.conf           
│   └── hive-site.xml         
├── secrets/
│   ├── secrets.example.sh    # шаблон файла с паролями
│   └── secrets.sh            # реальные пароли (в .gitignore)
└── test/
    └── ...                   # сюда кладётся test.zstd.parquet (в .gitignore)
```

- `conf/postgresql.conf` — стандартный конфиг Ubuntu + строка
  `listen_addresses = 'team-02-dn-01'`.
- `conf/pg_hba.conf` — стандартный + закомментированная строка для
  `127.0.0.1/32 scram-sha-256` и две дополнительные строки
  `host metastore hive team-02-jn|team-02-nn password`.
- `conf/hive-site.xml` — содержит плейсхолдер `__HIVE_DB_PASS__`,
  который `hive-start.sh` заменяет на значение `HIVE_DB_PASS` из
  `secrets/secrets.sh` перед заливкой на nn
- `secrets/secrets.sh` — нужны `SUDO_PASS` и `HIVE_DB_PASS` (любой непустой,
  попадает в `CREATE USER hive` и в `hive-site.xml`).

---

## 1. `hive-start.sh` — развёртывание Hive

### Как пользоваться

С локальной машины:

```bash
rsync -av task_3/ -e "ssh -i ~/.ssh/big_data/id_rsa" \
      ubuntu@178.236.25.99:~/task_3/
```

На JumpNode:

```bash
ssh -i ~/.ssh/big_data/id_rsa ubuntu@178.236.25.99

cd ~/task_3
cp secrets/secrets.example.sh secrets/secrets.sh
chmod 600 secrets/secrets.sh
vim secrets/secrets.sh        # вписать SUDO_PASS и HIVE_DB_PASS
./hive-start.sh
```

После успешного завершения HiveServer2 слушает `team-02-nn:5433`.
Для UI с локальной машины:

```bash
ssh -i ~/.ssh/big_data/id_rsa \
    -L 9870:192.168.10.13:9870  \
    -L 8088:192.168.10.13:8088  \
    -L 19888:192.168.10.13:19888 \
    -L 10002:192.168.10.13:10002 \
    ubuntu@178.236.25.99
```

| URL                       | Что это                |
|---------------------------|------------------------|
| http://localhost:9870     | NameNode (HDFS)        |
| http://localhost:8088     | YARN ResourceManager   |
| http://localhost:19888    | MR HistoryServer       |
| http://localhost:10002    | HiveServer2 Web UI     |

### Шаги `hive-start.sh`

Скрипт идёт с JumpNode и ходит на dn-01 и nn через
`ssh ubuntu@HOST` с пробросом `SUDO_PASS`

- **0.** Проверяет наличие `conf/postgresql.conf`,
  `conf/pg_hba.conf`, `conf/hive-site.xml` и что sudo-пароль рабочий
  на nn и dn-01
- **1.** `apt-get install -y postgresql`
  (идемпотентно через `dpkg -s`) + `systemctl enable --now postgresql`.
- **2.** Через `sudo -u postgres psql`
  создаёт БД `metastore` и роль `hive` с паролем `HIVE_DB_PASS`.
  `WHERE NOT EXISTS ... \gexec` / `DO $$ ... $$` — повторный запуск
  не падает.
- **3.** `scp` `postgresql.conf` и `pg_hba.conf`
  на dn-01, `install -o postgres -g postgres` кладёт их в
  `/etc/postgresql/16/main/`, `systemctl restart postgresql`.
- **4.** Ставит `postgresql-client-16` на nn
  и из ubuntu@nn делает `psql -h dn-01 ... -c '\q'` — подтверждение,
  что соединение и `pg_hba` работают.
- **5.** Локально `sed`-ом подставляет `HIVE_DB_PASS`
  в `conf/hive-site.xml`, `scp`-ом отправляет результат на nn в
  `/tmp/`. Далее на nn под hadoop: wget Hive 4.0.0-alpha-2, распаковка,
  wget `postgresql-42.7.4.jar` в `${HIVE_HOME}/bin/`, установка
  `hive-site.xml`, единоразовая дозапись `HIVE_HOME / HIVE_CONF_DIR /
  HIVE_AUX_JARS_PATH / PATH` в `~hadoop/.profile`.
- **6.** Под hadoop на nn:
  `hdfs dfs -mkdir -p /tmp /user/hive/warehouse` + `chmod g+w`.
  Если в metastore нет таблицы `VERSION` —
  `bin/schematool -dbType postgres -initSchema`, иначе пропуск.
- **7.** Под hadoop на nn: `pkill -f hiveserver2`
  гасит предыдущий процесс, `nohup hive --service hiveserver2 ... &`
  стартует новый с `hive.server2.enable.doAs=false` и
  `hive.security.authorization.enabled=false`. Логи в
  `/tmp/hs2.log` / `/tmp/hs2e.log`. Ждём порт `:5433` (до 2 минут).
- **8.** `beeline -u jdbc:hive2://team-02-nn:5433
  -e 'SHOW DATABASES;'` — должен показать `default`.

Скрипт можно перезапускать:
- проверки `dpkg -s` / `pg_database` / `pg_roles` /
  `information_schema` предотвращают повторные `apt-get install`,
  `CREATE DATABASE`, `CREATE ROLE`, `schematool -initSchema`;
- конфиги Postgres и `hive-site.xml` перезаписываются `install`-ом,
  `restart postgresql` гарантирует перечитывание;
- блок `export HIVE_HOME=...` дозаписывается в `.profile` только
  если такого экспорта там ещё нет;
- HiveServer2 сначала останавливается (`pkill`), потом стартует.

---

## 2. `load-data.sh` — загрузка test.zstd.parquet в Hive

### Предварительный шаг (на локальной машине)

Сгенерировать parquet и закинуть его на JN, например в `~/task_3/test/`:

```bash
scp -i ~/.ssh/big_data/id_rsa test/test.zstd.parquet \
    ubuntu@178.236.25.99:~/task_3/test/
```

### Запуск

На JumpNode:

```bash
cd ~/task_3
./load-data.sh                                    # ждёт ./test/test.zstd.parquet
./load-data.sh /home/ubuntu/test.zstd.parquet     # любой явный путь
```

### Шаги `load-data.sh`

Скрипт работает с jn, но все hadoop/hive-операции выполняются на nn
через `ssh ubuntu@nn` -> `sudo -i -u hadoop bash -s`.

- **1.** Проверяет, что `secrets.sh` есть и что
  parquet-файл действительно лежит на jn (если нет — печатает
  подсказку). Также проверяет sudo-доступ на nn.
- **2.** `scp` parquet с jn в `/tmp/` на nn,
  затем `install -o hadoop -g hadoop` перекладывает его в
  `/home/hadoop/`.
- **3.** Под hadoop на nn:
  `hdfs dfs -mkdir -p /raw`, удаление предыдущей копии (идемпотентно),
  `hdfs dfs -put /home/hadoop/test.zstd.parquet /raw/`.
- **4.** Под hadoop на nn через
  `beeline -u jdbc:hive2://team-02-nn:5433`:
  `DROP TABLE IF EXISTS test_table;` →
  `CREATE TABLE test_table (...) STORED AS PARQUET;` со схемой,
  совпадающей со схемой нашего parquet (8 колонок: `user_id`,
  `session_id`, `event_ts`, `event_type`, `country`, `device`,
  `revenue`, `is_premium`). Затем
  `LOAD DATA INPATH '/raw/test.zstd.parquet' INTO TABLE test_table;`
  — это move, после загрузки файл переезжает из `/raw/` в
  `/user/hive/warehouse/test_table/`.