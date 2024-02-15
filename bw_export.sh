#!/usr/bin/env bash
#  _                                             _   
# | |____      __      _____  ___ __   ___  _ __| |_ 
# | '_ \ \ /\ / /____ / _ \ \/ / '_ \ / _ \| '__| __|
# | |_) \ V  V /_____|  __/>  <| |_) | (_) | |  | |_ 
# |_.__/ \_/\_/       \___/_/\_\ .__/ \___/|_|   \__|
#                              |_|                   
# Bitwarden CLI Vault Export Script
# Author: 0netx based on David H (@dh024)
#  
# This script will backup the following:
#   - personal vault contents, password encrypted (or unencrypted)
#   - organizational vault contents (passwd encrypted or unencrypted)
#   - file attachments
# It will also report on whether there were items in the Trash that
# could not be exported.


# Constant and global variables

export BITWARDENCLI_APPDATA_DIR="$(pwd)"

params_validated=0
Yellow='\033[0;33m'       # Yellow
IYellow='\033[0;93m'      # Yellow
IGreen='\033[0;92m'       # Green
Cyan='\033[0;36m'         # Cyan
UCyan='\033[4;36m'        # Cyan
UWhite='\033[4;37m'       # White
Blue='\033[0;34m'     # Blue

echo Starting ...
#Set locations to save export files
if [[ -z "${OUTPUT_PATH}" ]]; then
    echo -e "\n$(date '+%F %T') ${Cyan}Info: OUTPUT_PATH enviroment not provided. Using default value: /var/data"
    save_folder="/var/data/"
else
	save_folder="${OUTPUT_PATH}"
    if [[ ! -d "$save_folder" ]]
    then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the files: $save_folder "
        echo
        params_validated=-1
    fi
fi


#Set locations to save attachment files
if [[ -z "${ATTACHMENTS_PATH}" ]]; then
    save_folder_attachments="/var/attachments/"    
    echo -e "\n$(date '+%F %T') ${Cyan}Info: ATTACHMENTS_PATH enviroment not provided. Using default value: /var/attachments"
else
	save_folder_attachments="${ATTACHMENTS_PATH}"
    if [[ ! -d "$save_folder_attachments" ]]
    then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the attachments files: $save_folder_attachments "
        echo
        params_validated=-1
    fi
fi



#Set Vaultwarden own server.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
if [[ -z "${BW_URL_SERVER}" ]]; then
    echo -e -n $Cyan # set text = yellow
    echo -e "\nInfo: BW_SERVER enviroment not provided."

    echo -n "$(date '+%F %T') If you have your own Bitwarden or Vaulwarden server, set in the environment variable BW_URL_SERVER its url address. "
    echo -n "$(date '+%F %T') Example: https://skynet-vw.server.com"
    echo
else
	bw_url_server="${BW_URL_SERVER}"
fi


