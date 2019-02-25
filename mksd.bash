#!/bin/bash
#
# Ti mksd-ti816x.sh based script
#
# Create a bootable SD for AM3894 ARM Cortex-A8 based modules
#
# BTMODE[0:5] pins settings:
# 10010 - NAND boot
# 10111 - SD boot
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -e

PATH=$PATH:/sbin

# Comment this to enable debug output:
SILENT=1

# Uncomment this to show executed commands:
#SHOWCMD=0

run_cmd() {
    if [ -n "$SHOWCMD" ]
    then
        echo "running: $@"
    fi

    if [ -n "$SILENT" ]
    then
        "$@" 1>/dev/null 2>/dev/null
    else
        "$@"
    fi
}

check_cmd() {
    if ! type $1 1>/dev/null 2>/dev/null
    then
       echo "Error: Command '$1' not found - please install '$1' and try again"
       exit 1
    fi
}

# Check for required commands
check_cmd fdisk
check_cmd losetup
check_cmd modprobe
check_cmd dd
check_cmd mkfs.vfat #dosfstools package
check_cmd mount
check_cmd umount
check_cmd partprobe #parted package
check_cmd md5sum
check_cmd gzip

# Configure directoy paths
SCRIPT_DIR="$(dirname $(readlink -f $0))"
TOP_DIR="$(dirname $(readlink -f $SCRIPT_DIR))"

# Check for mandatory cmdline params
if [[ -z $1 ]]
then
    echo "Make a bootable SD card for AM3894 based modules"
    echo "Notice: super user rights required to use 'mount', 'dd' etc commands"
    echo "$0 usage:"
    echo "    $0 <device> <u-boot.bin> <env_nand.bin> <uImage> <rootfs>"
    echo "    $0 <device> <binaries folder>"
    echo "    Example: $0 /dev/sdc u-boot.bin env_nand.bin uImage rootfs.ubi"
    echo "    Example: $0 sd.image u-boot.bin env_nand.bin uImage rootfs.ubi"
    echo "    Example: $0 sd.image _tools/bin"
    exit
fi

DRIVE=$1

if [[ -d $2 ]]
then
    # $1 - SD device
    # $2 - binaries folder
    dir="$(readlink -f $2)"

    UBOOT=$dir/u-boot.bin
    ENV_BIN=$dir/env_nand.bin
    UIMAGE=$dir/uImage
    ROOTFS=$dir/rootfs.ubi
else
    # $1 - SD device
    # $2 - u-boot.bin
    # $3 - env_nand.bin
    # $4 - uImage
    # $5 - rootfs

    # Default binaries location
    UBOOT=$2
    ENV_BIN=$3
    UIMAGE=$4
    ROOTFS=$5

    if [[ -z $2 ]]
    then
        UBOOT=$TOP_DIR/u-boot/u-boot.bin
    fi

    if [[ -z $3 ]]
    then
        ENV_BIN=$TOP_DIR/u-boot/env_nand.bin
    fi

    if [[ -z $4 ]]
    then
        UIMAGE=$TOP_DIR/kernel/uImage
    fi

    if [[ -z $5 ]]
    then
        ROOTFS=$TOP_DIR/rootfs/rootfs.ubi
    fi
fi

CH=$TOP_DIR/u-boot/CH
MLO=MLO
ENV_TXT=$TOP_DIR/u-boot/env_nand.txt

RND=`date | md5sum | gawk '{print $1}'`
MNT=/tmp/mksd-$RND

# Check block device mode
EXISTS=1
BLOCK_DEVICE=0
LOOP_DEVICE=0
SDFILE=""
PART="$DRIVE"1

if ! [[ -e $DRIVE ]]
then
    EXISTS=0

    echo "Warning: '$DRIVE' not found."
    echo "Insert SD-card or proceed in image creation mode."
    echo
    echo "SD-card image file '$DRIVE' will be created. Proceed? [y/n]"

    read ans
    if ! [ $ans == 'y' ]
    then
        exit 1
    else
        SDFILE=$DRIVE
        DRIVE=""
    fi
fi

