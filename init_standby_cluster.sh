#! /bin/bash

set -e

source ha_pieclouddb_tp.conf
# 检查环境：openpie用户是否存在，conf里主机是否3台，环境之间是否已做ssh互信

username="openpie"



# 检查用户是否存在
if id "$username" >/dev/null 2>&1; then
    echo "用户 $username 存在"
else
    echo "用户 $username 不存在"
    echo "openpie用户需存在，conf里主机需为3台，环境之间已做ssh互信" 
    exit 
fi

IFS=',' read -r -a ip_arr <<< "$ip_list"
IFS=',' read -r -a host_arr <<< "$host_list"
len=${#ip_arr[@]}

# 检查提供的主机是否为3台
if [ $len -ne 3 ];then
  echo "提供的主机不是3台"
  echo "openpie用户需存在，conf里主机需为3台，环境之间已做ssh互信"
  exit
fi


# 检查环境之间是否已做ssh互信
for (( i=0;i<$len;i++ ))
do
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${host_arr[$i]}" "echo 2>&1" >/dev/null
  if [ $? -ne 0 ]; then
    echo "与主机 ${host_arr[$i]} 的SSH互信未设置"
    echo "openpie用户需存在，conf里主机需为3台，环境之间已做ssh互信" 
    exit
  fi
done



#安装依赖，准备安装目录,和分发基本文件
for (( i=0;i<$len;i++ ))
do
#  ssh ${host_arr[$i]} "yum install -y gcc zlib readline zlib-devel readline-devel bison bzip2 openssl-devel zip unzip"
  ssh ${host_arr[$i]} "mkdir -p $ha_tp_dir"
  rsync -r ha_pieclouddb_tp/* ${host_arr[$i]}:$ha_tp_dir
done



# 执行etcd安装
echo "开始etcd安装"
./install_etcd.sh

# 执行minioconda3安装,解压文件到/opt目录，因环境依赖该目录是固定的
echo "解压minioconda3，需耐心等待"
./install_conda.sh

#执行standby patroni安装
echo "开始standby patroni安装"
./install_standby_patroni.sh

#执行vip-manager安装
echo "开始vip-manager安装"
./install_vip_manager.sh
