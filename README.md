
该安装包实现了tp（pg）的高可用和主备双集群的高可用，高可用依赖tp_etcd,patroni,tp_vip服务,并依赖miniconda3打包的python环境
可以使用下面的命令查看各服务的运行情况:
systemctl status tp_etcd
systemctl status patroni
systemctl status tp_vip
下面的命令可以查看patroni集群的情况:
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml list

***使用注意事项，主备集群都是如下要求，

1，使用root用户执行该脚本，且各服务器之间root用户已经配置互信
2，已经创建openpie用户，该用户运行tp
3, 每个集群部署的环境必须是3台服务器
4, 各服务器的防火墙已关闭
5, 各服务器已配置时钟同步，各服务器的时间需一致
6, 每个服务器使用的网口需要一样，如不一样需要自行去每个服务器上修改${ha_tp_dir}/tp_vip/vip_manager.yml里的配置
7, miniconda3依赖的环境已经固定，必须安装在/opt下
8, 每次重新安装前，删除ha_piecloudb_tp的部署目录，停用tp_etcd,patroni,tp_vip服务

***主集群安装使用步骤
1, 按上面的注意事项准备主集群安装环境
2, 修改ha_piecloudb_tp.con配置文件,特别是对主集群各主机名，IP和虚拟IP使用网口及其ip的修改
3, 执行方式为./main_install.sh

***备集群安装使用步骤
1, 按上面的注意事项准备备集群安装环境，主备集群之间所有服务器的网络需互通
2, 修改ha_piecloudb_tp.con配置文件,特别是对备集群各主机名，IP和虚拟IP使用网口及其ip的修改，还有连接主集群的信息
3, 执行方式为./init_standby_cluster.sh

***备集群使用注意事项
1，备集群正常为只读模式
2，备集群是通过standby leader从主集群的leader复制数据，而leader和standby leader在各自的集群内是可能移动的
3，备集群停止从主集群同步后是可以正常读写的，但会使用新的时间线，不能在继续从主集群同步
4，备集群上执行如下操作来停止从主集群同步的方法如下：
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml pause
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml edit-config
删除如下内容，并确认保存：
    standby_cluster:
      host: 主集群VIP或IP
      port: 5432
      primary_slot_name: standby01
      create_replica_methods:
      - basebackup
/opt/miniconda3/envs/py311/bin/patronictl -c /opt/ha_pieclouddb_tp/patroni/patroni.yml resume
