#! /bin/bash

set -e
source ./ha_pieclouddb_tp.conf

tp_rpm="pieclouddb-tp-2.9.9-96ee068498.20240801_ky10.x86_64.rpm"


IFS=',' read -r -a ip_arr <<< "$ip_list"
IFS=',' read -r -a host_arr <<< "$host_list"
len=${#ip_arr[@]}

# 生成patroni 服务配置文件
cp -f template_patroni.service patroni.service
sed -i "s@{{HA_TP_DIR}}@$ha_tp_dir@g; s@{{TP_DATA}}@$tp_data@g " patroni.service


# 生成etcd的cli信息
etcd_cli_list=""
for (( i=0;i<$len;i++ ))
do
   addr="  - ${ip_arr[$i]}:$cli_port"
   etcd_cli_list="$etcd_cli_list\n$addr"
done


for (( i=0;i<$len;i++ ))
do  
  # 安装tp
  ssh ${ip_arr[$i]} "rpm -ivh ${ha_tp_dir}/${tp_rpm}" --replacepkgs

  # 准备tp的数据目录,并修改权限
  ssh ${ip_arr[$i]} "mkdir -p ${tp_data};chown -R openpie. ${tp_data};chmod 700 ${tp_data}"
  ssh ${ip_arr[$i]} "mkdir -p ${tp_arch};chown -R openpie. ${tp_arch};chmod 700 ${tp_arch};"

  # 生成patroni配置文件并分发到各自的服务器
  cp -f template_patroni.yml patroni_${host_arr[$i]}.yml
  local_num=$(( $i+1 ))
  local_ip=${ip_arr[$i]}
  sed -i "s@{{LOACL_NUM}}@$local_num@g; s@{{LOCAL_IP}}@$local_ip@g; s@{{ETCD_CLI_LIST}}@$etcd_cli_list@g; s@{{TP_DATA}}@$tp_data@g;s@{{TP_ARCH}}@$tp_arch@g " patroni_${host_arr[$i]}.yml
  scp patroni_${host_arr[$i]}.yml ${host_arr[$i]}:${ha_tp_dir}/patroni/patroni.yml

  # 分发patroni 服务配置文件
  scp patroni.service ${host_arr[$i]}:/usr/lib/systemd/system/patroni.service
done


for (( i=0;i<$len;i++ ))
do
  # 启动patroni 服务
  ssh ${host_arr[$i]} "systemctl daemon-reload;systemctl start patroni;systemctl enable patroni"
done

# 查看patroni的情况
sleep 10
echo /opt/miniconda3/envs/py311/bin/patronictl -c ${ha_tp_dir}/patroni/patroni.yml list
/opt/miniconda3/envs/py311/bin/patronictl -c ${ha_tp_dir}/patroni/patroni.yml list
