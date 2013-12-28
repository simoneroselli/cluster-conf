#!/bin/bash


if [[ $# -lt 1 ]]; then
  echo "Usage $0 <ct_name>"
  exit 1
fi

CLUSTER_NODES=(proxmox proxmox2)

#NEW_CT_HOSTNAME=$1 
NEW_CT_HOSTNAME=$1
TEMPL_CT_ID="100"

# RETRIEVE THIS VALUE PLEASE
NODE='proxmox'

shift

#
# Define the next ID available
NEXT_CT_ID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')

# Storage (default local)
STORAGE_ID="sharedx"

# Cluster configuration file
CLUSTER_CFG=/etc/pve/cluster.conf

DUMP_DIR=/mnt/pve/sharedx/dump
DUMP_TEMPL_CT=${DUMP_DIR}/vzdump-openvz-${TEMPL_CT_ID}-*
DUMP_TEMPL_CT_TAR=${DUMP_DIR}/vzdump-openvz-${TEMPL_CT_ID}-*.tar
VZDUMP=/usr/bin/vzdump
VZRESTORE=/usr/bin/vzrestore
VZRESTORE_OPTS="-storage $STORAGE_ID"
PVESH=/usr/bin/pvesh
PVESH_OPTS="-vmid $NEXT_CT_ID -autostart 1"
PVECTL_SET="/usr/bin/pvectl set"

# TEMPORARY: Fix these mac addresses
case "$NEXT_CT_ID" in
  '101')
    MAC_ADDR="72:49:CC:6B:F9:CD"
    ;;
  '102')
    MAC_ADDR="72:49:CC:6B:F9:CE"
    ;;
  '103')
    MAC_ADDR="72:49:CC:6B:F9:CF"
    ;;
  *)
    echo "Unkown ID \"$NEXT_CT_ID\""
    exit 1
esac

# Vz container configuration
PVECTL_OPTS=" 
-cpus 1
-hostname $NEW_CT_HOSTNAME
-ip_address 192.168.1.${NEXT_CT_ID}
-nameserver 192.168.1.1
-memory 128
-swap 128
-netif ifname=eth0,mac=${MAC_ADDR},host_ifname=veth${NEXT_CT_ID},host_mac=A6:3E:D9:CB:B9:A3,bridge=vmbr0
"

# Current node or remote one
if [[ $NODE != $(hostname) ]]; then
  NODE="/usr/bin/ssh $NODE"
else
  NODE=""
fi

# Cleanup dump environment
cleanup_dump() {
  if [ "$1" ]; then
    /bin/rm -f $1
  fi
}

# Cleanup root ids if already present. *$1 needs to be an array*
cleanup_roots() {
  for i in ${CLUSTER_NODES[@]}; do
    /usr/bin/ssh $i rm -r /var/lib/vz/root/${1} 2>/dev/null 1>&2
  done
}

ct_2_domain() {
  if /bin/grep -q "vmid=\"$1\"" $2 && ! /bin/grep -q "domain=\"vicinet-$1\"/" $2; then
    /bin/sed -i "s/vmid=\"$1\"/vmid=\"$1\" domain=\"vicinet-$1\"/" $2 2>/dev/null
  else
    return 'false'
  fi
}

## LOCK FILE HERE PLEASE ##

# Cleanup old dumps
cleanup_dump $DUMP_TEMPL_CT

# Ensure the new ID is not present already on any node
cleanup_roots $NEXT_CT_ID

# Dump CT
$VZDUMP $TEMPL_CT_ID

# C# Perform the CT restore on the selected node
$NODE $VZRESTORE $DUMP_TEMPL_CT_TAR $NEXT_CT_ID $VZRESTORE_OPTS

# Set the new CT identity
$NODE $PVECTL_SET $NEXT_CT_ID $PVECTL_OPTS

# Add the new CT to the HA
if ! grep -q "vmid=\"$NEXT_CT_ID\"" $CLUSTER_CFG; then
  $PVESH create /cluster/ha/groups $PVESH_OPTS
fi
  
if [ -f ${CLUSTER_CFG}.new ]; then
  # Force the new CT to the specific domain
  ct_2_domain $NEXT_CT_ID ${CLUSTER_CFG}.new
  
  # Apply the changes on all nodes
  $PVESH create /cluster/ha/changes
fi
