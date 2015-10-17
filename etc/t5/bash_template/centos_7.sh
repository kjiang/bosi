#!/bin/bash

install_bsnstacklib=%(install_bsnstacklib)s
install_ivs=%(install_ivs)s
install_all=%(install_all)s
deploy_dhcp_agent=%(deploy_dhcp_agent)s
deploy_l3_agent=%(deploy_l3_agent)s
ivs_version=%(ivs_version)s
is_controller=%(is_controller)s
deploy_horizon_patch=%(deploy_horizon_patch)s
fuel_cluster_id=%(fuel_cluster_id)s
openstack_release=%(openstack_release)s
default_gw=%(default_gw)s


controller() {
    echo "Stop and disable metadata agent, dhcp agent, l3 agent"
    systemctl stop neutron-l3-agent
    systemctl disable neutron-l3-agent
    systemctl stop neutron-dhcp-agent
    systemctl disable neutron-dhcp-agent
    systemctl stop neutron-metadata-agent
    systemctl disable neutron-metadata-agent
    systemctl stop neutron-bsn-agent
    systemctl disable neutron-bsn-agent

    # copy dhcp_reschedule.sh to /bin
    cp %(dst_dir)s/dhcp_reschedule.sh /bin/
    chmod 777 /bin/dhcp_reschedule.sh

    # deploy bcf
    puppet apply --modulepath /etc/puppet/modules %(dst_dir)s/%(hostname)s.pp

    # deploy bcf horizon patch to controller node
    #if [[ $deploy_horizon_patch == true ]]; then
        # TODO: new way to plugin horizon
    #fi

    # restart keystone and httpd
    #systemctl restart httpd

    # schedule cron job to reschedule network in case dhcp agent fails
    chmod a+x /bin/dhcp_reschedule.sh
    crontab -r
    (crontab -l; echo "*/30 * * * * /bin/dhcp_reschedule.sh") | crontab -

    echo "Restart nova"
    systemctl restart openstack-nova-consoleauth
    systemctl restart openstack-nova-scheduler
    systemctl restart openstack-nova-conductor
    systemctl restart openstack-nova-cert

    echo "Restart neutron-server"
    rm -rf /var/lib/neutron/host_certs/*
    systemctl restart neutron-server
}

compute() {

    if [[ $deploy_dhcp_agent == true ]]; then
        echo 'Stop and disable neutron-metadata-agent and neutron-dhcp-agent'
        systemctl stop neutron-dhcp-agent
        systemctl disable neutron-dhcp-agent
        systemctl stop neutron-metadata-agent
        systemctl disable neutron-metadata-agent

        # patch linux/dhcp.py to make sure static host route is pushed to instances
        dhcp_py=$(find /usr -name dhcp.py | grep linux)
        dhcp_dir=$(dirname "${dhcp_py}")
        sed -i 's/if (isolated_subnets\[subnet.id\] and/if (True and/g' $dhcp_py
        find $dhcp_dir -name "*.pyc" | xargs rm
        find $dhcp_dir -name "*.pyo" | xargs rm
    fi

    if [[ $deploy_l3_agent == true ]]; then
        echo 'Stop and disable neutron-l3-agent'
        systemctl stop neutron-l3-agent
        systemctl disable neutron-l3-agent
    fi

    # copy send_lldp to /bin
    cp %(dst_dir)s/send_lldp /bin/
    chmod 777 /bin/send_lldp

    # update configure files and services
    puppet apply --modulepath /etc/puppet/modules %(dst_dir)s/%(hostname)s.pp
    systemctl daemon-reload

    # remove bond from ovs
    ovs-appctl bond/list | grep -v slaves | grep %(bond)s
    if [[ $? == 0 ]]; then
        ovs-vsctl --if-exists del-port %(bond)s
        declare -a uplinks=(%(uplinks)s)
        len=${#uplinks[@]}
        for (( i=0; i<$len; i++ )); do
            ovs-vsctl --if-exists del-port ${uplinks[$i]}
        done
    fi

    # flip uplinks and bond
    declare -a uplinks=(%(uplinks)s)
    len=${#uplinks[@]}
    ifdown %(bond)s
    for (( i=0; i<$len; i++ )); do
        ifdown ${uplinks[$i]}
    done
    for (( i=0; i<$len; i++ )); do
        ifup ${uplinks[$i]}
    done
    ifup %(bond)s

    # add physical interface bridge
    # this may be absent in case of packstack
    ovs-vsctl --may-exist add-br %(br_bond)s
    # add bond to ovs
    ovs-vsctl --may-exist add-port %(br_bond)s %(bond)s
    sleep 10
    systemctl restart send_lldp

    # restart neutron ovs plugin
    # this ensures connections between br-int and br-bond are created fine
    systemctl restart neutron-openvswitch-agent

    # assign default gw
    bash /etc/rc.d/rc.local

    if [[ $deploy_dhcp_agent == true ]]; then
        echo 'Restart neutron-metadata-agent and neutron-dhcp-agent'
        systemctl enable neutron-metadata-agent
        systemctl restart neutron-metadata-agent
        systemctl enable neutron-dhcp-agent
        systemctl restart neutron-dhcp-agent
    fi

    if [[ $deploy_l3_agent == true ]]; then
        echo "Restart neutron-l3-agent"
        systemctl enable neutron-l3-agent
        systemctl restart neutron-l3-agent
    fi

    # restart libvirtd and nova compute on compute node
    echo 'Restart libvirtd and openstack-nova-compute'
    systemctl enable libvirtd
    systemctl restart libvirtd
    systemctl enable openstack-nova-compute
    systemctl restart openstack-nova-compute
}


set +e

# Make sure only root can run this script
if [ "$(id -u)" != "0" ]; then
   echo -e "Please run as root"
   exit 1
fi

# prepare dependencies
rpm -iUvh http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
rpm -ivh https://yum.puppetlabs.com/el/7/products/x86_64/puppetlabs-release-7-10.noarch.rpm
yum groupinstall -y 'Development Tools'
yum install -y python-devel puppet python-pip wget libffi-devel openssl-devel
yum update -y
easy_install pip
puppet module install --force puppetlabs-inifile
puppet module install --force puppetlabs-stdlib
puppet module install jfryman-selinux
mkdir -p /etc/puppet/modules/selinux/files
cp %(dst_dir)s/%(hostname)s.te /etc/puppet/modules/selinux/files/centos.te

# install bsnstacklib
if [[ $install_bsnstacklib == true ]]; then
    sleep 2
    pip uninstall -y bsnstacklib
    sleep 2
    pip install --upgrade "bsnstacklib<%(bsnstacklib_version)s"
fi

if [[ $is_controller == true ]]; then
    controller
else
    compute
fi

set -e

exit 0
