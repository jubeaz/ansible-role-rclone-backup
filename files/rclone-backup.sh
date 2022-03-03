#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

declare -r __program=$(basename $0)
declare -r __keepass_group=$(date +%Y-%m-%d)
declare -r __password_policy="--lower --upper --numeric --length 24"
declare -r __datetime=$(date +'%F %H:%M:%S')
declare -r __logfile="/var/log/rclone-backup.log"

declare -r __enc_cmd="openssl enc -e"

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
        cloud_paths+=("$1")
        shift ;
        ;;
      --)
        shift;
        break
        ;;
    esac
  done

  backup_dirs=${@}
}

create_keepass_db() {
  #ssh-keygen -o -f $keepass_key -N ''
  # create empty password db
  if [[ ! -f $keepass_db ]] ; then
    echo "$__datetime  keepass create new database $keepass_db" >> $__logfile
    keepassxc-cli db-create --set-key-file $keepass_key $keepass_db
  fi
}

create_keepass_group() {
  local groups=$(keepassxc-cli ls $__keepass_std_arg)

  for group in $groups ; do
    if [[ $group == "$__keepass_group/" ]] ; then
      return
    fi
  done
  keepassxc-cli mkdir $__keepass_std_arg /$__keepass_group
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

  echo "$__datetime  keepass search entry for $url" >> $__logfile
  local result=$(keepassxc-cli export -f csv $__keepass_std_arg | grep -v Recycle | grep $url | awk -F',' '{print $1 $2}' | sed 's/""/\//' | sed 's/"//g' | sed 's/Passwords\///')
  if [[ ! -z $result ]] ; then
    # get existing entry info
    echo "$__datetime  keepass entry found for $url: $result" >> $__logfile
    entry_path=$result
    fetch_keepass_entry
  fi
}

create_keepass_entry() {
  local url=$1
  local suffix=$2

  find_keepass_entry_from_url $url

  if [[ -z $entry_path ]] ; then
    echo "$__datetime  keepass entry not found for $url creating one" >> $__logfile
    entry_title="$(keepassxc-cli generate --length 16 --lower --upper)$suffix"
    entry_path=/$__keepass_group/$entry_title
    result=$(keepassxc-cli add --username "$__program" --url "$url" --generate $__password_policy $__keepass_std_arg $entry_path)
    fetch_keepass_entry
    echo "$__datetime  keepass entry Created for $url: /$__keepass_group/$entry_title" >> $__logfile
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
    echo "$__datetime  Unchanged content skipping re-encryption" >> $__logfile
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
    echo "$__datetime  Unchanged file content skipping re-encryption" >> $__logfile
  fi
}

enc_directory() {
  local l_dir=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"

  echo "$__datetime  Create local file: $entry_title with entry_password" >> $__logfile
  tar czf - $l_dir | ${__enc_cmd} ${l_enc_params} -out ${local_dir}/${entry_title}
}

enc_file() {
  local l_file=$1
  local l_enc_params="-base64 -k $entry_password -pbkdf2 -aes-256-cbc -salt"

  echo "$__datetime  Create local file: $entry_title with entry_password" >> $__logfile
  ${__enc_cmd} ${l_enc_params} -in $l_file -out ${local_dir}/${entry_title}
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
    echo "$__datetime Processing directory: $l_dir" >> $__logfile
    create_keepass_entry $l_dir ".tgz.enc"
    process_directory $l_dir
  done

  for l_file in $l_files; do
    echo "$__datetime Processing file: $l_file" >> $__logfile
    create_keepass_entry $l_file ".enc"
    process_file $l_file
  done
}

cloud_sync() {
  local l_cloud=""

  echo "$__datetime Copy to clouds" >> $__logfile
  for l_cloud in ${cloud_paths[*]} ; do
    echo "$__datetime Copy to cloud: $l_cloud" >> $__logfile
    rclone sync ${local_dir} ${l_cloud}
  done
}

check() {
    tar_params='tzv'

    echo "rclone copy ${cloud_dir}/$enc_file ${local_dir}"

    echo "${__dec_cmd} ${enc_dec_params} -in $enc_file | tar ${tar_params}"
}

clean_up() {
  local content=()
  local i=0

  echo "$__datetime Begin clean up" >> $__logfile
  co=$(keepassxc-cli export -f csv  $__keepass_std_arg | grep rclone | grep -v Recycle | awk -F',' '{ print $5 $1 $2 }' | sed 's/Passwords\///' | sed 's/""/ /g' | sed 's/"//g' | paste -sd ' ')

  #echo $co
  content=($(echo $co | tr ' ' ' '))
  while [[ "$i" -lt "${#content[@]}" ]]; do
    l_path=${content[i]}
    l_group=${content[i+1]}
    l_title=${content[i+2]}
    i=$((i+3))
    if [[ -f $l_path ]] || [[ -d $l_path ]] ; then
      continue
    fi
    echo "$__datetime   Missing $l_path: purging $local_dir/$l_title and deleting $local_dir/$l_title and checksum" >> $__logfile
    keepassxc-cli rm  $__keepass_std_arg $l_group/$l_title
    #keepassxc-cli rm  $__keepass_std_arg $l_title
    rm -f $local_dir/$l_title
    rm -f $local_dir/$l_title.checksum
  done
  echo "$__datetime End clean up" >> $__logfile
}


main() {
  parse_cmdline "${@}"
  local l_dir=""

  declare -r __keepass_std_arg=" --no-password --key-file $keepass_key $keepass_db"

  create_keepass_db
  create_keepass_group
  for l_dir in ${backup_dirs[*]}
  do
    cloud_backup $l_dir
  done

  clean_up
  cp $keepass_db ${local_dir}
  cloud_sync
}

backup_dirs=()
cloud_paths=()
local_dir="/tmp"
keepass_key="${HOME}/.ssh/rclone-backup"
keepass_db="${HOME}/.rclone_backup.kdbx"


short=l:,k:,d:,c:,h
long=local-dir:,key:,database:,cloud-path:,help
options=$(getopt --name $__program --options $short --longoptions $long -- "$@")
[ $? -eq 0 ] || {
    echo "Incorrect options provided"
    exit 1
}
eval set -- "$options"
main "${@}"

