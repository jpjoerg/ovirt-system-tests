#!/bin/bash -ex

# Imports
source common/helpers/logger.sh

CLI="vagrant"
DO_CLEANUP=false
EXTRA_SOURCES=()
RPMS_TO_INSTALL=()
COVERAGE=false
usage () {
    echo "
Usage:

$0 [options] SUITE

This script runs a single suite of tests (a directory of tests repo)

Positional arguments:
    SUITE
        Path to directory that contains the suite to be executed

Optional arguments:
    -o,--output PATH
        Path where the new environment will be deployed.
        PATH shouldn't exist.

    -c,--cleanup
        Clean up any generated lago workdirs for the given suite, it will
        remove also from libvirt any domains if the current lago workdir fails
        to be destroyed

    -s,--extra-rpm-source
        Extra source for rpms, any string valid for repoman will do, you can
        specify this option several times. A common example:
            -s http://jenkins.ovirt.org/job/ovirt-engine_master_build-artifacts-el7-x86_64/123

        That will take the rpms generated by that job and use those instead of
        any that would come from the reposync-config.repo file. For more
        examples visit repoman.readthedocs.io

    -r,--reposync-config
        Use a custom reposync-config file, the default is SUITE/reposync-config.repo

    -l,--local-rpms
        Install the given RPMs from Lago's internal repo.
        The RPMs are being installed on the host before any tests being invoked.
        Please note that this option WILL modify the environment it's running
        on and it requires root permissions.

    --only-verify-requirements
        Verify that the system has the correct requirements (Disk Space, RAM, etc...)
        and exit.

    --ignore-requirements
        Don't fail if the system requirements are not satisfied.

    --coverage
        Enable coverage
"
}

on_exit() {
    [[ "$?" -ne 0 ]] && logger.error "on_exit: Exiting with a non-zero status"
    logger.info "Dumping lago env status"
    env_status || logger.error "Failed to dump env status"
}

on_sigterm() {
    local dest="${OST_REPO_ROOT}/test_logs/${SUITE##*/}/post-suite-sigterm"

    set +e
    export CLI
    export -f env_collect
    timeout \
        120s \
        bash -c "env_collect $dest"

    exit 143
}

verify_system_requirements() {
    local prefix="${1:?}"

    "${OST_REPO_ROOT}/common/scripts/verify_system_requirements.py" \
        --prefix-path "$prefix" \
        "${SUITE}/vars/main.yml"
}


generate_vdsm_coverage_report() {
    [[ "$COVERAGE" = true ]] || return 0
    declare coverage_dir="${OST_REPO_ROOT}/coverage/vdsm"
    mkdir -p "$coverage_dir"
    python "${OST_REPO_ROOT}/common/scripts/generate_vdsm_coverage_report.py" "$PREFIX" "$coverage_dir"
}


env_repo_setup () {
    # not needed for vagrant
    local extrasrc
    declare -a extrasrcs
    cd $PREFIX
    for extrasrc in "${EXTRA_SOURCES[@]}"; do
        extrasrcs+=("--custom-source=$extrasrc")
        logger.info "Adding extra source: $extrasrc"
    done
    local reposync_conf="$SUITE/reposync-config.repo"
    if [[ -e "$CUSTOM_REPOSYNC" ]]; then
        reposync_conf="$CUSTOM_REPOSYNC"
    fi
    if [[ -n "$OST_SKIP_SYNC" ]]; then
        skipsync="--skip-sync"
    else
        skipsync=""
    fi
    logger.info "Using reposync config file: $reposync_conf"
    http_proxy="" $CLI ovirt reposetup \
        $skipsync \
        --reposync-yum-config "$reposync_conf" \
        "${extrasrcs[@]}"
    cd -
}


env_start () {
    export VAGRANT_CWD="$PREFIX"
    cd "$PREFIX"
    cp "${SUITE}/Vagrantfile" .
    "$CLI" up
    cd -
}


env_stop () {

    cd "$PREFIX"
    "$CLI" halt
    cd -
}


env_deploy () {

    local res=0
    cd "$PREFIX"
    $CLI ovirt deploy || res=$?
    cd -
    return "$res"
}

env_status () {

    cd $PREFIX
    $CLI status
    $CLI ssh-config
    cd -
}


