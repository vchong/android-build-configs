#!/bin/bash -e

ROOT_DIR=$(cd $(dirname $0); pwd)
CUR_DIR=$(pwd)
CPUS=$(nproc)

#### TODO LIST ###########################
# 1. support for OUT_DIR specification
# 2. support for repo sync multiple configs
#    into one workspace
##########################################

### variables could be changed via parameters
build_config=lcr-reference-hikey-p
MIRROR=""
skip_init=false
skip_sync=false
PINNED_MANIFEST=""

########### workarounds ##################
# workaround for boot_fat.uefi.img for error:
# AssertionError: Can only handle FAT with 1 reserved sector
# git clone https://github.com/dosfstools/dosfstools -b v3.0.28
# cd dosfstools && make
export PATH=${ROOT_DIR}/dosfstools:${PATH}

# workaround to use openjdk-8 for oreo builds
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64/
export PATH=${JAVA_HOME}/bin:$PATH

########### contants #####################
REPO_URL="git://android.git.linaro.org/tools/repo"
BASE_MANIFEST="default.xml"
build_config_url="https://android-git.linaro.org/android-build-configs.git/plain"

######## functions define ################
function export_config(){
    local f_config=$1
    while read line; do
        if echo "${line}"|tr -d '[:blank:]'|grep -q '^$'; then
            continue
        fi
        if ! echo $line |grep -q '^#'; then
            eval "export $line"
        fi
    done < ${f_config}
}

function repo_sync_patch(){
    if [ ! -f android-build-configs/${build_config} ]; then
        f_tmp=$(mktemp -u lcr-XXX)
        wget ${build_config_url}/${build_config} -O ${f_tmp}
        export_config ${f_tmp}
        #rm -fr ${f_tmp}
    else
        export_config android-build-configs/${build_config}
    fi
    if ! ${skip_init}; then
        while ! repo init \
            -u "${MIRROR:-${MANIFEST_REPO}}" \
            -m "${BASE_MANIFEST}" \
            -g "${REPO_GROUPS}" \
            -b "${MANIFEST_BRANCH}" \
            --repo-url=${REPO_URL} \
            --no-repo-verify; do
            sleep 30
        done
    fi

    # only clone or update local_manifests when pinned manifest file not exist
    if [ -z "${PINNED_MANIFEST}" ]; then
        if [ -d .repo/local_manifests ]; then
            pushd .repo/local_manifests
            git pull
            popd
        else
            git clone "${LOCAL_MANIFEST}" -b "${LOCAL_MANIFEST_BRANCH}" .repo/local_manifests
        fi
    elif [ -d .repo/local_manifests ]; then
        echo "Please remove the .repo/local_manifests directory first"
        echo "Otherwise duplicate of projects error might be reported"
        exit 1
    fi

    if [ -n "${PINNED_MANIFEST}" ]; then
        PINNED_MANIFEST_name=$(basename ${PINNED_MANIFEST})
        PINNED_MANIFEST_dir=$(cd $(dirname ${PINNED_MANIFEST}); pwd)
        PINNED_MANIFEST_ABS="${PINNED_MANIFEST_dir}/${PINNED_MANIFEST_name}"
        repo_sync_cmd="repo sync -c -j${CPUS} -m ${PINNED_MANIFEST_ABS}"
    else
        repo_sync_cmd="repo sync -c -j${CPUS}"
    fi

    while ! ${repo_sync_cmd}; do
        echo "Try again for repo sync in one minute"
        sleep 60
    done

    for patch in ${PATCHSETS}; do
        ./android-patchsets/${patch}
    done
}

function build_with_config(){
    local f_config="android-build-configs/${build_config}"
    export_config "${f_config}"

    source build/envsetup.sh
    lunch ${TARGET_PRODUCT}-${TARGET_BUILD_VARIANT}

    echo "Start to build:" >>time.log
    date +%Y-%m-%d-%H-%M >>time.log
    (time LANG=C make ${MAKE_TARGETS} -j${CPUS} ) 2>&1 |tee build-${TARGET_PRODUCT}.log
    date +%Y-%m-%d-%H-%M >>time.log
}

function print_usage(){
    echo "$(basename $0) [-si|--skip_init] [-c|--config <config file name>] [-m|--mirror mirror_url] [-pm|--pinned-manifest]"
    echo -e "\t -ss|--skip-sync: skip to run repo sync and apply patchsets, for cases like only build"
    echo -e "\t -si|--skip-init: skip to run repo init, for cases like run on hackbox"
    echo -e "\t -c|--config branch: build config file name under:"
    echo -e "\t\t\thttps://android-git.linaro.org/android-build-configs.git/tree"
    echo -e "\t\tdefault is lcr-reference-hikey-p"
    echo -e "\t -m|--mirror mirror_url: specify the url where you want to sync from"
    echo -e "\t -pm|--pinned-manifest file_path: specify the path where you put the pinned manifest file"
    echo "$(basename $0) [-h|--help]"
    echo -e "\t -h|--help: print this usage"
}

function parseArgs(){
    while [ -n "$1" ]; do
        case "X$1" in
            X-ss|X--skip-sync)
                skip_sync=true
                shift
                ;;
            X-si|X--skip-init)
                skip_init=true
                shift
                ;;
            X-c|X--config)
                if [ -z "$2" ]; then
                    echo "Please specify the build config file name for the -c|--config option"
                    exit 1
                fi
                build_config="$2"
                shift 2
                ;;
            X-m|X--mirror)
                if [ -z "$2" ]; then
                    echo "Please specify the repo sync mirror url with the -c|--config option"
                    exit 1
                fi
                MIRROR="$2"
                shift 2
                ;;
            X-pm|X--pinned-manifest)
                if [ -z "$2" ]; then
                    echo "Please specify the path for the pinned manifest file with the -pm|--pinned-manifest option"
                    exit 1
                fi
                PINNED_MANIFEST="$2"
                shift 2
                ;;
            X-h|X--help)
                print_usage
                exit 1
                ;;
            X-*)
                echo "Unknown option: $1"
                print_usage
                exit 1
                ;;
            X*)
                echo "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

function install_packages(){
    # Some of the packges might be not necessary anymore for
    # android build, but not going to figure them out here.
    sudo apt-get update
    packages="acpica-tools bc bison build-essential ccache curl flex genisoimage"
    packages="${packages} git git-core g++-multilib gnupg gperf lib32ncurses5-dev lib32z-dev"
    packages="${packages} libc6-dev-i386 libdrm-intel1 libgl1-mesa-dev liblz4-tool libssl-dev"
    packages="${packages} libx11-dev libxml2-utils linaro-image-tools lzop mtools openjdk-8-jdk"
    packages="${packages} patch python-crypto python-mako python-parted python-pip python-requests"
    packages="${packages} python-wand python-yaml rsync time u-boot-tools unzip uuid-dev"
    packages="${packages} vim-common wget x11proto-core-dev xsltproc zip zlib1g-dev"
    sudo apt-get install -y ${packages}
}

function main(){
    parseArgs "$@"
    if ! ${skip_sync}; then
        repo_sync_patch
    fi
    install_packages
    build_with_config
}

main "$@"
