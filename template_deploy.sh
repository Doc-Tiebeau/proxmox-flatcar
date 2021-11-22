#!/bin/bash

#set -x # debug mode
set -e

# =============================================================================================
# global vars

# force english messages
export LANG=C
export LC_ALL=C

declare CONFIG_FILE=template_deploy.conf

#Get next available VMID
TEMPLATE_VMID=$(pvesh get /cluster/nextid)

if [[ ! -f "${CONFIG_FILE}" ]] ;then
        echo "ERROR: File ${CONFIG_FILE} doesn't exists"
        exit 1
else
        source ${CONFIG_FILE}
fi

# set for latest version
if [[ -z "${VERSION}" ]] || [[ "${VERSION}" == latest ]];then
        VERSION="current"
fi

TEMPLATE_NAME_FULL="${TEMPLATE_NAME}-${VERSION}"

if [[ -f ${TEMPLATE_NAME_FULL}.id ]] && [[ ${TEMPLATE_RECREATE} != true ]];then
        echo "${TEMPLATE_NAME_FULL} exists. Recreating not asked."
        sleep 2
        TEMPLATE_VMID=$(cat ./${TEMPLATE_NAME_FULL}.id)
        TEMPLATE_CREATE="false"
elif [[ ! -f ${TEMPLATE_NAME_FULL}.id ]];then
        echo "${TEMPLATE_VMID}" > ${TEMPLATE_NAME_FULL}.id
        TEMPLATE_CREATE="true"
elif [[ -f ${TEMPLATE_NAME_FULL}.id ]] && [[ ${TEMPLATE_RECREATE} == true ]];then
        echo "${TEMPLATE_NAME_FULL} exists. Recreating asked !!"
        TEMPLATE_VMID=$(cat ./${TEMPLATE_NAME_FULL}.id)
        qm destroy ${TEMPLATE_VMID} --purge
        rm ./${TEMPLATE_NAME_FULL}.id
        sleep 3
        TEMPLATE_VMID=$(pvesh get /cluster/nextid)
        echo "${TEMPLATE_VMID}" > ${TEMPLATE_NAME_FULL}.id
        TEMPLATE_CREATE="true"
else
#write Template VM_ID in a file.
        TEMPLATE_CREATE="false"
fi

FCAR_IMAGE=flatcar_production_${PLATFORM}_image.img
FCAR_ARCHIVE=${FCAR_IMAGE}.bz2
FCAR_IMAGE_URL=${BASEURL}/amd64-usr/${VERSION}/${FCAR_ARCHIVE}

# =============================================================================================
# main()

# pve storage exist ?
echo -n "Check if vm storage ${TEMPLATE_VMSTORAGE} exist... "
pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet ok ?
echo -n "Check if snippet storage ${SNIPPET_STORAGE} exist... "
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader &> /dev/null || {
        echo -e "[failed]"
        exit 1
}
echo "[ok]"

# pve storage snippet enable
pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep -q snippets || {
	echo "ERROR: You must activate content snippet on storage: ${SNIPPET_STORAGE}"
	exit 1
}

# copy files
echo "Copy hook-script and ignition config to snippet storage..."
snippet_storage="$(pvesh get /storage/${SNIPPET_STORAGE} --noborder --noheader | grep ^path | awk '{print $NF}')"
cp -av ${TEMPLATE_IGNITION} hook-fcar.sh ${snippet_storage}/snippets
sed -e "/^FCAR_TMPLT/ c\FCAR_TMPLT=${snippet_storage}/snippets/${TEMPLATE_IGNITION}" -i ${snippet_storage}/snippets/hook-fcar.sh
chmod 755 ${snippet_storage}/snippets/hook-fcar.sh

