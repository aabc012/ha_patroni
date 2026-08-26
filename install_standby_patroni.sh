#! /bin/bash

set -e
source ./ha_pieclouddb_tp.conf

: "${primary_cluster_vip:?missing primary_cluster_vip (primary cluster VIP)}"
: "${primary_cluster_pg_port:?missing primary_cluster_pg_port}"
: "${primary_cluster_pg_password:?missing primary_cluster_pg_password}"
: "${primary_slot_name:?missing primary_slot_name}"
[[ "$primary_cluster_pg_port" =~ ^[0-9]+$ ]] || {
  echo "primary_cluster_pg_port must be a positive integer" >&2
  exit 1
}
[[ "$primary_slot_name" =~ ^[a-zA-Z0-9_]+$ ]] || {
  echo "primary_slot_name contains unsafe characters: $primary_slot_name" >&2
  exit 1
}

PSQL=${PSQL:-/opt/pieclouddb-tp/bin/psql}
PDB_ENV=${PDB_ENV:-/opt/pieclouddb-tp/pdb_env.sh}
[[ -r "$PDB_ENV" ]] || { echo "PDB_ENV is not readable: $PDB_ENV" >&2; exit 1; }

# The standby cluster depends on this slot on the current primary. Create it
# before starting Patroni and make the operation safe to repeat.
set +u
source "$PDB_ENV"
set -u
export PGPASSWORD="$primary_cluster_pg_password"
"$PSQL" \
  -h "$primary_cluster_vip" \
  -p "$primary_cluster_pg_port" \
  -U openpie \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT pg_create_physical_replication_slot('${primary_slot_name}')
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_replication_slots
        WHERE slot_name = '${primary_slot_name}'
      );" >/dev/null

slot_exists=$("$PSQL" \
  -h "$primary_cluster_vip" \
  -p "$primary_cluster_pg_port" \
  -U openpie \
  -d postgres \
  -At \
  -v ON_ERROR_STOP=1 \
  -c "SELECT 1 FROM pg_replication_slots
      WHERE slot_name = '${primary_slot_name}';")
[[ "$slot_exists" == 1 ]] || {
  echo "replication slot $primary_slot_name was not found on $primary_cluster_vip:$primary_cluster_pg_port" >&2
  exit 1
}
echo "Verified replication slot $primary_slot_name on $primary_cluster_vip:$primary_cluster_pg_port"

#tp_rpm="pieclouddb-tp-2.9.9-96ee068498.20240801_ky10.x86_64.rpm"
tp_rpm="pieclouddb-tp-2.16.0-4552651248.20250930_el8.x86_64.rpm"


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
  cp -f template_standby_patroni.yml patroni_${host_arr[$i]}.yml
  local_num=$(( $i+1 ))
  local_ip=${ip_arr[$i]}
  sed -i "s@{{LOACL_NUM}}@$local_num@g; s@{{LOCAL_IP}}@$local_ip@g; s@{{ETCD_CLI_LIST}}@$etcd_cli_list@g; s@{{TP_DATA}}@$tp_data@g;s@{{TP_ARCH}}@$tp_arch@g " patroni_${host_arr[$i]}.yml
  sed -i "s@{{PRIMARY_CLUSTER_VIP}}@$primary_cluster_vip@g; s@{{PRIMARY_CLUSTER_PG_PORT}}@$primary_cluster_pg_port@g; s@{{PRIMARY_SLOT_NAME}}@$primary_slot_name@g;" patroni_${host_arr[$i]}.yml
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
