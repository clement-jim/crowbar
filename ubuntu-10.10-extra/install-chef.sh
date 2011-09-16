#!/bin/bash
# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# 

export FQDN="$1"
export PATH="/opt/dell/bin:$PATH"
die() { echo "$(date '+%F %T %z'): $@"; exit 1; }

# mac address and IP address matching routines
mac_match_re='link/ether ([0-9a-fA-F:]+)'
ip_match_re='inet ([0-9.]+)'
get_ip_and_mac() {
    local ip_line=$(ip addr show $1)
    [[ $ip_line =~ $mac_match_re ]] && MAC=${BASH_REMATCH[1]} || unset MAC
    [[ $ip_line =~ $ip_match_re ]] && IP=${BASH_REMATCH[1]} || unset IP
}

crowbar_up=

# Run a command and log its output.
log_to() {
    # $1 = install log to log to
    # $@ = rest of args
    local __logname="$1" _ret=0
    local __log="/var/log/install-$1"
    local __timestamp="$(date '+%F %T %z')"
    local log_skip_re='^gem|knife$'
    shift
    printf "\n%s\n" "$__timestamp: Running $*" | \
	tee -a "$__log.err" >> "$__log.log"
    "$@" 2>> "$__log.err" >>"$__log.log" || {
	_ret=$?
	if ! [[ $__logname =~ $log_skip_re ]]; then
	    echo "$__timestamp: $* failed."
	    echo "See $__log.log and $__log.err for more information."
	fi
    }
    printf "\n$s\n--------\n"  "$(date '+%F %T %z'): Done $*" | \
	tee -a "$__log.err" >> "$__log.log"
    return $_ret
}

chef_or_die() {
    if [ -e /opt/dell/bin/blocking_chef_client.sh ]; then
        log_to chef blocking_chef_client.sh && return
    else
        log_to chef chef-client && return
    fi
    if [[ $crowbar_up && $FQDN ]]; then
	crowbar crowbar transition "$FQDN" problem
    fi
    # If we were left without an IP address, rectify that.
    ip link set eth0 up
    ip addr add 192.168.124.10/24 dev eth0
    die "$@"
}

# Run knife in a loop until it doesn't segfault.
knifeloop() {
    local RC=0
    while { log_to knife knife "$@" -u chef-webui -k /etc/chef/webui.pem
	RC=$?
	(($RC == 139)); }; do
	:
    done
}

# Keep trying to start a service in a loop.
# $1 = service to restart
# $2 = status messae to print.
restart_svc_loop() {
    while service "$1" status | grep -qi fail
    do
        echo "$(date '+%F %T %z'): $2..."
	log_to svc service "$1" start
	sleep 1
    done
}

