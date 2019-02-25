#!/bin/bash

# Select block device (SD card) and write sd.image using dd
#
# $1 - sd.image filepath

SCRIPT_FOLDER="$(dirname $(readlink -f $0))"
SCRIPT_PATH=`pwd`"/$0"
SCRIPT_NAME=`basename $0`

SD_IMAGE="${SCRIPT_FOLDER}/sd.image"
SD_IMAGE_DUMP="${SCRIPT_FOLDER}/sd.image.dump"

USER=`whoami`

SCRIPT_SIZE=`stat --printf "%s" $0`
SCRIPT_SIZE_FIXED=6144

EMBEDDED=0
MD5_SAVED="########## replace_me ##########"

# Exit on error
set -e

# Functions
check_cmd() {
    if ! type $1 1>/dev/null 2>/dev/null
    then
       echo "Error: Command '$1' not found - please install '$1' and try again"
       exit 1
    fi
}

# Comment this to enable debug output:
SILENT=1

# Uncomment this to show executed commands:
SHOWCMD=1

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

cleanup() {
    rm -f "${SD_IMAGE_DUMP}" 1>/dev/null 2>/dev/null

    # Remove extracted image in embedded mode
    if [ $EMBEDDED -eq 1 ]
    then
        rm -f "${SD_IMAGE}"
        rm -f "${SD_IMAGE}.gz"
    fi
}

# Check for required packages
check_cmd lsblk
check_cmd grep
check_cmd sed
check_cmd diff
check_cmd dd
check_cmd awk
check_cmd md5sum
check_cmd gunzip

if [ $EMBEDDED -eq 1 ]
then
    SD_IMAGE="${SCRIPT_FOLDER}/sd.image.xtracted"
fi

SD_IMAGE_NAME=`basename ${SD_IMAGE}`

# Check for commandline params
if [ -z $1 ]
then
    echo "Using default image location: '$SD_IMAGE'"
else
    SD_IMAGE=$1
fi

if [ $EMBEDDED -eq 1 ]
then
    echo "Script is embedded with BLOB image"
    echo "Extracting embedded image to '$SD_IMAGE'...Please wait"

    if [ $SCRIPT_SIZE -le $SCRIPT_SIZE_FIXED ]
    then
        echo "Error: Cannot extract embedded image - script '$SCRIPT_NAME' is very small"
        exit 1
    fi

    # Extract embedded image
    dd status=none if=$0 of="$SD_IMAGE" bs=$SCRIPT_SIZE_FIXED skip=1

    # Check MD5
    echo "Checking MD5..."
    MD5=`cat $SD_IMAGE | md5sum | awk '{print $1}'`

    if [ "$MD5" != "$MD5_SAVED" ]
    then
        echo "Error: md5 check failed"
        echo "Stored MD5:     '$MD5_SAVED'"
        echo "Calculated MD5: '$MD5'"

        cleanup
        exit 1
    else
        echo "MD5 sum correct:"
        echo "Stored MD5:     '$MD5_SAVED'"
        echo "Calculated MD5: '$MD5'"
    fi

    # Check if image file is archived with gzip
    if file "$SD_IMAGE" | grep "gzip" 1>/dev/null 2>&1
    then
        echo "File '$SD_IMAGE_NAME' is a gzip archive - extracting...Please wait"

        mv "$SD_IMAGE" "${SD_IMAGE}.gz"
        gunzip -c "${SD_IMAGE}.gz" > "$SD_IMAGE"

        echo "File '$SD_IMAGE_NAME.gz' extracted as '$SD_IMAGE_NAME'"
    fi

    echo "Done: image file '$SD_IMAGE' extracted from '$SCRIPT_NAME'"
    echo
fi

# Check for image file
if [ ! -f "$SD_IMAGE" ] && [ ! -L "$SD_IMAGE" ]
then
    echo "Error: image file not found: '$SD_IMAGE'"
    exit 1
fi

