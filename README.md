# PostgreSQL 高可用集群安装说明

该安装包实现了 TP（PostgreSQL）的高可用和主备双集群的高可用。高可用依赖 `tp_etcd`、`patroni`、`tp_vip` 服务，并依赖 miniconda3 打包的 Python 环境。

## 服务状态检查

可以使用下面的命令查看各服务的运行情况：

```bash
systemctl status tp_etcd
systemctl status patroni
systemctl status tp_vip
```

下面的命令可以查看 patroni 集群的情况：

```bash
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml list
```

## 使用注意事项

**主备集群都是如下要求：**

1. 使用 root 用户执行该脚本，且各服务器之间 root 用户已经配置互信
2. 已经创建 openpie 用户，该用户运行 TP
3. 每个集群部署的环境必须是 3 台服务器
4. 各服务器的防火墙已关闭
5. 各服务器已配置时钟同步，各服务器的时间需一致
6. 每个服务器使用的网口需要一样，如不一样需要自行去每个服务器上修改 `${ha_tp_dir}/tp_vip/vip_manager.yml` 里的配置
7. miniconda3 依赖的环境已经固定，必须安装在 `/opt` 下
8. 每次重新安装前，删除 `ha_pieclouddb_tp` 的部署目录，停用 `tp_etcd`、`patroni`、`tp_vip` 服务

## 主集群安装使用步骤

### 1. 环境准备
按上面的注意事项准备主集群安装环境

### 2. 配置文件修改
修改 `ha_pieclouddb_tp.con` 配置文件，特别是对主集群各主机名、IP 和虚拟 IP 使用网口及其 IP 的修改

### 3. 执行安装
执行方式为：
```bash
./main_install.sh
```

## 备集群安装使用步骤

### 1. 环境准备
按上面的注意事项准备备集群安装环境，主备集群之间所有服务器的网络需互通

### 2. 配置文件修改
修改 `ha_pieclouddb_tp.con` 配置文件，特别是对备集群各主机名、IP 和虚拟 IP 使用网口及其 IP 的修改，还有连接主集群的信息

### 3. 执行安装
执行方式为：
```bash
./init_standby_cluster.sh
```

## 备集群使用注意事项

### 1. 运行模式
备集群正常为只读模式

### 2. 数据同步机制
备集群是通过 standby leader 从主集群的 leader 复制数据，而 leader 和 standby leader 在各自的集群内是可能移动的

### 3. 停止同步的影响
备集群停止从主集群同步后是可以正常读写的，但会使用新的时间线，不能继续从主集群同步

### 4. 停止同步的方法
备集群上执行如下操作来停止从主集群同步：

```bash
# 暂停集群操作
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml pause

# 编辑配置
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml edit-config
```

删除如下内容，并确认保存：

```yaml
standby_cluster:
  host: 主集群VIP或IP
  port: 5432
  primary_slot_name: standby01
  create_replica_methods:
  - basebackup
```

恢复集群操作：
```bash
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml resume
```

## 主备集群切换与回切

仓库提供 `dr_switchover.sh` 用于两个 Patroni 集群之间的计划切换。命令分别在两套集群自己的运维机上执行，每台运维机只需以 root SSH 免密访问本集群节点；不需要能同时访问两套集群的公共运维机。

当前环境可直接从 `dr_switchover.primary.conf.example` 和 `dr_switchover.standby.conf.example` 复制配置。通用模板为 `dr_switchover.conf.example`。两套环境的方向性配置如下：

| 配置 | 主集群 A | 备集群 B |
| --- | --- | --- |
| 节点 | `10.24.11.158-160` | `10.24.11.232-234` |
| 本集群 VIP | `10.24.11.201` | `10.24.11.221` |
| `peer_cluster_vip` | `10.24.11.221` | `10.24.11.201` |
| `peer_cluster_pg_port` | `5432` | `5432` |
| `local_replication_slot_name` | `dr_cluster_a` | `dr_cluster_b` |
| `peer_replication_slot_name` | `dr_cluster_b` | `dr_cluster_a` |

`local_replication_slot_name` 是本集群重建为备集群时在对端使用的槽；`peer_replication_slot_name` 是对端重建时需要本集群创建的槽。数据库密码由脚本从已部署的 Patroni 配置读取，不写入 DR 配置文件。

切换会执行以下不可逆运维动作：暂停并停止当前可写集群以防止双主，停止 VIP；提升备集群；最后清理旧集群的 Patroni DCS 状态，备份其 Patroni 配置，将旧集群每个节点的数据目录重命名为 `*.before_dr_<时间戳>`，并通过 `basebackup` 重建为新主集群的备集群。

