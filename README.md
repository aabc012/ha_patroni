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

仓库提供 `dr_switchover.sh` 用于两个 Patroni 集群之间的计划切换。脚本分三个阶段在两套集群中分别执行；每个阶段的执行机只需要能以 root SSH 免密访问**本集群**的三个节点，不需要跨集群 SSH。请分别为两个集群准备配置文件，可从 `dr_switchover.conf.example` 复制；已有的 `ha_pieclouddb_tp.conf` 也可以直接使用，但需要确认其中的 `ip_list`、`host_list`、`tp_data`、`vip`、`primary_slot_name` 与该集群一致。

切换会执行以下不可逆运维动作：暂停并停止当前可写集群以防止双主，停止 VIP；对当前 leader 的数据目录生成 `tar.gz` 备份和 SHA-256 校验文件；提升备集群；最后清理旧集群的 Patroni DCS 状态，备份其 Patroni 配置，将旧集群所有数据目录重命名为 `*.before_dr_<时间戳>`，并通过 `basebackup` 重建为新主集群的备集群。默认压缩备份目录为 `/data/patroni-dr-backup`，可通过 `BACKUP_ROOT` 修改，且该路径必须在旧 leader 所在主机有足够空间。

计划切换（集群 A 当前可写，集群 B 当前只读）需要人工复制一个权限为 `600` 的交接文件。交接文件只包含复制槽、备份路径以及原主/新主 VIP 与端口，不包含数据库密码；重建阶段会校验原主 VIP，防止误在新主集群执行数据重置。

1. 在集群 A 的运维机执行停写、停止服务并备份 leader 数据目录：

```bash
chmod 750 dr_switchover.sh
BACKUP_ROOT=/data/patroni-dr-backup ./dr_switchover.sh fence \
  --conf ./cluster-a.conf --handoff /tmp/dr-handoff.env
```

2. 将 `/tmp/dr-handoff.env` 复制到集群 B 的运维机，再在集群 B 执行提升和复制槽创建：

```bash
./dr_switchover.sh promote \
  --conf ./cluster-b.conf --handoff /tmp/dr-handoff.env
```

3. 再将更新后的交接文件复制回集群 A 的运维机，执行数据目录重置和备集群重建：

```bash
./dr_switchover.sh rejoin \
  --conf ./cluster-a.conf --handoff /tmp/dr-handoff.env
```

回切前应确认新主集群和重建后的旧集群均健康、复制延迟可接受。按同样三个阶段反向执行即可：先在当前可写的 B 执行 `fence`，在当前只读的 A 执行 `promote`，最后回到 B 执行 `rejoin`。

三个阶段分别要求输入 `FENCE`、`PROMOTE`、`REJOIN`。任一步失败时脚本退出并保持旧写入端停止，避免恢复旧写入端导致双主；此时先检查 Patroni、VIP 和备份，再决定人工恢复或重新执行。执行前应进行业务停写和一致性确认，脚本不保证跨集群零数据丢失。

### 主集群不可达时的应急切换

主集群全部不可达时，不执行 `fence`，因为脚本无法确认旧主已经停止。必须先通过网络隔离、关闭虚拟机、断开存储或移除原主 VIP 等方式确认旧主不能继续提供写服务；否则提升备集群会产生双主。确认后，在备集群运维机执行：

```bash
./dr_switchover.sh emergency-promote \
  --conf ./cluster-b.conf \
  --former-primary-conf ./cluster-a.conf \
  --handoff /tmp/dr-handoff.env
```

`cluster-a.conf` 只作为元数据输入，可通过受控文件传输带到备集群；其 `vip`、`primary_slot_name` 和 `patroni_scope` 必须是故障主集群的实际值。该命令提升 B 并创建 A 重建时使用的复制槽。故障主集群恢复且确认不应保留原数据服务后，将交接文件带回 A，执行：

```bash
./dr_switchover.sh rejoin \
  --conf ./cluster-a.conf --handoff /tmp/dr-handoff.env
```

这会停止 A、将原数据目录重命名保留为 `*.before_dr_<时间戳>`，再以 B 为上游进行 `basebackup` 重建。应急提升发生在复制延迟未知的情况下，可能丢失尚未复制到 B 的事务。