# Search for block devices
DEVICES=(`lsblk -o NAME,TYPE -n -l | grep disk | sed s/disk//`)
SIZES=(`lsblk -o SIZE,TYPE -n -l | grep disk | sed s/disk//`)

if [ ${#DEVICES[@]} -eq 0 ]
then
    echo "No block devices found - exiting"

    cleanup
    exit 1
fi

echo "Block devices found: "${#DEVICES[@]}
echo

# Show block devices
printf "NUM \t NAME     \t SIZE \t\n"
echo   "---------------------------------------"

i=0

for d in ${DEVICES[@]}
do
    printf "%s \t /dev/%s \t %s \t\n" $i ${DEVICES[$i]} ${SIZES[$i]}
    i=$(($i + 1))
done
echo

# Select block device
while true
do
    echo "Enter SD device number (Ctrl+C to exit):"
    read num

    # Check 'num' is a number
    regexp="^[0-9]+$"

    if [[ ! $num =~ $regexp ]]
    then
        echo "Wrong input: 'num' must be a number"
        continue
    fi

    # Check for number value
    if [ $num -lt 0 ] || [ $num -ge ${#DEVICES[@]} ]
    then
        echo "Error: device num must be between 0 and $((${#DEVICES[@]} - 1))"
        continue
    else
        # Input ok
        break
    fi
done
echo

DEVICE=${DEVICES[$num]}
SIZE=${SIZES[$num]}

echo "Device selected: /dev/${DEVICE} [${SIZE}]"
echo

# Check mount points
MOUNTPOINT=`lsblk -o MOUNTPOINT -n /dev/${DEVICE}`

if [ ! -z "$MOUNTPOINT" ]
then
    echo "Warning! Device '/dev/${DEVICE}' and it's childs mounted as:"
    lsblk -o NAME,MOUNTPOINT -n /dev/${DEVICE}
fi

# Confirm device write
echo "Please confirm device write on '/dev/${DEVICES[$num]}' [Enter 'y' or 'n']:"

read ans
if ! [ $ans == 'y' ]
then
    echo "Write cancelled"

    cleanup
    exit 1
fi

echo "Write confirmed for '/dev/${DEVICE}'"
echo

# Check for super-user righrs
if [ $(id -u) -ne 0 ]; then
    echo "Super-user rights required to write firmware"
    sudo ls 1>/dev/null 2>&1
    echo
fi

# Get firmware size
SDIMAGE_SIZE=`stat --printf "%s" ${SD_IMAGE}`

# Check additional commands
if hash pv 1>/dev/null 2>&1
then
    PV=" | pv -p -s $SDIMAGE_SIZE | dd status=none "
else
    PV=""
fi

# Write firmware
echo "Writing '${SD_IMAGE_NAME}' (${SDIMAGE_SIZE} bytes) to '/dev/${DEVICE}'...Please wait"

DD_CMD="dd status=none if=${SD_IMAGE} ${PV} of=/dev/${DEVICE}"
sudo sh -c "$DD_CMD"

echo "Syncing...Please wait"
sudo sync

# Verify firmware
echo "Verifying '${SD_IMAGE_NAME}' (${SDIMAGE_SIZE} bytes)...Please wait"

DD_CMD="dd status=none if=/dev/${DEVICE} count=1 bs=${SDIMAGE_SIZE} ${PV} of=${SD_IMAGE_DUMP}"
sudo sh -c "$DD_CMD"

echo "Syncing...Please wait"
sudo sync

sudo chown $USER:$USER "${SD_IMAGE_DUMP}"

if ! diff "${SD_IMAGE}" "${SD_IMAGE_DUMP}"
then
    echo "Error: write to '/dev/${DEVICE}' failed"
    echo "Reason: image files differs:"

    md5sum "${SD_IMAGE}"
    md5sum "${SD_IMAGE_DUMP}"

    cleanup
    exit 1
fi

# Done
echo "Completed"
echo "Image file '${SD_IMAGE}' successfully writed to '/dev/${DEVICE}'"

cleanup
exit 0

# Fillers
################################################################################
################################################################################
################################################################################
################################################################################
###########