# Make sure there is something of a domain name
DOMAINNAME=${FQDN#*.}
[[ $DOMAINNAME = $FQDN || $DOMAINNAME = ${DOMAINNAME#*.} ]] && \
    die "Please specify an FQDN for the admin name"

# setup hostname from config file
echo "$(date '+%F %T %z'): Setting Hostname..."
update_hostname.sh $FQDN

# put the apt files in place
cp sources-cdrom.list /etc/apt/sources.list
cp apt.conf /etc/apt

# Set up our eth0 IP address way in advance.
# Deploying Crowbar should also do this for us, but sometimes it does not.
# When it does not, things get hard to debug pretty quick.
ip link set eth0 up
ip addr add 192.168.124.10/24 dev eth0

# Load up domain name
DOMAINNAME=$(dnsdomainname)

# once our hostname is correct, bounce rsyslog to let it know.
log_to svc service rsyslog restart

# This is ugly, but there does not seem to be a better way
# to tell Chef to just look in a specific location for its gems.
echo "$(date '+%F %T %z'): Arranging for gems to be installed"
log_to apt apt-get update
log_to apt apt-get -y install rubygems gcc 
(   cd /tftpboot/ubuntu_dvd/extra/gems
    gem install --local --no-ri --no-rdoc builder*.gem)
gem generate_index
# Of course we are rubygems.org. Anything less would be uncivilised.
sed -i -e 's/\(127\.0\.0\.1.*\)/\1 rubygems.org/' /etc/hosts

#
# Install the base deb packages
#
echo "$(date '+%F %T %z'): Installing Chef Server..."
log_to apt sed -i "s/__HOSTNAME__/$FQDN/g" ./debsel.conf
log_to apt /usr/bin/debconf-set-selections ./debsel.conf
log_to apt apt-get -y install chef chef-server chef-server-webui \
    kwalify libcurl4-gnutls-dev build-essential ruby-dev

(   cd /tftpboot/ubuntu_dvd/extra/gems
    gem install --local --no-ri --no-rdoc json*.gem)

# HACK AROUND CHEF-2005
cp data_item.rb /usr/share/chef-server-api/app/controllers
log_to svc /etc/init.d/chef-server restart
# HACK AROUND CHEF-2005

restart_svc_loop chef-solr "Restarting chef-solr - spot one"

chef_or_die "Initial chef run failed"

echo "$(date '+%F %T %z'): Building Keys..."
# Generate root's SSH pubkey
if [ ! -e /root/.ssh/id_rsa ] ; then
  log_to keys ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
fi

# add our own key to authorized_keys
cat /root/.ssh/id_rsa.pub >>/root/.ssh/authorized_keys

# Hack up sshd_config to kill delays
sed -i -e 's/^\(GSSAPI\)/#\1/' \
    -e 's/#\(UseDNS.*\)yes/\1no/' /etc/ssh/sshd_config
service ssh restart

# Replace the domainname in the default template
sed -i "s/pod.your.cloud.org/$DOMAINNAME/g" /opt/dell/barclamps/dns/chef/data_bags/crowbar/bc-template-dns.json

# and trick Chef into pushing it out to everyone.
cp /root/.ssh/authorized_keys \
    /opt/dell/barclamps/provisioner/chef/cookbooks/provisioner/files/default/authorized_keys

# generate the machine install username and password
mkdir -p /opt/dell/crowbar_framework
CROWBAR_FILE="/opt/dell/barclamps/crowbar/chef/data_bags/crowbar/bc-template-crowbar.json"
if [[ -e /tftpboot/ubuntu_dvd/extra/config/crowbar.json ]]; then
  CROWBAR_FILE="/tftpboot/ubuntu_dvd/extra/config/crowbar.json"
fi
CROWBAR_REALM=$(parse_node_data $CROWBAR_FILE -a attributes.crowbar.realm)
CROWBAR_REALM=${CROWBAR_REALM##*=}
if [[ ! -e /etc/crowbar.install.key && $CROWBAR_REALM ]]; then
    dd if=/dev/urandom bs=65536 count=1 2>/dev/null |sha512sum - 2>/dev/null | \
	(read key rest; echo "machine-install:$key" >/etc/crowbar.install.key)
    export CROWBAR_KEY=$(cat /etc/crowbar.install.key)
    printf "${CROWBAR_KEY%%:*}:$CROWBAR_REALM:${CROWBAR_KEY##*:}" |md5sum - | (
	read key rest
	printf "\n${CROWBAR_KEY%%:*}:$CROWBAR_REALM:$key\n" >> \
	    /opt/dell/crowbar_framework/htdigest)
fi
if [[ $CROWBAR_REALM ]]; then
    export CROWBAR_KEY=$(cat /etc/crowbar.install.key)
    sed -i -e "s/machine_password/${CROWBAR_KEY##*:}/g" \
        -e "/\"realm\":/ s/null/\"$CROWBAR_REALM\"/g" \
        $CROWBAR_FILE
fi

# Crowbar will hack up the pxeboot files appropriatly.
# Set Version in Crowbar UI
VERSION=$(cat /opt/.dell-install/Version)
sed -i "s/CROWBAR_VERSION = .*/CROWBAR_VERSION = \"${VERSION:=Dev}\"/" \
    /opt/dell/barclamps/crowbar/crowbar_framework/config/environments/production.rb

# Make sure we use the right OS installer. By default we want to install
# the same OS as the admin node.
for t in provisioner deployer; do
    sed -i '/os_install/ s/os_install/ubuntu_install/' \
	/opt/dell/barclamps/${t}/chef/data_bags/crowbar/bc-template-${t}.json
done

# Installing Barclamps (uses same library as rake commands, but before rake is ready)

# Always run crowbar barclamp first
log_to bcinstall /opt/dell/bin/barclamp_install.rb "/opt/dell/barclamps/crowbar"

# Barclamp preparation (put them in the right places)
cd /opt/dell/barclamps
for i in *; do
    [[ -d $i ]] || continue
    [[ $i != 'crowbar' ]] || continue
    if [ -e $i/crowbar.yml ]; then
      log_to bcinstall /opt/dell/bin/barclamp_install.rb "/opt/dell/barclamps/$i"
    else
      echo "WARNING: item $i found in barclamp directory, but it is not a barclamp!"
    fi 
done

restart_svc_loop chef-solr "Restarting chef-solr - spot two"

echo "$(date '+%F %T %z'): Validating data bags..."
log_to validation validate_bags.rb /opt/dell/chef/data_bags || \
    die "Crowbar configuration has errors.  Please fix and rerun install."

echo "$(date '+%F %T %z'): Update run list..."
knifeloop node run_list add "$FQDN" role[crowbar]
knifeloop node run_list add "$FQDN" role[deployer-client]

log_to svc service chef-client stop
restart_svc_loop chef-solr "Restarting chef-solr - spot three"

echo "$(date '+%F %T %z'): Bringing up Crowbar..."
# Run chef-client to bring-up crowbar server
chef_or_die "Failed to bring up Crowbar"
# Make sure looper_chef_client is a NOOP until we are finished deploying
touch /tmp/deploying

# have chef_or_die change our status to problem if we fail
crowbar_up=true

# Add configured crowbar proposal
if [ "$(crowbar crowbar proposal list)" != "default" ] ; then
    proposal_opts=()
    if [[ -e /tftpboot/ubuntu_dvd/extra/config/crowbar.json ]]; then
        proposal_opts+=(--file /tftpboot/ubuntu_dvd/extra/config/crowbar.json)
    fi
    proposal_opts+=(proposal create default)

    # Sometimes proposal creation fails if Chef and Crowbar are not quite 
    # fully prepared -- this can happen due to solr not having everything
    # fully indexed yet.  So we don't want to just fail immediatly if 
    # we fail to create a proposal -- instead, we will kick Chef, sleep a bit,
    # and try again up to 5 times before bailing out.
    for ((x=1; x<6; x++)); do
        crowbar crowbar "${proposal_opts[@]}" && { proposal_created=true; break; }
        echo "Proposal create failed, pass $x.  Will kick Chef and try again."
        chef_or_die "Kicking proposal bits"
        sleep 1
    done
    if [[ ! $proposal_created ]]; then
        die "Could not create default proposal"
    fi
fi
crowbar crowbar proposal show default >/var/log/default-proposal.json
crowbar crowbar proposal commit default || \
    die "Could not commit default proposal!"
crowbar crowbar show default >/var/log/default.json
chef_or_die "Chef run after default proposal commit failed!"

# transition though all the states to ready.  Make sure that
# Chef has completly finished with transition before proceeding
# to the next.

for state in "discovering" "discovered" "hardware-installing" \
    "hardware-installed" "installing" "installed" "readying" "ready"
do
    while [[ -f "/tmp/chef-client.lock" ]]; do sleep 1; done
    printf "$state: "
    crowbar crowbar transition "$FQDN" "$state" || \
        die "Transition to $state failed!"
    chef_or_die "Chef run for $state transition failed!"
done

# OK, let looper_chef_client run normally now.
rm /tmp/deploying

# Spit out a warning message if we managed to not get an IP address
# on eth0
get_ip_and_mac eth0
[[ $IP && $MAC ]] || {
    echo "$(date '+%F %T %z'): eth0 not configured, but should have been."
    echo "Things will probably end badly."
    echo "Going ahead and configuring eth0 with 192.168.124.10."
    ip link set eth0 up
    ip addr add 192.168.124.10/24 dev eth0
}

restart_svc_loop chef-client "Restarting chef-client - spot four"
log_to apt apt-get -q --force-yes -y upgrade

# transform our friendlier Crowbar default home page.
cd /tftpboot/ubuntu_dvd/extra
[[ $IP ]] && sed "s@localhost@$IP@g" < index.html >/var/www/index.html

# Run tests -- currently the host will run this.
#/opt/dell/bin/barclamp_test.rb -t || \
#    die "Crowbar validation has errors! Please check the logs and correct."
