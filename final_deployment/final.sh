#!/bin/bash

TENANT_NAME=${1:-app}
USER_NAME=${2:-app}

function authenticate {
  local user=${1:-$USER_NAME}
  local tenant=${2:-$TENANT_NAME}
  echo "Authenticating as $user in tenant $tenant"
  source ~/devstack/openrc $user $tenant
}

function get_tenant_id {
  local name=${1:-$TENANT_NAME}
  openstack project show $name -f value -c id
}

function get_network_id {
  local network_name=$1
  neutron net-list -c id -c name -f value | grep $network_name | cut -f 1 -d ' '
}

function get_subnet_id {
  local subnet_name=$1
  neutron subnet-list -c id -c name -f value | grep $subnet_name | cut -f 1 -d ' '
}

function cleanup {
  authenticate $USER_NAME $TENANT_NAME

  echo Cleaning up stacks
  heat stack-delete autoscale

  # let the stack instances get cleaned up
  # otherwise networking cleanup could fail
  sleep 10 

  echo Cleaning up networking
  neutron router-gateway-clear router
  neutron router-interface-delete router web-subnet
  neutron port-list --format value -c id | xargs -n 1 neutron port-delete
  neutron router-list --format value -c id | xargs -n 1 neutron router-delete
  neutron subnet-list --format value -c id | xargs -n 1 neutron subnet-delete
  neutron net-list --format value -c id | xargs -n 1 neutron net-delete

  authenticate admin admin 

  echo Cleaning up user and tenant
  openstack user delete $USER_NAME
  openstack project delete $TENANT_NAME
  
}

function setup {
  authenticate admin admin

  echo Creating user $USER_NAME and tenant $TENANT_NAME
  openstack project create $TENANT_NAME
  openstack user create $USER_NAME --project $TENANT_NAME --password $ADMIN_PASSWORD
  openstack role add --user $USER_NAME --project $TENANT_NAME Member
  openstack role add --user admin --project $TENANT_NAME Member
  
  authenticate $USER_NAME $TENANT_NAME

  echo Creating private network
  neutron net-create web-net
  neutron subnet-create --name web-subnet web-net 10.0.0.0/24
  neutron router-create router
  neutron router-gateway-set router public
  neutron router-interface-add router web-subnet
  
}

function create_stack {
  authenticate $USER_NAME $PASSWORD

  local subnet_id=$(get_subnet_id web-subnet)
  local public_net_id=$(get_network_id public)
  echo heat stack-create -f final.yaml -P"network=web-net;subnet_id=$subnet_id;external_network_id=$public_net_id" autoscale
  heat stack-create -f final.yaml -P"network=web-net;subnet_id=$subnet_id;external_network_id=$public_net_id" autoscale

  local stack_status=CREATE_IN_PROGRESS
  while [ $stack_status == "CREATE_IN_PROGRESS" ]
  do
    stack_status=$(heat stack-list | grep autoscale | cut -d \| -f 4)
    echo $(date): $stack_status
  done
}

cleanup
setup
create_stack

FIP=$(neutron floatingip-list -c floating_ip_address -f value)

while [ 1 ]
do
  echo $(date): $(curl -sS http://$FIP/)
  sleep 15
done