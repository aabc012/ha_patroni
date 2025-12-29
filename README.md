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
