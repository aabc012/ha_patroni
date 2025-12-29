#! /bin/bash

set -e

source ha_pieclouddb_tp.conf

IFS=',' read -r -a ip_arr <<< "$ip_list"
IFS=',' read -r -a host_arr <<< "$host_list"
len=${#ip_arr[@]}

# 生成etcd信息
all_host_peer_info=""
etcd_endpoint_info=""
for (( i=0;i<$len;i++ ))
do
   addr="tp_etcd_${host_arr[$i]}=http://${ip_arr[$i]}:$peer_port,"
   all_host_peer_info="$all_host_peer_info$addr"
   etcd_endpoint_info="$etcd_endpoint_info${ip_arr[$i]}:$cli_port,"
done

#echo $all_host_peer_info

# 生成etcd服务文件
cp -f template_tp_etcd.service tp_etcd.service
sed -i "s@{{HA_TP_DIR}}@$ha_tp_dir@g " tp_etcd.service

for (( i=0;i<$len;i++ ))
do
  # 生成etcd环境文件，并分发
  cp -f template_tp_etcd.env tp_etcd_${host_arr[$i]}.env
  local_ip=${ip_arr[$i]}
  local_hostname=${host_arr[$i]}
  sed -i "s@{{HA_TP_DIR}}@$ha_tp_dir@g; s@{{DATA_DIR}}@$data_dir@g; s@{{CLI_PORT}}@$cli_port@g; s@{{PEER_PORT}}@$peer_port@g; s@{{LOCAL_HOSTNAME}}@$local_hostname@g; s@{{LOCAL_IP}}@$local_ip@g; s@{{ALL_HOST_PEER_INFO}}@$all_host_peer_info@g " tp_etcd_${host_arr[$i]}.env
  scp tp_etcd_${host_arr[$i]}.env ${host_arr[$i]}:${ha_tp_dir}/tp_etcd/tp_etcd.env
 
  # 分发etcd服务文件
  scp tp_etcd.service ${host_arr[$i]}:/usr/lib/systemd/system/tp_etcd.service
done

# 启动etcd服务
for (( i=0;i<$len;i++ ))
do
  ssh ${host_arr[$i]} "systemctl daemon-reload;systemctl restart tp_etcd;systemctl enable tp_etcd" &
done

#查看tp_etcd的情况
sleep 5
echo  ${ha_tp_dir}/tp_etcd/bin/etcdctl member list  --endpoints="$etcd_endpoint_info"
${ha_tp_dir}/tp_etcd/bin/etcdctl member list  --endpoints="$etcd_endpoint_info"
