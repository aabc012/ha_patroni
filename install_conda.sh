#! /bin/bash

set -e

source ./ha_pieclouddb_tp.conf

IFS=',' read -r -a ip_arr <<< "$ip_list"
len=${#ip_arr[@]}

# 解压文件
for (( i=0;i<$len;i++ ))
do
  ssh ${ip_arr[$i]} "unzip -q  ${ha_tp_dir}/miniconda3.zip -d /opt/"
done
