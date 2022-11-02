#!/bin/bash

ROOT_DIR=`pwd`



export BUILD_DATE=`date +"%Y%m%d"`

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# source dirs
export a3700_utils=${ROOT_DIR}/A3700-utils-marvell
export atf=${ROOT_DIR}/trusted-firmware-a
export uboot=${ROOT_DIR}/u-boot
export mvddr=${ROOT_DIR}/mv-ddr-marvell
export kernel=${ROOT_DIR}/linux
export cryptopp=${ROOT_DIR}/cryptopp
export mox=${ROOT_DIR}/mox-boot-builder

# for atf
export BL33=${uboot}/u-boot.bin
export CROSS_CM3=arm-linux-gnueabi-
export WTP=${a3700_utils}
export MV_DDR_PATH=${mvddr}
export CRYPTOPP_PATH=${cryptopp}
export WTMI_IMG=${mox}/wtmi_app.bin
export FIP_ALIGN=0x100

export PRJNAME=espressobin_ultra
export BUILDTYPE=release

if [ "${BUILDTYPE}" == "release" ]; then
    DATESTR="${BUILD_DATE}-rel"
else
    DATESTR="${BUILD_DATE}-dbg"
fi
export BUILDOUT=${ROOT_DIR}/out/build-${DATESTR}

function query_commitid {
    local path=$1

    # query latest commit
    if [ -d "$path/.git" ]; then
        commitid=`git -C $path log --no-merges --pretty=format:"%h%n" -1`
    else
        commitid="0000000"
    fi

    echo $commitid
}

function query_ddr {
    local topology=$1
    local ddr_type
    local cs_mask
    local ddr_size
    local value

    # get ddr_type
    value=$(awk -F"=" '/ddr_type/ {print $2}' $a3700_utils/tim/ddr/DDR_TOPOLOGY_$topology.txt)
    if [ "$value" == "0" ]; then
        ddr_type="ddr3"
    else
        ddr_type="ddr4"
    fi

    # get ddr_cs_mask
    value=$(awk -F"=" '/ddr_cs_mask/ {print $2}' $a3700_utils/tim/ddr/DDR_TOPOLOGY_$topology.txt)
    if [ "$value" == "1" ]; then
        cs_mask="1cs"
    else
        cs_mask="2cs"
    fi

    # get ddr_mem_size
    value=$(awk -F"=" '/ddr_mem_size_index/ {print $2}' $a3700_utils/tim/ddr/DDR_TOPOLOGY_$topology.txt)

    case $value in
      0) if [ "$cs_mask" = "2cs" ]; then  ddr_size="128m"; else ddr_size="64m"; fi ;;
      1) if [ "$cs_mask" = "2cs" ]; then  ddr_size="256m"; else ddr_size="128m"; fi ;;
      2) if [ "$cs_mask" = "2cs" ]; then  ddr_size="512m"; else ddr_size="256m"; fi ;;
      3) if [ "$cs_mask" = "2cs" ]; then  ddr_size="1g"; else ddr_size="512m"; fi ;;
      4) if [ "$cs_mask" = "2cs" ]; then  ddr_size="2g"; else ddr_size="1g"; fi ;;
      5) if [ "$cs_mask" = "2cs" ]; then  ddr_size="4g"; else ddr_size="2g"; fi ;;
      6) if [ "$cs_mask" = "2cs" ]; then  ddr_size="8g"; else ddr_size="4g"; fi ;;
    esac
    echo ${ddr_type}-${cs_mask}-${ddr_size}
}

function cpu_string {

    local cpu_speed=$1

    case ${cpu_speed} in
        800) str="cpu-800" ;;
        1000) str="cpu-1000" ;;
        1200) str="cpu-1200" ;;
    esac

    echo $str
}

function updateConfig {
    local conf=$1
    local key=$2
    local data=$3

    if [ -z "$conf" ] || [ -z "$key" ]; then
        return 1
    fi

    num=`awk -F"=" '!/^($|[[:space:]]*#)/ && /^(\s*)'${key}[^A-Za-z0-9_]'/ {print NR}' ${conf}`
    if [ -z "${num}" ]; then
        if [ ! -z "${data}" ]; then
            # not found, add new key pair to conf
            echo "${key}=${data}" >> ${conf}
        fi
    else
        if [ -z "${data}" ]; then
            # del the key
            sed -i "${num}d" ${conf}
        else
            # update the data
            sed -i "${num}c ${key}=${data}" ${conf}
        fi
    fi
    return 0
}