# storage type ? (https://pve.proxmox.com/wiki/Storage)
echo -n "Get storage \"${TEMPLATE_VMSTORAGE}\" type... "
case "$(pvesh get /storage/${TEMPLATE_VMSTORAGE} --noborder --noheader | grep ^type | awk '{print $2}')" in
        dir|nfs|cifs|glusterfs|cephfs) TEMPLATE_VMSTORAGE_type="file"; echo "[file]"; ;;
        lvm|lvmthin|iscsi|iscsidirect|rbd|zfs|zfspool) TEMPLATE_VMSTORAGE_type="block"; echo "[block]" ;;
        *)
                echo "[unknown]"
                exit 1
        ;;
esac

# download flatcar qemu vdisk image
if [[ ! -f ${FCAR_IMAGE} ]] ;then
    echo "Download flatcar qemu vdisk image..."
    wget --show-progress --no-check-certificate ${FCAR_IMAGE_URL} #REVIEW pass --no-check-certificate because of Let's Encrypt ROOT CA Cert changed on 2021 Q4
    bzip2 --decompress --quiet ${FCAR_ARCHIVE}
fi

# create a new VM

if [[ ${TEMPLATE_CREATE} == "true" ]];then
        echo "Create flatcar vm template ${TEMPLATE_VMID}"
        qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME_FULL}
        qm set ${TEMPLATE_VMID} --memory 2048 \
                                --cpu host \
                                --cores 2 \
                                --agent enabled=1 \
                                --autostart \
                                --onboot 1 \
                                --ostype l26 \
                                --tablet 0 \
                                --boot c --bootdisk scsi0

        template_vmcreated=$(date +%Y-%m-%d)
        qm set ${TEMPLATE_VMID} --description "Flatcar Linux Template

        - Version             : ${VERSION}
        - Cloud-init          : true

        Creation date : ${template_vmcreated}
        "

        qm set ${TEMPLATE_VMID} --net0 virtio,bridge=vmbr0

        echo -e "\nCreate Cloud-init vmdisk..."
        qm set ${TEMPLATE_VMID} --ide2 ${TEMPLATE_VMSTORAGE}:cloudinit

        # import flatcar disk
        if [[ "x${TEMPLATE_VMSTORAGE_type}" = "xfile" ]]
        then
                vmdisk_name="${TEMPLATE_VMID}/vm-${TEMPLATE_VMID}-disk-0.qcow2"
                vmdisk_format="--format qcow2"
        else
                vmdisk_name="vm-${TEMPLATE_VMID}-disk-0"
                vmdisk_format=""
        fi
        qm importdisk ${TEMPLATE_VMID} ${FCAR_IMAGE} ${TEMPLATE_VMSTORAGE} ${vmdisk_format}

        qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${TEMPLATE_VMSTORAGE}:${vmdisk_name}${VMDISK_OPTIONS}

        # set hook-script
        qm set ${TEMPLATE_VMID} -hookscript ${SNIPPET_STORAGE}:snippets/hook-fcar.sh

        # convert vm template
        echo -n "Convert VM ${TEMPLATE_VMID} in proxmox vm template... "
        qm template ${TEMPLATE_VMID} &> /dev/null || true
        echo "[done]"
fi
echo
echo
if [[ ${TEMPLATE_CREATE} == "true" ]] && [[ ${TEMPLATE_RECREATE} == "false" ]];then
        echo "SUCCESS: ${TEMPLATE_NAME_FULL}  with ID: ${TEMPLATE_VMID} created on \"${TEMPLATE_VMSTORAGE}\" storage"
elif [[ ${TEMPLATE_CREATE} == "true" ]] && [[ ${TEMPLATE_CREATE} == "true" ]];then
        echo "SUCCESS: ${TEMPLATE_NAME_FULL}  with ID: ${TEMPLATE_VMID} Re-created on \"${TEMPLATE_VMSTORAGE}\" storage"
elif [[ ${TEMPLATE_CREATE} == "false" ]];then
        echo "SUCCESS: ${TEMPLATE_NAME_FULL} with ID: ${TEMPLATE_VMID} updated"
fi
echo
echo