if [ "$EXISTS" == 1 ]
then
    if [ -b $DRIVE ]
    then
        BLOCK_DEVICE=1
        echo "$DRIVE is a block device"
    fi

    if [ -f $DRIVE ]
    then
        BLOCK_DEVICE=0
        SDFILE=$DRIVE
        DRIVE=$SDFILE
        echo "$SDFILE is a regular file"
    fi

    if [ -c $DRIVE ]
    then
        echo "Error: $DRIVE is a character device"
        exit 1
    fi
fi

# Check files exists
if ! [[ -e $UBOOT ]]
then
    echo "Incorrect u-boot.bin location: '$UBOOT'"
    exit
fi

if ! [[ -e $UIMAGE ]]
then
    echo "Incorrect uImage location: '$UIMAGE'"
    exit
fi

if ! [[ -e $ROOTFS ]]
then
    echo "Incorrect rootfs location: '$ROOTFS'"
    exit
fi

if ! [[ -e $CH ]]
then
    echo "Incorrect CH header location: '$CH'"
    exit
fi

if ! [[ -e $ENV_BIN ]]
then
    echo "Incorrect U-boot env location: '$ENV_BIN'"
    exit
fi

if ! [[ -e $ENV_TXT ]]
then
    echo "Incorrect U-boot env location: '$ENV_TXT'"
    exit
fi

# Check for sudo
if [ $(id -u) -ne 0 ]; then
    echo "Requesting sudo privileges:"
    sudo echo "Ok" && rc=$? || rc=$? && true #do not exit on error

    if [ "$rc" != 0 ]
    then
        USER=`whoami`
        echo "Error: sudo request failed - check '$USER' privileges"
        exit 1
    fi
fi

# Prepare SD card image
if [ "$BLOCK_DEVICE" == 0 ]
then
    if [ "$EXISTS" == 0 ]
    then
        echo "[Creating file '$SDFILE'...]"
        run_cmd sudo dd if=/dev/zero of=$SDFILE bs=1M count=72
    else
        echo "[Using file '$SDFILE'...]"
        run_cmd sudo dd if=/dev/zero of=$SDFILE bs=1M count=72
    fi #if [ "$EXISTS" == 0 ]

    # Prepare kernel modules (loop)
    echo "[Loading required kernel modules...]"
    sudo modprobe loop && rc=$? || rc=$? && true #do not exit on error

    if [ "$rc" != 0 ]
    then
        echo "Error: 'modprobe loop' failed - SD image creation impossible"
        exit 1
    fi

    # Setup loop device
    echo "[Attaching loop device for file '$SDFILE'...]"
    DRIVE=`sudo losetup --find --show $SDFILE`
    PART="$DRIVE"p1

    echo "loop device $DRIVE attached"
fi


# Prepare SD card
echo
echo "Block device $DRIVE information:"
sudo fdisk -l | grep $DRIVE && true
echo

# Check for loop block device - disable fdisk errors
LOOP=`echo $DRIVE | grep 'loop' > /dev/null && echo 1 || echo 0`

if [ "$LOOP" == 1 ]
then
    echo "Warning: Block device '$DRIVE' is a loop device - disabling fdisk errors"
    LOOP_DEVICE=1
    PART="$DRIVE"p1
fi

# Check for MMC device to set correct PART name
MMC=`echo $DRIVE | grep 'mmc' > /dev/null && echo 1 || echo 0`

if [ "$MMC" == 1 ]
then
    echo "Using MMC device: $DRIVE"
    LOOP_DEVICE=0
    PART="$DRIVE"p1
fi

# Display warning
echo
echo "Warning!"
echo "All data on "$DRIVE" now will be destroyed! Continue? [y/n]"
read ans
if ! [ $ans == 'y' ]
then
    exit
fi

# Cleaning up SD card
echo "[Unmounting all mounted partitions from $DRIVE...]"
if [ "$LOOP_DEVICE" == 0 ]
then
    run_cmd sudo umount -f "${DRIVE}1" || true
    run_cmd sudo umount -f "${DRIVE}2" || true
    run_cmd sudo umount -f "${DRIVE}3" || true
    run_cmd sudo umount -f "${DRIVE}4" || true
