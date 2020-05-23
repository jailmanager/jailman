#!/usr/local/bin/bash
# This script installs the current release of Mariadb and PhpMyAdmin into a created jail
#####
# 
# Init and Mounts
#
#####

initjail "$1"

# Initialise defaults
# shellcheck disable=SC2154
CERT_EMAIL="jail_${1}_cert_email"
CERT_EMAIL="${!CERT_EMAIL:-placeholder@email.fake}"
# shellcheck disable=SC2154
DB_ROOT_PASSWORD="jail_${1}_db_root_password"
host_name="jail_${1}_host_name"
DL_FLAGS=""
DNS_ENV=""

# Check that necessary variables were set by nextcloud-config
if [ -z "${ip4_addr%/*}" ]; then
  echo 'Configuration error: The mariadb jail does NOT accept DHCP'
  echo 'Please reinstall using a fixed IP adress'
  exit 1
fi

# Make sure DB_PATH is empty -- if not, MariaDB/PostgreSQL will choke
# shellcheck disable=SC2154
if [ "$(ls -A "/mnt/${global_dataset_config}/${1}/db")" ]; then
	echo "Reinstall of mariadb detected... Continuing"
	REINSTALL="true"
fi

# Mount database dataset and set zfs preferences
createmount "${1}" "${global_dataset_config}"/"${1}"/db /var/db/mysql
zfs set recordsize=16K "${global_dataset_config}"/"${1}"/db
zfs set primarycache=metadata "${global_dataset_config}"/"${1}"/db

iocage exec "${1}" chown -R 88:88 /var/db/mysql

# Install includes fstab
iocage exec "${1}" mkdir -p /mnt/includes
iocage fstab -a "${1}" "${includes_dir}" /mnt/includes nullfs rw 0 0

iocage exec "${1}" mkdir -p /usr/local/www/phpmyadmin
iocage exec "${1}" chown -R www:www /usr/local/www/phpmyadmin

#####
# 
# Install mariadb, Caddy and PhpMyAdmin
#
#####

fetch -o /tmp https://getcaddy.com
if ! iocage exec "${1}" bash -s personal "${DL_FLAGS}" < /tmp/getcaddy.com
then
	echo "Failed to download/install Caddy"
	exit 1
fi

iocage exec "${1}" sysrc mysql_enable="YES"

# Copy and edit pre-written config files
echo "Copying Caddyfile for no SSL"
iocage exec "${1}" cp -f /mnt/includes/caddy.rc /usr/local/etc/rc.d/caddy
iocage exec "${1}" cp -f /mnt/includes/Caddyfile /usr/local/www/Caddyfile
# shellcheck disable=SC2154
iocage exec "${1}" sed -i '' "s/yourhostnamehere/${host_name}/" /usr/local/www/Caddyfile
iocage exec "${1}" sed -i '' "s/JAIL-IP/${ip4_addr%/*}/" /usr/local/www/Caddyfile

iocage exec "${1}" sysrc caddy_enable="YES"
iocage exec "${1}" sysrc php_fpm_enable="YES"
iocage exec "${1}" sysrc caddy_cert_email="${CERT_EMAIL}"
iocage exec "${1}" sysrc caddy_env="${DNS_ENV}"

iocage restart "${1}"
sleep 10

if [ "${REINSTALL}" == "true" ]; then
	echo "Reinstall detected, skipping generaion of new config and database"
else
	
	# Secure database, set root password, create Nextcloud DB, user, and password
	iocage exec "${1}" cp -f /mnt/includes/my-system.cnf /var/db/mysql/my.cnf
	iocage exec "${1}" mysql -u root -e "DELETE FROM mysql.user WHERE User='';"
	iocage exec "${1}" mysql -u root -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
	iocage exec "${1}" mysql -u root -e "DROP DATABASE IF EXISTS test;"
	iocage exec "${1}" mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
	iocage exec "${1}" mysqladmin --user=root password "${!DB_ROOT_PASSWORD}"
	iocage exec "${1}" mysqladmin reload
fi
iocage exec "${1}" cp -f /mnt/includes/my.cnf /root/.my.cnf
iocage exec "${1}" sed -i '' "s|mypassword|${!DB_ROOT_PASSWORD}|" /root/.my.cnf

# Save passwords for later reference
iocage exec "${1}" echo "MariaDB root password is ${!DB_ROOT_PASSWORD}" > /root/"${1}"_db_password.txt
	

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${1}" "${includes_dir}" /mnt/includes nullfs rw 0 0

# Done!
echo "Installation complete!"
echo "Using your web browser, go to http://${host_name} to log in"

if [ "${REINSTALL}" == "true" ]; then
	echo "You did a reinstall, please use your old database and account credentials"
else
	echo "Database Information"
	echo "--------------------"
	echo "The MariaDB root password is ${!DB_ROOT_PASSWORD}"
	fi
echo ""
echo "All passwords are saved in /root/${1}_db_password.txt"
