#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

declare -r __program=$(basename $0)

declare -r __dec_cmd="openssl enc -d"

# usage function
function usage()
{
   cat << HEREDOC

   Usage: $__program [ command opts] -- [ list of dirs ]

   options:
     -h, --help                         this help
     -l, --local-dir    path            dir for local storage
     -k, --key          key-path        full path of keepassxc db key
                                        default ~/.ssh/rclone-backup
     -d, --database     database-path   full path of keepassxc db
                                        default ~/.rclone-backup.kdbx
HEREDOC
}

parse_cmdline() {
  while [[ $# -gt 0 ]] ; do
    case "$1" in
      -h | --help) usage ; exit ; ;;
      -l | --local-dir)
        shift ;
        local_dir=$1;
        #echo "tmp dir : $local_dir"
        shift ;
        ;;
      -k | --key)
        shift ;
        keepass_key=$1;
        #echo "key : $keepass_key"
        shift ;
        ;;
      -d | --database)
        shift ;
        keepass_db=$1
        #echo "database : $keepass_db"
        shift ;
        ;;
      --)
        shift;
        break
        ;;
    esac
  done

  restore_list=${@}
}


fetch_keepass_entry () {
  local keepass_cmd="keepassxc-cli show --show-protected $__keepass_std_arg $entry_path"

  entry_password=$($keepass_cmd | grep Password | sed 's/Password: //')
  entry_title=$($keepass_cmd | grep Title | sed 's/Title: //')
  entry_group=${result%/*}
}


find_keepass_entry_from_url() {
  local url=$1
  entry_path=""
  entry_password=""
  entry_title=""
  entry_group=""

  echo "  keepass search entry for $url"
  local result=$(keepassxc-cli export -f csv $__keepass_std_arg | grep -v Recycle | grep $url | awk -F',' '{print $1 $2}' | sed 's/""/\//' | sed 's/"//g' | sed 's/Passwords\///')
  if [[ ! -z $result ]] ; then
    # get existing entry info
    echo "  keepass entry found for $url: $result"
    entry_path=$result
    fetch_keepass_entry
  fi
}

process_directory() {
  local l_dir=$1
  local old_hash="empty"

  new_hash=$(tar cf - $l_dir | sha512sum | cut -d ' ' -f 1)
  if [[ -f "$local_dir/${entry_title}.checksum" ]] ; then
    old_hash=$(cat "$local_dir/${entry_title}.checksum")
  fi

  if [[ $new_hash != $old_hash ]] ; then
    enc_directory $l_dir
    echo $new_hash > "$local_dir/${entry_title}.checksum"
  else
    echo "  Unchanged content skipping re-encryption"
  fi
}

process_file() {
  local l_file=$1
  local old_hash="empty"

  new_hash=$(cat $l_file | sha512sum | cut -d ' ' -f 1)
  if [[ -f "$local_dir/${entry_title}.checksum" ]] ; then
    old_hash=$(cat "$local_dir/${entry_title}.checksum")
  fi

  if [[ $new_hash != $old_hash ]] ; then
    enc_file $l_file
    echo $new_hash > "$local_dir/${entry_title}.checksum"
  else
    echo "  Unchanged file content skipping re-encryption"
  fi
}

enc_directory() {
  local l_dir=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"

    echo "  Create local file: $entry_title with $entry_password"
    tar czf - $l_dir | ${__enc_cmd} ${l_enc_params} -out ${local_dir}/${entry_title}
}

enc_file() {
  local l_file=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"

#  if [[ ! -f ${local_dir}/${entry_title} ]] ; then
    echo "  Create local file: $entry_title with $entry_password"
    ${__enc_cmd} ${l_enc_params} -in $l_file -out ${local_dir}/${entry_title}
#  else
#    echo "  local file already exist: $entry_title"
#  fi
}

cloud_backup() {
  local l_base_dir=$1
  local l_dirs=$(find $l_base_dir -maxdepth 1 -type d)
  local l_files=$(find $l_base_dir  -maxdepth 1 -type f)
  local l_dir=""
  local l_file=""

  for l_dir in $l_dirs; do
    if [[ $l_dir == $l_base_dir ]] ; then
      continue
    fi
    echo "Processing directory: $l_dir"
    create_keepass_entry $l_dir ".tgz.enc"
    process_directory $l_dir
  done

  for l_file in $l_files; do
    echo "Processing file: $l_file"
    create_keepass_entry $l_file ".enc"
    process_file $l_file
  done
}

cloud_sync() {
  local l_cloud=""

  echo "Copy to clouds"
  for l_cloud in ${cloud_paths[*]} ; do
    echo "Copy to cloud: $l_cloud"
    rclone sync ${local_dir} ${l_cloud}
  done
}

check() {
  local l_enc_file=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"
  local l_tar_params='tzv'


    echo "${__dec_cmd} ${l_enc_params} -in $l_enc_file | tar ${l_tar_params}"
    ${__dec_cmd} ${l_enc_params} -in $l_enc_file | tar ${l_tar_params}
}

#keepassxc-cli db-info --key-file ./keepassxc --no-password test.db

main() {
  parse_cmdline "${@}"
  local l_dir=""

  declare -r __keepass_std_arg=" --no-password --key-file $keepass_key $keepass_db"

  for l_restore in ${restore_list[*]}
  do
    find_keepass_entry_from_url $l_restore
    rclone copy "$cloud/$entry_title" $local_dir
    check $local_dir/$entry_title
    rclone copy "$cloud/$entry_title.checksum" $local_dir
  done
  #keepassxc-cli export -f csv $__keepass_std_arg
}

restore_list=()
local_dir="$HOME/rclone_cloud_test"
keepass_key="${HOME}/.ssh/rclone-backup"
keepass_db="${HOME}/.rclone_backup.kdbx"


short=l:,k:,d:,h
long=local-dir:,key:,database:,help
options=$(getopt --name $__program --options $short --longoptions $long -- "$@")
[ $? -eq 0 ] || {me
    echo "Incorrect options provided"
    exit 1
}
eval set -- "$options"
main "${@}"