else
    run_cmd sudo umount -f "${DRIVE}p1" || true
    run_cmd sudo umount -f "${DRIVE}p2" || true
    run_cmd sudo umount -f "${DRIVE}p3" || true
    run_cmd sudo umount -f "${DRIVE}p4" || true
fi

echo "[Removing all existing partitions from $DRIVE...]"
{
echo d     # delete 4
echo
echo d     # delete 3
echo
echo d     # delete 2
echo
echo d     # delete 1
echo
echo w     # write changes
echo q     # quit
} | run_cmd sudo fdisk $DRIVE && rc=$? || rc=$? && true #do not exit on error

if [ "$LOOP_DEVICE" == 0 ] #'Re-reading partition table failed' is not an error if loop device used
then
    # Unrecoverable error
    if [ "$rc" != 0 ]
    then
        echo "Error: fdisk partition delete failed - please re-run $0, reinsert SD-card, reboot OS"
        if [ "$LOOP_DEVICE" == 1 ]
        then
            run_cmd sudo losetup -D
        fi
        exit 1
    fi
fi #if [ "$LOOP_DEVICE" == 1 ]

# Remove CH settings header to avoid unwanted RAW boot
echo "[Removing possible CHSETTINGS header from $DRIVE...]"
run_cmd sudo dd if=/dev/zero of=$DRIVE bs=1024 count=1024 conv=sync

echo "[Updating partition information from $DRIVE...]"
sudo partprobe $DRIVE || true

echo "[Partitioning $DRIVE...]"

rc=1
retry=0

while [ "$rc" != 0 ];
do
    {
    echo n     # new
    echo p     # primary
    echo 1     # 1
    echo 2048  # start sector
    echo +64M  # size
    echo t     # change type
    echo c     # to W95 FAT32
    # With bootable flag set AM3894 On-chip bootloader tries
    # to load MLO image from FAT32 partition instead of RAW sector
    # but max MLO size at FAT32 is 128 KB
    # and we use u-boot without SPL wich is 128 KB+ in size
    # so just not set boot flag
    #echo a    # set bootable flag
    echo w     # write changes
    echo q     # quit
    } | run_cmd sudo fdisk $DRIVE && rc=$? || rc=$? && true #do not exit on error

    if [ "$BLOCK_DEVICE" == 1 ]
    then
        if [ ! -e "$PART" ]
        then
            echo "Updating partition information '$PART' using 'partprobe'"
            run_cmd sudo partprobe $DRIVE || true
        else
            echo "fdisk done: new partition found in $DRIVE:"
            sudo fdisk -l | grep $DRIVE

            rc=0
            retry=0
        fi #if [ ! -e "$PART" ];

        if [ $retry -ge 3 ]
        then
            echo "Erorr: Partitioning $DRIVE failed on retry: $retry"
            exit 1
        fi

        retry=$(expr $retry + 1)
    fi #if [ "$BLOCK_DEVICE" == 1 ]

    if [ "$LOOP_DEVICE" == 1 ] #'Re-reading partition table failed' is not an error if loop device used
    then
        rc=0
    fi #if [ "$LOOP_DEVICE" == 1 ]
done #while $rc != 0

echo "[Making filesystems...]"
run_cmd sudo mkfs.vfat -F 32 -n boot "$PART" && rc=$? || rc=$? && true

# Retry on first error with partprobe
if [ "$rc" != 0 ]
then
    echo "mkfs.vfat: retrying after error..."
    run_cmd sudo partprobe $DRIVE || true
    sleep 3
    run_cmd sudo mkfs.vfat -F 32 -n boot "$PART" && rc=$? || rc=$? && true
fi

# Unrecoverable error
if [ "$rc" != 0 ]
then
    echo "Error: FAT32 filesystem creation failed - please re-run $0, reinsert SD-card, reboot OS"
    if [ "$LOOP_DEVICE" == 1 ]
    then
        run_cmd sudo losetup -D
    fi
    exit 1
fi

