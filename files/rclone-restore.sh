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
                                        default /tmp
     -k, --key          key-path        full path of keepassxc db key
                                        default ~/.ssh/rclone-backup
     -d, --database     database-path   full path of keepassxc db
                                        default ~/.rclone-backup.kdbx
     -c, --cloud-path   cloud-path      <drive_name>:<path>

HEREDOC
}

parse_cmdline() {
  while [[ $# -gt 0 ]] ; do
    case "$1" in
      -h | --help) usage ; exit ; ;;
      -l | --local-dir)
        shift ;
        local_dir=$1;
        shift ;
        ;;
      -k | --key)
        shift ;
        keepass_key=$1;
        shift ;
        ;;
      -d | --database)
        shift ;
        keepass_db=$1
        shift ;
        ;;
      -c | --cloud-path)
        shift ;
        cloud_path="$1"
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

check() {
  local l_enc_file=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"
  local l_tar_params='tzv'

  echo "${__dec_cmd} ${l_enc_params} -in $l_enc_file | tar ${l_tar_params}"
  ${__dec_cmd} ${l_enc_params} -in $l_enc_file | tar ${l_tar_params}
}


main() {
  parse_cmdline "${@}"
  
  declare -r __keepass_std_arg=" --no-password --key-file $keepass_key $keepass_db"

  for l_restore in ${restore_list[*]}
  do
    find_keepass_entry_from_url $l_restore
    rclone copy "$cloud_path/$entry_title" $local_dir
    check $local_dir/$entry_title
    rclone copy "$cloud_path/$entry_title.checksum" $local_dir
  done
}

restore_list=()
local_dir="/tmp"
keepass_key="${HOME}/.ssh/rclone-backup"
keepass_db="${HOME}/.rclone_backup.kdbx"
cloud_path=""

short=l:,k:,d:,c:,h
long=local-dir:,key:,database:,cloud-path:,help
options=$(getopt --name $__program --options $short --longoptions $long -- "$@")
[ $? -eq 0 ] || {
    echo "Incorrect options provided"
    exit 1
}
eval set -- "$options"
main "${@}"

