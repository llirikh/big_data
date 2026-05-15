# Развёртывание Hadoop

## Инфраструктура

| Хост            | Внутренний IP   | Роль                                   |
|-----------------|-----------------|----------------------------------------|
| `team-02-jn`    | `192.168.10.57` | JumpNode (внешний `178.236.25.99`)     |
| `team-02-nn`    | `192.168.10.13` | NameNode + SecondaryNameNode + DataNode|
| `team-02-dn-00` | `192.168.10.11` | DataNode                               |
| `team-02-dn-01` | `192.168.10.12` | DataNode                               |

Внутренние ноды не доступны извне и принимают ssh от JumpNode
только по паролю. Поэтому **Ansible запускается с самой JumpNode**

## Что нужно перед запуском

### На рабочей машине

1. Зайти на JumpNode (если требуется надо указать ключ):
   ```bash
   ssh ubuntu@178.236.25.99 -i ~/.ssh/big_data/id_rsa
   ```
2. Скопировать туда содержимое каталога `task_1/ansible/`, например:
   ```bash
   # выполнить с локальной машины
   rsync -av task_1/ansible/ ubuntu@178.236.25.99:~/ansible/
   ```
   или через гит.

### На JumpNode

3. Поставить Ansible:
   ```bash
   sudo apt update && sudo apt install -y ansible
   cd ~/ansible
   ansible-galaxy collection install -r requirements.yml
   ```
4. Создать файл с секретами (пароль пользователя `hadoop`):
   ```bash
   cp group_vars/all/secrets.example.yml group_vars/all/secrets.yml
   $EDITOR group_vars/all/secrets.yml
   ```
5. На всех 4 хостах должна быть установлена Java (она уже установлена)


## Запуск (на JumpNode)

В терминале выполнить:

```bash
cd ~/ansible

# 0. ОДИН РАЗ: bootstrap. Сгенерирует ssh-ключ для ubuntu на JumpNode,
#    добавит его в локальный authorized_keys и раскатит файл
#    authorized_keys на ноды кластера через sshpass + пароль ubuntu.
#    Флаг -K запросит sudo-пароль пользователя ubuntu на JumpNode
ansible-playbook bootstrap.yml -K

# 1. Проверить, что все ноды отвечают
ansible cluster -m ping

# 2. Развернуть HDFS-кластер
#    -K тоже обязателен: become используется на всех 4 хостах
#    (sudo-пароль ubuntu должен совпадать на jn/nn/dn-00/dn-01).
ansible-playbook playbook.yml -K
```

После пробросить порт UI:

```bash
ssh -L 9870:192.168.10.13:9870 ubuntu@178.236.25.99
# открыть http://localhost:9870
```

Повторный запуск `playbook.yml` не изменяет состояние системы:
- архив повторно не скачивается, если `bin/hadoop` уже есть
- NameNode форматируется только при отсутствии
  `/tmp/hadoop-hadoop/dfs/name/current/VERSION`
- `start-dfs.sh` Hadoop сам не падает, если демоны уже запущены


## Объяснение плейбука

### `bootstrap.yml` (одноразово, до основного плейбука)
1. На JumpNode ставит `sshpass` (нужен, чтобы скрипт мог ввести пароль
   за вас)
2. Генерирует на JumpNode ed25519-ключ для пользователя `ubuntu`
   (если ещё нет)
3. Дописывает публичную часть в собственный `~ubuntu/.ssh/authorized_keys`
   на JumpNode
4. Запрашивает пароль `ubuntu` на нодах и `scp`-ом раскатывает
   `authorized_keys` с JumpNode на каждую ноду кластера

После этого ssh с JumpNode на любую ноду работает по ключу

### `playbook.yml`

Пять блоков, выполняющихся по порядку

#### Play 1 — `common` (роль `roles/common`)
Готовит `/etc/hosts` на JumpNode и на всех внутренних нодах:
- комментирует `127.0.0.1 localhost` и IPv6-строки
- добавляет четыре строки с внутренними IP и именами
  (`team-02-jn`, `team-02-nn`, `team-02-dn-00`, `team-02-dn-01`)

#### Play 2 — `hadoop_user` (роль `roles/hadoop_user`)
- Создаёт группу и пользователя `hadoop` на всех нодах кластера.
  Пароль берётся из `group_vars/all/secrets.yml`
  (`hadoop_password`) и хешируется фильтром `password_hash('sha512')`.
- Подтверждает, что pubkey ubuntu из JumpNode лежит
  в `authorized_keys` на каждой ноде

#### Play 3 — `hadoop_install` (роль `roles/hadoop_install`)
- Один раз качает `hadoop-3.4.0.tar.gz` на JumpNode
- С JumpNode `scp`-ом раскладывает архив на каждую ноду кластера в
  `/home/ubuntu/`, затем `sudo mv` + `chown` переносит его в
  `/home/hadoop/`
- Распаковывает архив в `/home/hadoop/hadoop-3.4.0/`
- Дописывает в `~hadoop/.profile` экспорты `JAVA_HOME`, `HADOOP_HOME`,
  `PATH`

#### Play 4 — `hadoop_config` (роль `roles/hadoop_config`)
Кладёт четыре конфига в `$HADOOP_HOME/etc/hadoop/`:
- `hadoop-env.sh` - экспорт `JAVA_HOME`
- `core-site.xml` - `fs.defaultFS = hdfs://team-02-nn:9000`
- `hdfs-site.xml` - `dfs.replication = 3`
- `workers` - список DataNode-узлов (NameNode тоже в этом списке)

Файл `workers` рендерится из `groups['workers']` инвентори, поэтому
чтобы добавить/убрать DataNode нужно поправить `inventory.ini`

#### Play 5 — `hadoop_start` (роль `roles/hadoop_start`)
- Генерирует ssh-ключ для пользователя `hadoop` на NameNode и
  раскладывает **и публичную, и приватную** часть на все ноды
  (потому что `start-dfs.sh` ходит ssh-ом с NameNode на каждый worker от имени `hadoop`)
- Обновление `~hadoop/.ssh/known_hosts
- Один раз форматирует NameNode (`hdfs namenode -format`) - только
  если каталога метаданных ещё нет
- Запускает кластер через `sbin/start-dfs.sh`
- Прогоняет `jps` на каждой ноде и печатает результат (там должны
  быть `NameNode`, `SecondaryNameNode`, `DataNode` на NN и
  `DataNode` на DN-нодах)