function create_dir {
    local dir=$1

    if [ -z "$dir" ]; then
        return
    fi

    if [ ! -d "$dir" ]; then
        mkdir -p $dir
    fi
}

# build_uboot $defconfig $device-tree-file $boot-type
function build_uboot {
    local defconfig=${1}
    local dts=${2}
    local bootdev=${3}

    if [ -f $uboot/u-boot.bin ]; then
        # remove old u-boot.bin
        rm $uboot/u-boot.bin
    fi

    # update u-boot commit id
    UBOOTGITID=$(query_commitid $uboot)

    if [ "${BUILDTYPE}" == "release" ]; then
        make -C $uboot distclean
        #if [ -d "$uboot/.git" ]; then
        #    git -C $uboot clean -f
        #fi
    fi

    make -C $uboot $defconfig

    # update emmcboot config
    if [ "$bootdev" == "emmc" ]; then
        updateConfig $uboot/.config 'CONFIG_MVEBU_MMC_BOOT' 'y'
        updateConfig $uboot/.config 'CONFIG_SYS_MMC_ENV_PART' '1'
    fi

    if [ -z "${dts}" ]; then
        make -C $uboot
    else
        make -C $uboot DEVICE_TREE=${dts}
    fi

    return 0
}

# build $ddr_topology $cpu_speed $bootdev
function build_atf {

    local ddr_topology=$1
    local cpu_speed=$2
    local bootdev=$3

    # build wtmi.app
    make -C ${mox} \
        CROSS_CM3=${CROSS_CM3} \
        clean wtmi_app.bin

    # clean a3700-utils image to prevent using old ddr image
    make -C $a3700_utils \
        DDR_TOPOLOGY=${ddr_topology} \
        clean

    # update a3700_utils commit id
    WTPGITID=$(query_commitid $a3700_utils)

    # update atf commit id
    ATFGITID=$(query_commitid $atf)

    ddrstr=$(query_ddr $ddr_topology)
    cpustr=$(cpu_string $cpu_speed)

    if [ -z "${ddrstr}" ] || [ -z "${cpustr}" ]; then
        echo "unknown ddr or cpu type"
        return 1
    fi

    ddr_speed=800 # default to use 800MHz for ddr speed
    if [ $cpu_speed == 1200 ]; then
        ddr_speed=750
    fi

    # build image
    make -C $atf distclean

    if [ $bootdev != "emmc" ]; then
        make -C $atf \
            CROSS_COMPILE=${CROSS_COMPILE}		\
            CROSS_CM3=${CROSS_CM3}			\
            USE_COHERENT_MEM=0				\
            PLAT=a3700					\
            CLOCKSPRESET=CPU_${cpu_speed}_DDR_${ddr_speed} \
            DDR_TOPOLOGY=${ddr_topology}		\
            MV_DDR_PATH=${MV_DDR_PATH}			\
            WTP=${WTP}					\
            CRYPTOPP_PATH=${CRYPTOPP_PATH}		\
            BL33=${BL33}				\
            WTMI_IMG=${WTMI_IMG}			\
            FIP_ALIGN=${FIP_ALIGN}			\
            DEBUG=0					\
            LOG_LEVEL=20				\
            clean mrvl_flash mrvl_uart
        # spi-flash boot
        FLASHOUT=${BUILDOUT}/${PRJNAME}-bootloader-${cpustr}-${ddrstr}-atf-${ATFGITID}-uboot-g${UBOOTGITID}-utils-${WTPGITID}-${DATESTR}.bin

        # uartboot
        UARTIMG=${BUILDOUT}/${PRJNAME}-uartboot-${cpustr}-${ddrstr}-atf-${ATFGITID}-uboot-${UBOOTGITID}-utils-${WTPGITID}-${DATESTR}.tgz
        cp $atf/build/a3700/release/uart-images.tgz.bin ${UARTIMG}
    else
        make -C $atf \
            CROSS_COMPILE=${CROSS_COMPILE}		\
            CROSS_CM3=${CROSS_CM3}			\
            USE_COHERENT_MEM=0				\
            PLAT=a3700					\
            CLOCKSPRESET=CPU_${cpu_speed}_DDR_${ddr_speed} \
            DDR_TOPOLOGY=${ddr_topology}		\
            MV_DDR_PATH=${MV_DDR_PATH}			\
            WTP=${WTP}					\
            CRYPTOPP_PATH=${CRYPTOPP_PATH}		\
            BL33=${BL33}				\
            WTMI_IMG=${WTMI_IMG}			\
            FIP_ALIGN=${FIP_ALIGN}			\
            DEBUG=0					\
            LOG_LEVEL=20				\
            BOOTDEV=EMMCNORM 				\
            PARTNUM=1 					\
            clean mrvl_flash
        # emmc boot
        FLASHOUT=${BUILDOUT}/${PRJNAME}-emmcloader-${cpustr}-${ddrstr}-atf-${ATFGITID}-uboot-g${UBOOTGITID}-utils-${WTPGITID}-${DATESTR}.bin
    fi

    OUTPUTMSG="${OUTPUTMSG}`basename ${FLASHOUT}`\n"
    # copy image to output folder
    cp $atf/build/a3700/release/flash-image.bin ${FLASHOUT}

    sync

    return 0
}

