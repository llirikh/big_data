# Запуск YARN

Перед начлом: уже развёрнут hdfs-кластер из [task_1](../task_1/README.md)

| Хост            | Сервисы YARN                          |
|-----------------|---------------------------------------|
| `team-02-nn`    | `ResourceManager`, `JobHistoryServer` |
| `team-02-dn-00` | `NodeManager`                         |
| `team-02-dn-01` | `NodeManager`                         |
| `team-02-nn`    | `NodeManager`  |

## Структура каталога

```
task_2/
├── README.md
├── yarn-start.sh             # bash-скрипт, запускается с JumpNode
├── configs/
│   ├── mapred-site.xml       # включает MapReduce поверх YARN
│   └── yarn-site.xml         # адреса RM, aux-services для NodeManager и т.д.
└── secrets/
    ├── secrets.example.sh    # шаблон файла с паролями
    └── secrets.sh            # реальные пароли (в .gitignore)
```

- `configs/` - конфиги для правки и запуска `yarn-start.sh` повторно
- `secrets/secrets.sh` - все пароли, нужные скрипту. Файл в `.gitignore`,
  создаётся копированием из `secrets.example.sh`. Сейчас там
  только `SUDO_PASS` (sudo-пароль пользователя `ubuntu` на нодах
  кластера, тот же что в `ansible-playbook -K` из task_1)

## Как пользоваться скриптом

### 0. Предварительные условия

- Полностью пройден [task_1](../task_1/README.md):
  - HDFS-кластер развёрнут и запущен (`start-dfs.sh`)
  - на JumpNode у пользователя `ubuntu` есть ssh-ключ к `nn`/`dn-00`/`dn-01`
    (`bootstrap.yml`)
  - на NameNode у пользователя `hadoop` есть ssh-ключ, раскатанный
    на все ноды (`roles/hadoop_start`) - им скрипт раскладывает конфиги
    с nn по dn

### 1. Скопировать `task_2/` на JumpNode

С локальной машины (если требуется, явно указать путь к ключу):

```bash
rsync -av task_2/ -e "ssh -i ~/.ssh/big_data/id_rsa" \
      ubuntu@178.236.25.99:~/task_2/
```

### 2. Создать файл с секретами на JumpNode

```bash
ssh -i ~/.ssh/big_data/id_rsa ubuntu@178.236.25.99
cd ~/task_2
cp secrets/secrets.example.sh secrets/secrets.sh
chmod 600 secrets/secrets.sh
vim secrets/secrets.sh   # вписать SUDO_PASS
```

### 3. Запустить скрипт на JumpNode

```bash
cd ~/task_2
./yarn-start.sh
```

Скрипт запускается **без `sudo`** (иначе теряется ssh-ключ `ubuntu`).
`SUDO_PASS` из `secrets/secrets.sh` пробрасывается на каждую ноду
по ssh и скармливается `sudo -S` на удалённой стороне

### 4. Открыть UI

После того как скрипт отработал, с локальной машины поднять туннели:

```bash
ssh -i ~/.ssh/big_data/id_rsa \
    -L 9870:192.168.10.13:9870 \
    -L 8088:192.168.10.13:8088 \
    -L 19888:192.168.10.13:19888 \
    ubuntu@178.236.25.99
```

| URL                       | Что это                |
|---------------------------|------------------------|
| http://localhost:9870     | NameNode (HDFS)        |
| http://localhost:8088     | YARN ResourceManager   |
| http://localhost:19888    | MapReduce HistoryServer|

## Какие шаги делает скрипт и зачем

#### 1. Проверка локальных конфигов
Проверка, что `configs/mapred-site.xml` и `configs/yarn-site.xml`
существуют - чтобы не ловить ошибку посреди работы

#### 2-3. Заливка конфигов на NameNode
JumpNode не имеет ключа к hadoop-пользователю на нодах, поэтому
конфиги сначала копируются `scp`-ом во временную папку
`/tmp/yarn-conf` на `nn` от пользователя `ubuntu`, а затем `sudo install`
кладёт их в `${HADOOP_HOME}/etc/hadoop/` с владельцем `hadoop:hadoop`

Что лежит в конфигах и зачем:
- `mapred-site.xml`
  - `mapreduce.framework.name = yarn` - чтобы MapReduce-задачи
    исполнялись поверх YARN, а не локально
  - `mapreduce.application.classpath` - где контейнерам брать
    jar-ники MapReduce
- `yarn-site.xml`
  - `yarn.nodemanager.aux-services = mapreduce_shuffle` -
    включает shuffle-сервис, без него MR-задачи падают
  - `yarn.nodemanager.env-whitelist` - переменные окружения,
    пробрасываемые в контейнеры
  - `yarn.resourcemanager.hostname/address/resource-tracker.address` -
    говорим NodeManager-ам, куда стучаться к ResourceManager

#### 4. Раздача конфигов по DataNodes и старт YARN
Через `ssh ubuntu@nn` -> `sudo -i -u hadoop bash` исполняется
вложенный скрипт от имени `hadoop`:
1. `scp`-ом раскладывает оба конфига на `team-02-dn-00` и `team-02-dn-01`
   в `${HADOOP_HOME}/etc/hadoop/` (без этого NodeManager-ы не поднимутся
   с правильными настройками)
2. Запускает `sbin/start-yarn.sh` - стартует `ResourceManager` на nn
   и `NodeManager` на каждом worker-е (включая nn, т. к. он в `workers`)
3. Запускает `mapred --daemon start historyserver` - JobHistoryServer
   на nn, чтобы видеть историю выполненных job-ов в UI на 19888 порте.

#### 5. Проверка `jps`
На каждой ноде запускается `jps` от имени `hadoop`. Ожидаем увидеть:
- `team-02-nn`: `NameNode`, `SecondaryNameNode`, `DataNode`,
  `ResourceManager`, `NodeManager`, `JobHistoryServer`
- `team-02-dn-0X`: `DataNode`, `NodeManager`

#### 6. Подсказка по туннелям
Печатает готовую `ssh -L ...` команду для проброса UI-портов

## Идемпотентность

Скрипт можно запускать повторно:
- конфиги перезаписываются `install`-ом (атомарная замена)
- `start-yarn.sh` корректно отрабатывает, если демоны уже запущены
- `historyserver` сначала останавливается, потом запускается заново
