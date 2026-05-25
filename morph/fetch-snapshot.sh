#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /jwtsecret/jwt-secret.txt ]]; then
  echo "Generating JWT secret"
  __secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  __secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${__secret1}""${__secret2}" > /jwtsecret/jwt-secret.txt
fi

if [[ -O "/jwtsecret/jwt-secret.txt" ]]; then
  chmod 666 /jwtsecret/jwt-secret.txt
fi

__get_snapshot() {
  __dont_rm=0
  mkdir -p /db/snapshot
  cd /db/snapshot
  eval "__url=$1"
#shellcheck disable=SC2154
  if [[ "${__url}" == "https://storage.cloud.google.com/"* ]]; then
    echo "Google Cloud URL detected, using gsutil"
    __path="gs://${__url#https://storage.cloud.google.com/}"
    gsutil -m cp "${__path}" .
  else
    aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true "${__url}"
  fi
  echo "Copy completed, extracting"
  if ! __final_url=$(curl -s -I -L -o /dev/null -w '%{url_effective}' "$__url"); then
    printf "Error: Failed to retrieve final URL for %s\n" "$__url" >&2
    return 1
  fi
  __filename=$(basename "$__final_url")
  __filename="${__filename%%\?*}"
  if [[ "${__filename}" =~ \.tar\.zst$ ]]; then
    pzstd -c -d "${__filename}" | tar xvf - -C /db
  elif [[ "${__filename}" =~ \.tar\.gz$ || "${__filename}" =~ \.tgz$ ]]; then
    tar xzvf "${__filename}" -C /db
  elif [[ "${__filename}" =~ \.tar$ ]]; then
    tar xvf "${__filename}" -C /db
  elif [[ "${__filename}" =~ \.lz4$ ]]; then
    lz4 -c -d "${__filename}" | tar xvf - -C /db
  else
    __dont_rm=1
    echo "The snapshot file has a format that Morph Docker can't handle."
    echo "Please come to CryptoManufaktur Discord to work through this."
  fi
  if [ "${__dont_rm}" -eq 0 ]; then
    rm -f "${__filename}"
  fi
  # try to find the directory
  __search_dir="chaindata"
  __base_dir="/db/"
  __found_path=$(find "$__base_dir" -type d -path "*/$__search_dir" -print -quit)
  if [ "${__found_path}" = "${__base_dir}chaindata" ]; then
    echo "Found chaindata in root directory, moving it to geth folder"
    mkdir -p "$__base_dir/geth"
    mv "$__found_path" "$__base_dir/geth"
  elif [ -n "$__found_path" ]; then
    __geth_dir=$(dirname "$__found_path")
    __geth_dir=${__geth_dir%/chaindata}
    if [ "${__geth_dir}" = "${__base_dir}geth" ]; then
       echo "Snapshot extracted into ${__geth_dir}/chaindata"
    else
      echo "Found a geth directory at ${__geth_dir}, moving it."
      mv "$__geth_dir" "$__base_dir"
      rm -rf "$__geth_dir"
    fi
  fi
  if [[ ! -d /db/geth/chaindata ]]; then
    echo "Chaindata isn't in the expected location."
    echo "This snapshot likely won't work until the entrypoint script has been adjusted for it."
    exit 1
  fi
}

# Prep datadir
if [ -n "${SNAPSHOT}" ] && [ ! -d "/db/geth/" ]; then
  __get_snapshot "${SNAPSHOT}"
else
  echo "No snapshot fetch necessary"
fi
