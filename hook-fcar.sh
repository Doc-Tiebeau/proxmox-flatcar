#!/bin/bash

#set -e
 
vmid="$1"
phase="$2"

# global vars
FCAR_TMPLT=/opt/flatcar-tmplt.yaml
FCAR_FILES_PATH=/etc/pve/flatcar
# YQ="/usr/local/bin/yq read --exitStatus --printMode v --stripComments --"
YQ="/usr/local/bin/yq e"

# ==================================================================================================================================================================
# functions()
#
setup_flatcar-config-transpiler()
{
        local CT_VER=0.9.1
        local ARCH=x86_64
        local OS=unknown-linux-gnu # Linux
        local DOWNLOAD_URL=https://github.com/flatcar-linux/container-linux-config-transpiler/releases/download
 
        # [[ -x /usr/local/bin/flatcar-config-transpiler ]]&& [[ "x$(/usr/local/bin/flatcar-config-transpiler --version | awk '{print $NF}')" == "x${CT_VER}" ]]&& return 0
        echo
				echo "Setup Flatcar Linux config transpiler..."
				echo
				if [[ "$(/usr/local/bin/flatcar-config-transpiler --version)" != "ct v${CT_VER}" ]];then
					echo "Updating Container Linux Config Transpiler to version ${CT_VER}"
        	rm -f /usr/local/bin/flatcar-config-transpiler
        	wget --quiet --show-progress ${DOWNLOAD_URL}/v${CT_VER}/ct-v${CT_VER}-${ARCH}-${OS} -O /usr/local/bin/flatcar-config-transpiler
        	chmod 755 /usr/local/bin/flatcar-config-transpiler
				else
					echo "Container Linux Config Transpiler already exists with expected version (v${CT_VER}). Continue..."
				fi
}
setup_flatcar-config-transpiler

setup_yq()
{
        # local VER=3.4.1
        local YQ_VER=4.14.1

        [[ -x /usr/bin/wget ]] && download_command="wget --quiet --show-progress --output-document"  || download_command="curl --location --output"
        if [[ -x /usr/local/bin/yq ]] && [[ "$(/usr/local/bin/yq --version | awk '{print $NF}')" != "${YQ_VER}" ]];then
        	echo "Updating yaml parser tool from v$(/usr/local/bin/yq --version | awk '{print $NF}') to v${YQ_VER}..."
					rm -f /usr/local/bin/yq
        	${download_command} /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v${YQ_VER}/yq_linux_amd64
        	chmod 755 /usr/local/bin/yq
				else
					echo "yaml parser tool (YQ) already exists with expected version. Continue..."
				fi
}
setup_yq

mask2cdr ()
{
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}


cdr2mask()
{
	# Number of args to shift, 255..255, first non-255 byte, zeroes
	set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
	[[ $1 -gt 1 ]] && shift $1 || shift
	echo ${1-0}.${2-0}.${3-0}.${4-0}
}