echo "[Preparing MLO using '$UBOOT'...]"
run_cmd $TOP_DIR/u-boot/prep_mlo $UBOOT

# Using RAW boot mode (25.7.4.6 in AM3894 Technical Reference Manual)
# Placing boot image with Configuration Header (CH) at second location (128 KB offset)

echo "[Installing CH settings header '$CH'...]"
run_cmd sudo dd if=$CH of=$DRIVE bs=1 seek=$((0x20000)) conv=notrunc

echo "[Installing MLO bootloader...]"
run_cmd sudo dd if=$MLO of=$DRIVE bs=1 seek=$((0x20200)) conv=notrunc

echo "[Generating MD5 sums...]"
run_cmd $SCRIPT_DIR/generate_md5sums $UBOOT $UIMAGE $ROOTFS
cat md5sums.txt

echo "[Mounting '$PART' at '$MNT'...]"

if [ ! -d "$MNT" ]
then
    run_cmd mkdir -p "$MNT"
fi

sudo mount "$PART" $MNT && rc=$? || rc=$? && true
if [ "$rc" != 0 ]
then
    echo "Error mounting '$PART' as '$MNT'"
    __error 1
fi

echo "[Copying files...]"
sudo cp $MLO $MNT/MLO
sudo cp $UBOOT $MNT/u-boot.bin

sudo cp $ENV_BIN $MNT/env_nand.bin
sudo cp $ENV_TXT $MNT/env_nand.txt

sudo cp $UIMAGE $MNT/uImage
sudo cp $ROOTFS $MNT/

sudo cp md5sums.bin $MNT/md5sums.bin
sudo cp md5sums.txt $MNT/md5sums.txt

sudo sync

ls -Al $MNT

# Clean up
echo "[Unmounting ${PART}...]"
sudo umount -f "$PART"

echo "[Cleaning up files...]"

rm $MLO

if [ "$LOOP_DEVICE" == 1 ]
then
    echo "[Detaching SD card image file '$SDFILE' from '$DRIVE'...]"
    sudo losetup -d $DRIVE
fi

if [ "$BLOCK_DEVICE" == 1 ]
then
    echo "[Block device '$DRIVE' successfully prepared]"
else
    # Attach prepare.sh to binary file
    PREPARE_SH="$SCRIPT_DIR/prepare.sh"

    if [ ! -f $PREPARE_SH ] && [ ! -L $PREPARE_SH ]
    then
        echo "Error: prepare.sh not found in '${SCRIPT_DIR}' - leaving $SDFILE as raw BLOB"
        exit 1
    fi

    echo "[Attaching prepare.sh to '$SDFILE'...]"

    # Archive SDFILE
    run_cmd gzip -9 $SDFILE

    if [ ! -f "$SDFILE.gz" ]
    then
        echo "Error: '$SDFILE.gz' not found after archiving"
        exit 1
    fi

    run_cmd mv "$SDFILE.gz" "$SDFILE"

    # Calculate MD5 for archived SDFILE
    MD5=`cat $SDFILE | md5sum | awk '{print $1}'`
    echo "MD5 sum: $MD5"

    # Attach prepare.sh
    run_cmd sudo mv $SDFILE $SDFILE.tmp
    run_cmd cp $PREPARE_SH $SDFILE

    sed -i "s/EMBEDDED=0/EMBEDDED=1/" "$SDFILE"
    sed -i "s/MD5_SAVED=\"########## replace_me ##########\"/MD5_SAVED=\"${MD5}\"/" "$SDFILE"

    run_cmd dd if=$SDFILE.tmp of=$SDFILE oflag=append conv=notrunc
    run_cmd chmod +x $SDFILE
    run_cmd sync
    run_cmd sudo rm $SDFILE.tmp

    echo "[SD-card image '$SDFILE' successfully prepared]"
fi

# Functions definitions
__error() {
    if [ "$LOOP_DEVICE" == 1 ]
    then
        echo "[Detaching SD card image file '$SDFILE' from '$DRIVE'...]"
        sudo losetup -d $DRIVE | true
    fi

    echo "Removing $MLO"
    rm -f $MLO | true

    exit $1
}
