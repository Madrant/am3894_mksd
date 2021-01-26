#!/bin/sh

BOOT_FORMAT="./boot_format"

print_help() {
    echo "$0 - prepare SD card to run U-boot at Freescale P2020 board"
    echo "Usage:"
    echo "$0 <sd> <.dat file> <U-boot image>"
}

setup_sd() {
    if [ ! -f $2 ]
    then
        echo "Boot loader configuration file \"$2\" not found"
        exit
    fi

    if [ ! -f $3 ]
    then
        echo "U-boot image \"$3\" not found"
        exit
    fi

    if [ ! -f $BOOT_FORMAT ]
    then
        echo "boot_format executable \"$BOOT_FORMAT\" not found"
        exit
    fi

    echo "SD card selected: $1"
    fdisk -l | grep $1
    echo "Boot loader configuration file: $2"
    echo "U-boot image: $3"

    SD=$1
    DAT=$2
    UBOOT=$3

    echo "Creating sd card image using boot_format"
    $BOOT_FORMAT $DAT $UBOOT -spi spiimage > /dev/null

    echo "Analyzing boot_format image"

    UBOOT_OFFSET=`dd if=spiimage bs=1 count=4 skip=$((0x50)) 2>/dev/null | hexdump -e '"0x" 4/1 "%02x" "\n"' | grep 0x`
    echo "U-boot offset: $UBOOT_OFFSET"

    UBOOT_SIZE=`dd if=spiimage bs=1 count=4 skip=$((0x48)) 2>/dev/null | hexdump -e '"0x" 4/1 "%02x" "\n"' | grep 0x`
    echo "U-boot size: $UBOOT_SIZE"

    BOOT_PARAMS_PAIRS=`dd if=spiimage bs=1 count=4 skip=$((0x68)) 2>/dev/null | hexdump -e '"0x" 4/1 "%02x" "\n"' | grep 0x`
    echo "Boot parameters pairs: $BOOT_PARAMS_PAIRS"

    BOOT_PARAMS_SIZE=`echo "$((0x40)) + $(($BOOT_PARAMS_PAIRS)) * 8" | bc`
    echo "Boot parameters size: $BOOT_PARAMS_SIZE"

    echo "Writing boot parameters to $SD at offset 0x40"
    dd if=spiimage of=$SD bs=1 count=$BOOT_PARAMS_SIZE skip=$((0x40)) seek=$((0x40)) 2>/dev/null

    echo "Writing U-boot image $UBOOT to $SD at offset $UBOOT_OFFSET"
    dd if=$UBOOT of=$SD bs=1 count=$((UBOOT_SIZE)) seek=$((UBOOT_OFFSET))

    echo "Installation successfull"
}

if [ $# -eq 3 ]
then
    setup_sd $1 $2 $3
else
    print_help
fi