function build_bootloader {
    local TARGET="5,1000 5,1200"

    OUTPUTMSG=""

    # build cellular-cpe
    build_uboot gti_espressobin-ultra_defconfig armada-3720-espressobin-ultra flash

    # build axc300 hw.v3
    #build_uboot gti_axc300-88f3720_defconfig armada-3720-axc300-v3 flash

    if [ ! -f ${BL33} ]; then
        echo "Failed to build u-boot!"
        return 0
    fi

    for type in ${TARGET}
    do
        topology=`echo $type | awk -F"," '{print $1}'`
        speed=`echo $type | awk -F"," '{print $2}'`
        build_atf $topology $speed flash
    done

    local TARGET="5,1000 5,1200"

    # for emmcloader

    # build cellular-cpe
    build_uboot gti_espressobin-ultra_defconfig armada-3720-espressobin-ultra emmc

    # build axc300 hw.v3
    #build_uboot gti_axc300-88f3720_defconfig armada-3720-axc300-v3 emmc

    if [ ! -f ${BL33} ]; then
        echo "Failed to build u-boot!"
        return 0
    fi

    for type in ${TARGET}
    do
        topology=`echo $type | awk -F"," '{print $1}'`
        speed=`echo $type | awk -F"," '{print $2}'`
        build_atf $topology $speed emmc
    done
    printf "\nOutput:\n${OUTPUTMSG}\n"
}

function build_kernel {

    if [ "${BUILDTYPE}" == "release" ]; then
        if [ -f $kernel/.scmversion ]; then
            rm $kernel/.scmversion
            make -C $kernel clean
        fi
    else
        if [ ! -f $kernel/.scmversion ]; then
            touch $kernel/.scmversion
        fi
    fi

    #make -C $kernel gti_ccpe-88f3720_defconfig
    make -C $kernel -j4
    make -C $kernel modules_install INSTALL_MOD_PATH=${BUILDOUT}

    if [ -f "$kernel/arch/arm64/boot/Image" ]; then
        create_dir ${BUILDOUT}/boot

        cp $kernel/arch/arm64/boot/Image ${BUILDOUT}/boot/
        cp $kernel/arch/arm64/boot/dts/marvell/armada-3720-espressobin-ultra.dtb ${BUILDOUT}/boot/
    fi
}

# gtibuild $build-prj $build-type $version
function gtibuild {
    local build_prj=$1
    local build_type=$2
    local build_ver=$3

    if [ -z "$build_type" ]; then
        export BUILDTYPE=debug
    fi
    export BUILDTYPE=$build_type

    if [ "${BUILDTYPE}" == "release" ]; then
        DATESTR="${BUILD_DATE}-rel"
    else
        DATESTR="${BUILD_DATE}-dbg"
    fi

    export BUILDOUT=${ROOT_DIR}/out/build-${DATESTR}

    create_dir ${BUILDOUT}

    case $build_prj in
      "bootloader")
        build_bootloader
      ;;
      "kernel")
        build_kernel
      ;;
      "all")
        build_bootloader
        build_kernel
      ;;
      *)
        echo "Unknown project"
      ;;
    esac
}

# create output directory
create_dir ${BUILDOUT}
