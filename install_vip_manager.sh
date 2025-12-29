#! /bin/bash

set -e

source ha_pieclouddb_tp.conf

IFS=',' read -r -a ip_arr <<< "$ip_list"
IFS=',' read -r -a host_arr <<< "$host_list"
len=${#ip_arr[@]}

# 生成tp_vip 服务配置文件
cp -f template_tp_vip.service tp_vip.service
sed -i "s@{{HA_TP_DIR}}@$ha_tp_dir@g" tp_vip.service

for (( i=0;i<$len;i++ ))
do
  # 生成vip_manager配置文件并分发到各自的服务器
  cp -f template_vip_manager.yml vip_manager_${host_arr[$i]}.yml
  local_num=$(( $i+1 ))
  local_ip=${ip_arr[$i]}
  sed -i "s@{{LOACL_NUM}}@$local_num@g; s@{{LOCAL_IP}}@$local_ip@g; s@{{VIP}}@$vip@g; s@{{INTERFACE}}@$interface@g; s@{{CLI_PORT}}@$cli_port@g; s@{{NETMASK}}@$netmask@g" vip_manager_${host_arr[$i]}.yml
  scp vip_manager_${host_arr[$i]}.yml ${host_arr[$i]}:${ha_tp_dir}/tp_vip/vip_manager.yml

  # 分发tp_vip 服务配置文件
  scp tp_vip.service ${host_arr[$i]}:/usr/lib/systemd/system/tp_vip.service
done


# 启动tp_vip 服务
for (( i=0;i<$len;i++ ))
do
  ssh ${host_arr[$i]} "systemctl daemon-reload;systemctl restart tp_vip;systemctl enable tp_vip"
done

# 查看tp_vip的情况
