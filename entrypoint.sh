#!/usr/bin/env bash
/etc/cont-init.d/10-adduser

Yellow='\033[0;33m'       # Yellow
Cyan='\033[0;36m'         # Cyan
command="su bitwarden -c /app/bw_export.sh "
if [[ -n "${FILE_LOG}" ]]; then
    echo -e "\n${Cyan}Output log enabled: $FILE_LOG "
    command="$command 2>&1 | tee $FILE_LOG"
fi

if [[ -n "${INFISICAL_TOKEN}" ]]; then

    if [[ -n "${INFISICAL_PATH}" ]]; then
        infisicalpath="--path=${INFISICAL_PATH}"
    fi

    echo -e "\n${Yellow}Infisical enabled! "
    command="infisical run $infisicalpath --command='$command'"
fi

eval $command