1. 在集群 A 的运维机执行停写并停止服务：

```bash
chmod 750 dr_switchover.sh
./dr_switchover.sh fence \
  --conf ./dr_switchover.primary.conf
```

`fence` 会在停止 VIP 前验证 `dr_cluster_b` 槽存在、处于活动流复制状态且延迟不超过 `MAX_PREFLIGHT_LAG_BYTES`（默认 16 MiB）。停止业务 VIP 后会等待延迟降到 `MAX_SWITCHOVER_LAG_BYTES`（默认 `0`），确认后才停止 Patroni 和 PostgreSQL。复制不健康时不会进入停库阶段。

2. 在集群 B 的运维机执行提升和复制槽创建：

```bash
./dr_switchover.sh promote \
  --conf ./dr_switchover.standby.conf
```

`promote` 会验证 DCS 中的上游 VIP 和本集群槽名、确认已回放所有收到的 WAL，并探测 A 的数据库 VIP；如果原主仍可连接，脚本会拒绝提升。提升完成后，B 自动创建 A 回接使用的 `dr_cluster_a` 槽。

3. 在集群 A 的运维机执行数据目录重置和备集群重建：

```bash
./dr_switchover.sh rejoin \
  --conf ./dr_switchover.primary.conf
```

回切前应确认新主集群和重建后的旧集群均健康、复制延迟可接受。反向执行相同流程即可：在当前可写的 B 执行 `fence`，在当前只读的 A 执行 `promote`，最后回到 B 执行 `rejoin`。

三个命令分别要求输入 `FENCE`、`PROMOTE`、`REJOIN`。任一步失败时脚本退出并保持旧写入端停止，避免恢复旧写入端导致双主；此时先检查 Patroni、VIP 和备份，再决定人工恢复或重新执行。执行前应进行业务停写和一致性确认，脚本不保证跨集群零数据丢失。

`fence` 和 `rejoin` 会同时停止 Patroni 与指定 `tp_data` 的 PostgreSQL 主进程，并通过 `pg_ctl status` 验证实例已退出。旧版 `patroni.service` 若使用 `KillMode=process`，仅执行 `systemctl stop patroni` 不能停止 PostgreSQL；新的服务模板已改为 `KillMode=control-group`。

创建和检查复制槽前，脚本会加载 `/opt/pieclouddb-tp/pdb_env.sh`，并从本集群 Patroni 配置读取数据库认证信息。非默认安装路径可通过 `PDB_ENV=/path/to/pdb_env.sh` 指定。

清理旧集群 DCS 时，脚本使用 Patroni 3.3.x 支持的交互确认方式，不依赖较新版本才可能提供的 `patronictl remove --force`。若旧 leader 租约尚未超过 TTL，脚本会等待后重试。

Patroni 在移除 `standby_cluster` 后可能由集群内任意节点成为新主，不能假设原 `Standby Leader` 必然提升。脚本会自动识别实际新主，并在同一次 `promote` 中创建配置指定的复制槽。`finalize-promote` 仅用于修复已经提升、但未完成复制槽创建的切换。

### 主集群不可达时的应急切换

主集群全部不可达时，不执行 `fence`，因为脚本无法确认旧主已经停止。必须先通过网络隔离、关闭虚拟机、断开存储或移除原主 VIP 等方式确认旧主不能继续提供写服务；否则提升备集群会产生双主。`emergency-promote` 允许备集群个别节点不可达，但必须仍有可用的 DCS quorum 和 Standby Leader。确认后，在备集群运维机执行：

```bash
./dr_switchover.sh emergency-promote \
  --conf ./dr_switchover.standby.conf
```

该命令从 B 的配置读取原主 VIP 和方向性槽名，提升 B 并创建 A 重建时使用的 `dr_cluster_a` 槽。故障主集群恢复且确认不应保留原数据服务后，在 A 执行：

```bash
./dr_switchover.sh rejoin \
  --conf ./dr_switchover.primary.conf
```

`rejoin` 会先连接 A 配置中的 `peer_cluster_vip`，确认 B 可写且 `dr_cluster_a` 槽存在；验证通过后才停止 A、将原数据目录重命名保留为 `*.before_dr_<时间戳>`，再以 B 为上游进行 `basebackup` 重建。应急提升发生在复制延迟未知的情况下，可能丢失尚未复制到 B 的事务。
