#!/bin/bash

set -e -u
# set -x

function die() {
    echo "$@"
    exit 1
}

function usage() {
    die "usage: $0 <image> <ami name> <loopback device mapper name> <virtualization-type> <networking type> [<grub-ver>]"
}

[ $EUID -eq 0 ] || die "must be root"
[ $# -eq 5 ] || [ $# -eq 6 ] || usage

_basedir="$( cd $( dirname -- $0 )/.. && /bin/pwd )"

[ -e "${1}" ] || die "$1 doesn't exist"

img="$( readlink -f ${1} )"
ami_name="${2}"
block_dev="${3}"
img_target_dev="/dev/mapper/${block_dev}1"
virt_type="${4}"
net_type="${5}"
shift 5

[ "${virt_type}" = "hvm" ] || [ "${virt_type}" = "paravirtual" ] || die "virtualization type must be hvm or paravirtual"
[ "${net_type}" = "sriov" ] || [ "${net_type}" = "normal" ] || die "networking type must be sriov or normal"

if [ "${virt_type}" = "hvm" ] && [ $# -ne 1 ]; then
    usage
fi

if [ "${virt_type}" = "paravirtual" ]; then
    grub_ver="not applicable"

    ## http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedKernels.html
    ## pv-grub-hd0_1.04-x86_64.gz; specific to us-east-1!
    kernel_id="--kernel-id aki-919dcaf8"

    ## http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/block-device-mapping-concepts.html
    root_device="/dev/sda"
elif [ "${virt_type}" = "hvm" ]; then
    grub_ver="${1}"
    
    [ "${grub_ver}" = "grub0" ] || [ "${grub_ver}" = "grub2" ] || die "grub version must be grub0 or grub2"

    ## kernel id only applies for paravirtualized instances
    kernel_id=""
    
    ## the root device for the block device mapping
    root_device="/dev/xvda"
fi

if [ "${net_type}" = "sriov" ]; then
  enhanced_networking="--sriov-net-support simple"
fi

## A client error (InvalidAMIName.Malformed) occurred when calling the
## RegisterImage operation: AMI names must be between 3 and 128 characters long,
## and may contain letters, numbers, '(', ')', '.', '-', '/' and '_'
if [ ${#ami_name} -lt 3 ] || [ ${#ami_name} -gt 128 ]; then
    echo "illegal length for ami_name; must be >= 3, <= 128"
    exit 1
fi

# if echo $ami_name | egrep -q '[^a-z0-9 ()./_-]' ; then
#     echo "illegal characters in ami_name; must be [a-z0-9 ()./_-]"
#     exit 1
# fi

echo "executing with..."
echo "    img: ${img}"
echo "    ami_name: ${ami_name}"
echo "    block_dev: ${block_dev}"
echo "    vol_id: ${vol_id}"
echo "    virt_type: ${virt_type}"
echo "    grub_ver: ${grub_ver}"
echo "    kernel_id: ${kernel_id}"
echo "    root_device: ${root_device}"

## check for required programs
which aws       >/dev/null 2>&1 || die "need aws"
which curl      >/dev/null 2>&1 || die "need curl"
which jq        >/dev/null 2>&1 || die "need jq"
which e2fsck    >/dev/null 2>&1 || die "need e2fsck"
which resize2fs >/dev/null 2>&1 || die "need resize2fs"
which hdparm    >/dev/null 2>&1 || die "need hdparm"
which parted    >/dev/null 2>&1 || die "need parted"
which losetup   >/dev/null 2>&1 || die "need losetup"
which dmsetup   >/dev/null 2>&1 || die "need dmsetup"
which kpartx    >/dev/null 2>&1 || die "need kpartx"


## the device map must not already exist
[ -e "/dev/mapper/${block_dev}" ] && die "${block_dev} already exists"

## set up/verify aws credentials and settings
## http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html
## FIXME ##export AWS_DEFAULT_REGION="$( curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's#.$##g' )"
[ -n "${AWS_ACCESS_KEY_ID}" ]     || die "AWS_ACCESS_KEY_ID not set"
[ -n "${AWS_SECRET_ACCESS_KEY}" ] || die "AWS_SECRET_ACCESS_KEY not set"

if [ "$( aws ec2 describe-images --filters "Name=name,Values=${ami_name}" | jq -r '.Images | length' )" -ne 0 ]; then
    die "AMI with that name already exists!"
fi

## create 10GB loopback volume
mb_size=10240
sec_size=$((${sec_size} * 1024 * 1024 / 512))
dd if=/dev/zero status=noxfer of=bundle.img bs=1M count=1 seek=$((${mb_size} - 1))
## partition volume
parted --script bundle.img -- 'unit s mklabel msdos mkpart primary 63 -1s set 1 boot on print quit'
## attach image file to loopback device
loop_dev=$(losetup -f)
loop_name=$(basename ${loop_dev})
losetup ${loop_dev} bundle.img
majmin=$(cat /sys/block/${loop_name}/dev)
echo 0 ${sec_size} linear ${majmin} 0|dmsetup create ${block_dev}
kpartx -a /dev/mapper/${block_dev}


## write image to volume
echo "writing image to ${img_target_dev}"
dd if=${img} of=${img_target_dev} conv=fsync oflag=sync bs=8k

## force-check the filesystem; re-write the image if it fails
if ! fsck.ext4 -n -f ${img_target_dev} ; then
    echo "well, that didn't work; trying again"
    dd if=${img} of=${img_target_dev} conv=fsync oflag=sync bs=8k
    fsck.ext4 -n -f ${img_target_dev}
fi

## resize the filesystem
e2fsck -f ${img_target_dev}
resize2fs ${img_target_dev}

if [ "${virt_type}" = "hvm" ]; then
    ## install grub bootloader for hvm instances; they boot like real hardware

    # mount the volume so
    vol_mnt="/mnt/ebs_vol"
    mkdir -p ${vol_mnt}
    mount -t ext4 ${img_target_dev} ${vol_mnt}
    
    ## mount special filesystems so the chroot is like running in a real
    ## instance.  hopefully this is pretty distro- and kernel-agnostic…
    mount -t proc none ${vol_mnt}/proc
    mount -o bind /dev ${vol_mnt}/dev
    mount -o bind /sys ${vol_mnt}/sys
    
    if [ ${grub_ver} = "grub0" ]; then
        # make ${vol_mnt}/boot/grub/device.map with contents
        #   (hd0) ${block_dev}
        # because otherwise grub-install isn't happy, even with --recheck
        echo "(hd0) ${block_dev}" > ${vol_mnt}/boot/grub/device.map
        
        ## also need to create fake /etc/mtab so grub-install can figure out
        ## what device / is
        echo "${img_target_dev} / ext4 rw,relatime 0 0" > ${vol_mnt}/etc/mtab
        
        chroot ${vol_mnt} /sbin/grub-install --no-floppy ${block_dev}

        rm -f ${vol_mnt}/etc/mtab ${vol_mnt}/boot/grub/device.map
    elif [ ${grub_ver} = "grub2" ]; then
        ## *aaah* so much simpler!
        
        ## @todo move grub2-mkconfig to ami-creator (add grub2 support)
        chroot ${vol_mnt} /sbin/grub2-mkconfig -o /boot/grub2/grub.cfg
        chroot ${vol_mnt} /sbin/grub2-install ${block_dev}
    fi

    umount ${vol_mnt}/{proc,dev,sys,}
fi

## unmount/clean up loopback
kpartx -d /dev/mapper/${block_dev}
dmsetup remove ${block_dev}
losetup -d ${loop_dev}
## FIXME ##
## bundle image
ec2-bundle-image --foo --bar --region --whatever

## kernel-id hard-coded
## see http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedKernels.html
## fuck me, bash space escaping is a pain in the ass.
image_id=$( \
    aws ec2 register-image \
    ${kernel_id} \
    --architecture x86_64 \
    --name "${ami_name}" \
    --root-device-name ${root_device} \
    ## FIXME ## --block-device-mappings "[{\"DeviceName\":\"${root_device}\",\"Ebs\":{\"SnapshotId\":\"${snap_id}\",\"VolumeSize\":10}},{\"DeviceName\":\"/dev/sdb\",\"VirtualName\":\"ephemeral0\"}]" \
    --virtualization-type ${virt_type} \
    ${enhanced_networking} \
    | jq -r .ImageId
)

echo "created AMI with id ${image_id}"

## create json file next to input image
{
    echo "{"
    echo "    \"virt_type\": \"${virt_type}\", "
    echo "    \"snapshot_id\": \"${snap_id}\", "
    echo "    \"ami_id\": \"${image_id}\""
    echo "}"
} > "${img%.*}.json"