#Set Bitwarden session authentication.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
if [[ -z "${BW_CLIENTID}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_CLIENTID enviroment variable not provided, exiting..."

    echo -n "$(date '+%F %T') Your Bitwarden Personal API Key can be obtain in:"
    echo -n "$(date '+%F %T') https://bitwarden.com/help/personal-api-key/"
    params_validated=-1
else
    if test -f "${BW_CLIENTID}"; then
        client_id=$(<${BW_CLIENTID})
    else
	    client_id="${BW_CLIENTID}"
    fi

fi


if [[ -z "${BW_CLIENTSECRET}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_CLIENTSECRET enviroment variable not provided, exiting..."

    echo -n "$(date '+%F %T') Your Bitwarden Personal API Key can be obtain in:"
    echo -n "$(date '+%F %T') https://bitwarden.com/help/personal-api-key/"
	params_validated=-1
else
    if test -f "${BW_CLIENTSECRET}"; then
        client_secret=$(<${BW_CLIENTSECRET})
    else
	    client_secret="${BW_CLIENTSECRET}"
    fi
    
fi


if [[ -z "${BW_PASSWORD}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_PASSWORD enviroment variable not provided, exiting..."

	params_validated=-1
else

     if test -f "${BW_PASSWORD}"; then
        bw_password=$(<${BW_PASSWORD})
    else
	    bw_password="${BW_PASSWORD}"
    fi
fi


#Set Organization ID (if applicable)
if [[ -z "${BW_ORGANIZATIONS_LIST}" ]]; then
    echo -e "\n$(date '+%F %T') ${Cyan} BW_ORGANIZATIONS_LIST enviroment not provided. All detected organizations will be exported. "
    echo -e "${Cyan} If you want to make a backup of specific organizations, set one or more organizations separated by comma"
    echo -e "${Cyan} To obtain your organization_id value, open a terminal and type:"
    echo -e "${Cyan}       bw login #(follow the prompts); bw list organizations | jq -r '.[0] | .id'"
    echo -e "${Cyan}       Example: cada13d7-5418-37ed-981b-be822121c593,cada13d7-5418-37ed-981b-be82219879878979,cada13d7-5418-37ed-981b-be822121c5435"
else
	organization_list="${BW_ORGANIZATIONS_LIST}"
fi



#Check export password 
if [[ -z "${EXPORT_PASSWORD}" ]]; then

    echo
    echo -e "\n$(date '+%F %T') ${IYellow}-------------------------------------------------------------------------------------------------------------"
    echo -e "\n$(date '+%F %T') ${IYellow}Warning: EXPORT_PASSWORD enviroment not provided. Exports require a password to securize your exported vault."
    echo -e "\n$(date '+%F %T') ${IYellow}-------------------------------------------------------------------------------------------------------------"
    echo
    password1=""

else
    echo -e "\n$(date '+%F %T') ${Cyan}Info:  Be sure to save your EXPORT_PASSWORD in a safe place!"
    if test -f "${EXPORT_PASSWORD}"; then
        password1=$(<${EXPORT_PASSWORD})
    else
	    password1="${EXPORT_PASSWORD}"
    fi
fi

# Check if required parameters has beed proviced.
if [[ $params_validated != 0 ]]
then
    echo -e "\n$(date '+%F %T') ${IYellow}One or more required environment variables have not been set."
    echo -e "${IYellow}Please check the required environment variables:"
    echo -e "${IYellow}BW_CLIENTID,BW_CLIENTSECRET,BW_PASSWORD"
    exit -1
fi

echo "$(date '+%F %T') $(date '+%F %T') Starting exporting..."
echo 

if [[ $bw_url_server != "" ]]
then 
    echo "$(date '+%F %T') Setting custom server..."
    bw config server $bw_url_server --quiet --nointeraction
    echo
fi

BW_CLIENTID=$client_id
BW_CLIENTSECRET=$client_secret

#Login user if not already authenticated
if [[ $(bw status | jq -r .status) == "unauthenticated" ]]
then 
    echo "$(date '+%F %T') Performing login..."
    bw login --apikey --method 0   --quiet --nointeraction
fi
if [[ $(bw status | jq -r .status) == "unauthenticated" ]]
then 
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Failed to authenticate."
    echo
    exit 1
fi

#Unlock the vault
session_key=$(bw unlock $bw_password --raw)

#Verify that unlock succeeded
if [[ $session_key == "" ]]
then 
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Failed to authenticate."
    exit 1
else
    echo "$(date '+%F %T') Login successful."
fi
#Export the session key as an env variable (needed by BW CLI)
export BW_SESSION="$session_key" 
echo

#Check if the user has decided to enter a password or save unencrypted
if [[ $password1 == "" ]]
then 
    echo -e "\n$(date '+%F %T') ${IYellow}WARNING! Your vault contents will be saved to an unencrypted file."   
    echo "$(date '+%F %T') WARNING! Your vault contents will be saved to an unencrypted file."     
else
    echo -e "\n$(date '+%F %T') ${Cyan}Info: Password for encrypted export has been provided."   
fi

echo "$(date '+%F %T') Performing vault exports..."

# 1. Export the personal vault 
if [[ ! -d "$save_folder" ]]
then
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the files. Path: $save_folder"
    echo
    exit 1
fi

working_folder=$(date '+%Y%m%d%H%M%S')-bw-export

runtime_save_folder=$save_folder/$working_folder/
runtime_save_folder_attachments=$save_folder_attachments/$working_folder/

if [[ ! -d "$runtime_save_folder" ]]
then
    mkdir $runtime_save_folder
fi

if [[ ! -d "$runtime_save_folder_attachments" ]]
then
    mkdir $runtime_save_folder_attachments
fi




if [[ $password1 == "" ]]
then
    echo
    echo "$(date '+%F %T') Exporting personal vault to an unencrypted file..."
    bw export --format json --output $runtime_save_folder
else
    echo 
    echo "$(date '+%F %T') Exporting personal vault to a password-encrypted file..."
    bw export --format encrypted_json --password $password1 --output $runtime_save_folder
fi

if [[ $organization_list == "" ]]
then
    list=$(bw list organizations | jq -r '.[] | .id' | tr '\n' ', ')
    if [[ ! -z "$list" ]]
    then 
        organization_list=${list::-1}
        if [[ ! -z "$organization_list" ]]
        then 
                echo -e "\n$(date '+%F %T') ${Cyan}Info: No  BW_ORGANIZATIONS_LIST provided. Exporting all organizations detected in vault"
        fi
    fi
fi

# 2. Export the organization vault (if specified) 
if [[ ! -z "$organization_list" ]]
then 
    IFS=', ' read -r -a array <<< "$organization_list" 
    for org_id in "${array[@]}"
    do
        if [[ $password1 == "" ]]
        then
            echo
            echo "$(date '+%F %T') Exporting organization vault to an unencrypted file..."
            bw export --organizationid $org_id --format json --output $runtime_save_folder
        else
            echo 
            echo "$(date '+%F %T') Exporting organization vault to a password-encrypted file..."
            bw export --organizationid $org_id --format encrypted_json --password $password1 --output $runtime_save_folder
        fi
    done
else
    echo
    echo "$(date '+%F %T') No organizational vault exists, so nothing to export."
fi


# 3. Download all attachments (file backup)
#First download attachments in vault
if [[ $(bw list items | jq -r '.[] | select(.attachments != null)') != "" ]]
then
    echo
    echo "$(date '+%F %T') Saving attachments..."
    bash <(bw list items | jq -r '.[]  | select(.attachments != null) | "bw get attachment \"\(.attachments[].fileName)\" --itemid \(.id) --output \"'$runtime_save_folder_attachments'\(.name)/\""' )
else
    echo
    echo "$(date '+%F %T') No attachments exist, so nothing to export."
fi 

echo
echo "$(date '+%F %T') Vault export complete."

# 4. Report items in the Trash (cannot be exported)
trash_count=$(bw list items --trash | jq -r '. | length')

if [[ $trash_count > 0 ]]
then

    echo -e "\n$(date '+%F %T') ${Cyan}Info: You have $trash_count items in the trash that cannot be exported."

fi

echo
bw lock 
bw logout
BW_CLIENTID=
BW_CLIENTSECRET=
BW_SESSION=


if [ -n "${KEEP_LAST_BACKUPS}" ]; then
    echo "$(date '+%F %T') $(date '+%F %T') Starting cleaning previous backups..."
    echo 
    re='^[0-9]+$'
    if ! [[ ${KEEP_LAST_BACKUPS} =~ $re ]] ; then
       echo -e "\n$(date '+%F %T') ${IYellow}ERROR: KEEP_LAST_BACKUPS:${KEEP_LAST_BACKUPS} is not a number" >&2; exit 1
    fi
    keep_backups="${KEEP_LAST_BACKUPS}"
    # Deleting vault exportings directories
    actual_num_backups=$(find $save_folder -path "*-bw-export" -type d | sort | wc -l)
    echo -e "\n$(date '+%F %T') ${Cyan}Info: Nº backups: $actual_num_backups"
    echo -e "$(date '+%F %T') ${Cyan}Info: Max Nº backups: $keep_backups"    
    if [[ $actual_num_backups -gt $keep_backups ]]; then
        for F in $(find $save_folder -path "*-bw-export" -type d | sort | head -$(expr $actual_num_backups - $keep_backups)); do 
            echo -e "\n$(date '+%F %T') ${Blue} Deleting exported vault:$F"
            rm -rf $F
        done
    fi
    # Deleteting attachment exporting directories
    actual_num_backups=$(find $save_folder_attachments -path "*-bw-export" -type d | sort | wc -l)
    if [[ $actual_num_backups -gt $keep_backups ]]; then
        echo -e "\n$(date '+%F %T') ${Cyan}Info: Nº backups: $actual_num_backups"
        echo -e "$(date '+%F %T') ${Cyan}Info: Max Nº backups: $keep_backups"
        for F in $(find $save_folder_attachments -path "*-bw-export" -type d | sort | head -$(expr $actual_num_backups - $keep_backups)); do 
            echo -e "\n$(date '+%F %T') ${Blue} Deleting exported attachment:$F"
            rm -rf $F
        done
    fi
    echo "$(date '+%F %T') $(date '+%F %T') Finish clean previous backups..."    
fi



echo -e "\n$(date '+%F %T') ${IGreen} Info: Exporting finished. Have a good day"
echo