env_version() {
    "$CLI" --version
    "$CLI" plugin list
}

env_run_test () {

    local res=0
    cd $PREFIX
    local junitxml_file="$PREFIX/${1##*/}.junit.xml"
    $CLI ovirt runtest $1 --junitxml-file "${junitxml_file}"  || res=$?
    [[ "$res" -ne 0 ]] && xmllint --format ${junitxml_file}
    cd -
    return "$res"
}

env_ansible () {

    # Ensure latest Ansible modules are tested:
    rm -rf $SUITE/ovirt-deploy/library || true
    rm -rf $SUITE/ovirt-deploy/module_utils || true
    mkdir -p $SUITE/ovirt-deploy/library
    mkdir -p $SUITE/ovirt-deploy/module_utils
    cd $SUITE/ovirt-deploy/library
    ANSIBLE_URL_PREFIX="https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/modules/cloud/ovirt/ovirt_"
    for module in vm disk cluster datacenter host network quota storage_domain template vmpool nic
    do
      OVIRT_MODULES_FILES="$OVIRT_MODULES_FILES $ANSIBLE_URL_PREFIX$module.py "
    done

    wget -N $OVIRT_MODULES_FILES
    cd -

    wget https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/module_utils/ovirt.py -O $SUITE/ovirt-deploy/module_utils/ovirt.py
}


env_collect () {
    local tests_out_dir="${1?}"

    [[ -e "${tests_out_dir%/*}" ]] || mkdir -p "${tests_out_dir%/*}"
    cd "$PREFIX/current"
    $CLI collect --output "$tests_out_dir"
    cp -a "logs" "$tests_out_dir/lago_logs"
    cd -
}


env_cleanup() {

    local res=0
    local uuid

    logger.info "Cleaning up"
    if [[ -e "$PREFIX" ]]; then
        logger.info "Cleaning with lago"
        $CLI --workdir "$PREFIX" destroy --yes --all-prefixes || res=$?
        [[ "$res" -eq 0 ]] && logger.success "Cleaning with lago done"
    elif [[ -e "$PREFIX/uuid" ]]; then
        uid="$(cat "$PREFIX/uuid")"
        uid="${uid:0:4}"
        res=1
    else
        logger.info "No uuid found, cleaning up any lago-generated vms"
        res=1
    fi
    if [[ "$res" -ne 0 ]]; then
        logger.info "Lago cleanup did not work (that is ok), forcing libvirt"
        env_libvirt_cleanup "${SUITE##*/}" "$uid"
    fi
    restore_package_manager_config
    logger.success "Cleanup done"
}


env_libvirt_cleanup() {
    local suite="${1?}"
    local uid="${2}"
    local domain
    local net
    if [[ "$uid" != "" ]]; then
        local domains=($( \
            virsh -c qemu:///system list --all --name \
            | egrep "$uid*" \
        ))
        local nets=($( \
            virsh -c qemu:///system net-list --all \
            | egrep "$uid*" \
            | awk '{print $1;}' \
        ))
    else
        local domains=($( \
            virsh -c qemu:///system list --all --name \
            | egrep "[[:alnum:]]*-lago-${suite}-" \
            | egrep -v "vdsm-ovirtmgmt" \
        ))
        local nets=($( \
            virsh -c qemu:///system net-list --all \
            | egrep -w "[[:alnum:]]{4}-.*" \
            | egrep -v "vdsm-ovirtmgmt" \
            | awk '{print $1;}' \
        ))
    fi
    logger.info "Cleaning with libvirt"
    for domain in "${domains[@]}"; do
        virsh -c qemu:///system destroy "$domain"
    done
    for net in "${nets[@]}"; do
        virsh -c qemu:///system net-destroy "$net"
    done
    logger.success "Cleaning with libvirt Done"
}

get_package_manager() {
    [[ -x /bin/dnf ]] && echo dnf || echo yum
}

get_package_manager_config() {
    local pkg_manager

    pkg_manager="$(get_package_manager)"
    echo "/etc/${pkg_manager}/${pkg_manager}.conf"
}

backup_package_manager_config() {
    local path_to_config  path_to_config_bak

    path_to_config="$(get_package_manager_config)"
    path_to_config_bak="${path_to_config}.ost_bak"

    if [[ -e "$path_to_config_bak" ]]; then
        # make sure we only try to backup once
        return
    fi
    cp "$path_to_config" "$path_to_config_bak"
}