# ==================================================================================================================================================================
# main()
#
if [[ "${phase}" == "pre-start" ]]
then
	# instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} - 'instance-id')"
	instance_id="$(qm cloudinit dump ${vmid} meta | ${YQ} '.instance-id' -)"

	# same cloudinit config ?
	[[ -e ${FCAR_FILES_PATH}/${vmid}.id ]] && [[ "x${instance_id}" != "x$(cat ${FCAR_FILES_PATH}/${vmid}.id)" ]]&& {
		rm -f ${FCAR_FILES_PATH}/${vmid}.ign # cloudinit config change
	}
	[[ -e ${FCAR_FILES_PATH}/${vmid}.ign ]]&& exit 0 # already done

	mkdir -p ${FCAR_FILES_PATH} || exit 1
		
	# check config
	cipasswd="$(qm cloudinit dump ${vmid} user | grep ^password | awk '{print $NF}')" || true # can be empty
	[[ "x${cipasswd}" != "x" ]]&& VALIDCONFIG=true
	${VALIDCONFIG:-false} || [[ "x$(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys[]' -)" == "x" ]]|| VALIDCONFIG=true
	${VALIDCONFIG:-false} || {
		echo "Flatcar Linux: you must set passwd or ssh-key before start VM: ${vmid}"
		exit 1
	}

  echo
  echo
	echo -n "Flatcar Linux: Generate yaml users block... "
	ciuser="$(qm cloudinit dump ${vmid} user 2> /dev/null | grep ^user: | awk '{print $NF}')"

	echo -e "# This file is generated at pre-start. Do not edit manualy.\n" > ${FCAR_FILES_PATH}/${vmid}.yaml
	
	if [[ $(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys[]' - 2> /dev/null) ]];then
	ssh_authorized_keys="$(qm cloudinit dump ${vmid} user | ${YQ} '.ssh_authorized_keys[]' - | sed -e 's/^/        - "/' -e 's/$/"/')"
	else
		echo
		echo -e "No ssh_authorized_keys found."
		echo 
		ssh_authorized_keys=''
	fi


	echo "
passwd:
  users:
    - name: "${ciuser:-core}"
      gecos: "Flatcar Administrator"
      password_hash: "${cipasswd}"
      groups: [ "sudo", "docker", "adm", "wheel", "systemd-journal" ]
      ssh_authorized_keys: "${ssh_authorized_keys}"

" >> ${FCAR_FILES_PATH}/${vmid}.yaml
	echo "[done]"

	echo -n "Flatcar Linux: Generate yaml network block... "

	netcards="$(qm cloudinit dump ${vmid} network | ${YQ} '.config[].name' - 2> /dev/null | wc -l)"

#Network Block	
	echo "
networkd:
  units:
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

	for (( i=O; i<${netcards}; i++ ))
	do
		netcard_name="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].name" - 2> /dev/null)"
		if [[ ${netcard_name} != "null" ]];then
			
			nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].address[]" -)"
			if [[ -z ${nameservers} ]];then
				nameservers="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[$((${i}+1))].address[]" -)"
			fi
			
			searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].search[]" -)"
			if [[ -z ${searchdomain} ]];then
				searchdomain="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[$((${i}+1))].search[]" -)"
			fi

			ipv4="" netmask="" gw="" macaddr="" # reset on each run
			ipv4="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].subnets[0].address" - 2> /dev/null)" || continue # dhcp
			netmask="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].subnets[0].netmask" - 2> /dev/null)"
			cidr="$(mask2cdr ${netmask})"
			gw="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].subnets[0].gateway" - 2> /dev/null)" || true # can be empty
			macaddr="$(qm cloudinit dump ${vmid} network | ${YQ} ".config[${i}].mac_address" - 2> /dev/null)"
			# ipv6: TODO: Disable explicitly IPV6

			echo "
  - name: 00-${netcard_name}.network
    contents: |
      [Match]
      Name=${netcard_name}

      [Network]
      DNS=${nameservers}
      Address=${ipv4}/${cidr}
      Gateway=${gw}
      Domains=${searchdomain}
" >> ${FCAR_FILES_PATH}/${vmid}.yaml
		fi

	done
	echo "[done]"

	echo -n "Flatcar Linux: Generate yaml hostname block... "
	hostname="$(qm cloudinit dump ${vmid} user | ${YQ} '.hostname' - 2> /dev/null)"

# Storage block
	echo "
storage:
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

	echo "
  filesystems:
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

echo "
    - name: oem
      mount:
        device: /dev/disk/by-label/OEM
        format: ext4
        label: OEM
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

	echo "
  files:
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

	echo "
    - path: /etc/hostname
      mode: 0644
      overwrite: true
      contents:
        inline: |
          ${hostname}
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

# Disable autologin
echo "
    - path: /grub.cfg
      filesystem: oem
      mode: 0644
      contents:
        inline: |
          set oem_id=\"qemu\"
          set linux_append=\"\"
" >> ${FCAR_FILES_PATH}/${vmid}.yaml

	echo "[done]"
	

	if [[ -e "${FCAR_TMPLT}" ]];then
		echo -n "Flatcar Linux: Generate other block based on template... "
		cat "${FCAR_TMPLT}" >> ${FCAR_FILES_PATH}/${vmid}.yaml
		echo "[done]"
	fi


	echo -n "Flatcar Linux: Generate ignition config... "
	/usr/local/bin/flatcar-config-transpiler 	--pretty --strict \
				--out-file ${FCAR_FILES_PATH}/${vmid}.ign \
				--in-file ${FCAR_FILES_PATH}/${vmid}.yaml 2> /dev/null
	[[ $? -eq 0 ]] || {
		echo "[failed]"
		exit 1
	}
	echo "[done]"

	# save cloudinit instanceid
	echo "${instance_id}" > ${FCAR_FILES_PATH}/${vmid}.id

	# check vm config (no args on first boot)
	qm config ${vmid} --current | grep -q ^args || {
		echo -n "Set args opt/org.flatcar-linux/config on VM${vmid}... "
		rm -f /var/lock/qemu-server/lock-${vmid}.conf || echo "Remove lock failed"
		pvesh set /nodes/$(hostname)/qemu/${vmid}/config --args "-fw_cfg name=opt/org.flatcar-linux/config,file=${FCAR_FILES_PATH}/${vmid}.ign" 2> /dev/null || {
			echo "[failed]"
			exit 1
		}
		touch /var/lock/qemu-server/lock-${vmid}.conf

		# hack for reload new ignition file
		echo -e "\nWARNING: New generated Flatcar Linux ignition settings, restarting vm ${vmid}."
		qm start ${vmid}
		sleep 10
		qm stop ${vmid} && sleep 2 && qm start ${vmid}
		exit 0
	}
fi