restore_package_manager_config() {
    local path_to_config  path_to_config_bak

    path_to_config="$(get_package_manager_config)"
    path_to_config_bak="${path_to_config}.ost_bak"

    if ! [[ -e "$path_to_config_bak" ]]; then
        return
    fi
    cp -f "$path_to_config_bak" "$path_to_config"
    rm "$path_to_config_bak"
}

install_local_rpms() {
    local pkg_manager os path_to_config

    [[ ${#RPMS_TO_INSTALL[@]} -le 0 ]] && return

    pkg_manager="$(get_package_manager)"
    path_to_config="$(get_package_manager_config)"

    os=$(rpm -E %{dist})
    os=${os#.}
    os=${os%.*}

    backup_package_manager_config

    cat > "$path_to_config" <<EOF
[internal_repo]
name=Lago's internal repo
baseurl="file://${PREFIX}/current/internal_repo/default/${os}"
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF

    $pkg_manager -y install "${RPMS_TO_INSTALL[@]}" || return 1

    return 0
}

main() {
    options=$( \
        getopt \
            -o ho:e:n:b:cs:r:l:i \
            --long help,output:,engine:,node:,boot-iso:,cleanup,images \
            --long extra-rpm-source,reposync-config:,local-rpms: \
            --long only-verify-requirements,ignore-requirements \
            --long coverage \
            -n 'run_suite.sh' \
            -- "$@" \
    )
    if [[ "$?" != "0" ]]; then
        exit 1
    fi
    eval set -- "$options"

    while true; do
        case $1 in
            -o|--output)
                PREFIX=$(realpath -m $2)
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -c|--cleanup)
                DO_CLEANUP=true
                shift
                ;;
            -s|--extra-rpm-source)
                EXTRA_SOURCES+=("$2")
                shift 2
                ;;
            -l|--local-rpms)
                RPMS_TO_INSTALL+=("$2")
                shift 2
                ;;
            -r|--reposync-config)
                readonly CUSTOM_REPOSYNC=$(realpath "$2")
                shift 2
                ;;
            --only-verify-requirements)
                readonly ONLY_VERIFY_REQUIREMENTS=true
                shift
                ;;
            --ignore-requirements)
                readonly IGNORE_REQUIREMENTS=true
                shift
                ;;
            --coverage)
                readonly COVERAGE=true
                shift
                ;;
            --)
                shift
                break
                ;;
        esac
    done

    if [[ -z "$1" ]]; then
        logger.error "No suite passed"
        usage
        exit 1
    fi

    export OST_REPO_ROOT="$PWD"

    export SUITE="$(realpath --no-symlinks "$1")"
    #export VAGRANT_HOME="$SUITE"
    # If no deployment path provided, set the default
    [[ -z "$PREFIX" ]] && PREFIX="$PWD/deployment-${SUITE##*/}"
    export PREFIX

    if "$DO_CLEANUP"; then
        env_cleanup
        exit $?
    fi

    [[ -e "$PREFIX" ]] && {
        echo "Failed to run OST. \
            ${PREFIX} shouldn't exist. Please remove it and retry"
        exit 1
    }

    mkdir -p "$PREFIX"
    [[ "$IGNORE_REQUIREMENTS" ]] || verify_system_requirements "$PREFIX"
    [[ $? -ne 0 ]] && { rm -rf "$PREFIX"; exit 1; }
    [[ "$ONLY_VERIFY_REQUIREMENTS" ]] && { rm -rf "$PREFIX"; exit; }

    [[ -d "$SUITE" ]] \
    || {
        logger.error "Suite $SUITE not found or is not a dir"
        exit 1
    }

    trap "on_sigterm" SIGTERM
    trap "on_exit" EXIT

    logger.info "Using $(env_version)"

    logger.info  "Running suite found in $SUITE"
    logger.info  "Environment will be deployed at $PREFIX"

    export PYTHONPATH="${PYTHONPATH}:${SUITE}"
    source "${SUITE}/control_vagrant.sh"

    # prep_suite
    run_suite
    logger.success "$SUITE - All tests passed :)"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
