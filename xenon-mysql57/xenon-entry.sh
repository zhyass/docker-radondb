#!/bin/bash

help()
{
	echo $1

	cat << EE
usage:
	xenon-entry is command tool for xenon
	xenon-entry [start] options
EE
}

# usage: file_env VAR [DEFAULT]
#	ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# usage: process_init_file FILENAME MYSQLCOMMAND...
#	ie: process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
	local f="$1"; shift
	local mysql=( "$@" )

	case "$f" in
		*.sh)	 echo "$0: running $f"; . "$f" ;;
		*.sql)	echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
		*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
		*)		echo "$0: ignoring $f" ;;
	esac
	echo
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
	local conf="$1";
	"mysqld" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
		| awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
	# match "datadir	  /some/path with/spaces in/it here" but not "--xyz=abc\n	 datadir (xyz)"
}

#get server_id from ip address
ipaddr=$(hostname -I | awk ' { print $1 } ')
server_id=$(echo $ipaddr | tr . '\n' | awk '{s = s*256 + $1} END{printf("%d", s)}')

init_server(){
	grep -l "server_id" /etc/mysql/my.cnf
	if [ $? -ne 0 ];then
		echo "server_id=$server_id" >> /etc/mysql/my.cnf
	fi

	if [ -n "$INIT_TOKUDB" ]; then
		export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1
	fi
	# Get config
	DATADIR="$(_get_config 'datadir')"

	if [ ! -d "$DATADIR/mysql" ]; then
		mkdir -p "$DATADIR"

		echo 'Initializing database'
		mysqld --initialize-insecure --skip-ssl
		echo 'Database initialized'

		if command -v mysql_ssl_rsa_setup > /dev/null && [ ! -e "$DATADIR/server-key.pem" ]; then
			# https://github.com/mysql/mysql-server/blob/23032807537d8dd8ee4ec1c4d40f0633cd4e12f9/packaging/deb-in/extra/mysql-systemd-start#L81-L84
			echo 'Initializing certificates'
			mysql_ssl_rsa_setup --datadir="$DATADIR"
			echo 'Certificates initialized'
		fi

		SOCKET="$(_get_config 'socket')"
		"mysqld" --skip-networking --socket="${SOCKET}" &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" --password="" )

		for i in {120..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
			# sed is for https://bugs.mysql.com/bug.php?id=20545
			mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		fi

		# install TokuDB engine
		if [ -n "$INIT_TOKUDB" ]; then
			ps-admin --docker --enable-tokudb -u root
		fi

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			-- or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'root') OR host NOT IN ('localhost') ;
			CREATE USER 'root'@'127.0.0.1' IDENTIFIED BY '' ;
			GRANT ALL ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		file_env 'MYSQL_REPL_PASSWORD' 'Repl_123'
		echo "GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* to 'qc_repl'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD' ;" | "${mysql[@]}"
		echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"

		echo
		ls /docker-entrypoint-initdb.d/ > /dev/null
		for f in /docker-entrypoint-initdb.d/*; do
			process_init_file "$f" "${mysql[@]}"
		done

		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done.'
		echo
	fi


	printf '{
 "log": {
  "level": "INFO"
 },
 "server": {
  "endpoint": "%s:8801"
 },
 "replication": {
  "passwd": "%s",
  "user": "qc_repl"
 },
 "rpc": {
  "request-timeout": 2000
 },
 "mysql": {
  "admit-defeat-ping-count": 3,
  "admin": "root",
  "basedir": "/usr",
  "defaults-file": "/etc/mysql/my.cnf",
  "ping-timeout": 2000,
  "passwd": "",
  "host": "localhost",
  "version": "mysql57",
  "master-sysvars": "tokudb_fsync_log_period=default;sync_binlog=default;innodb_flush_log_at_trx_commit=default",
  "slave-sysvars": "tokudb_fsync_log_period=1000;sync_binlog=1000;innodb_flush_log_at_trx_commit=1",
  "port": 3306
 },
 "raft": {
  "election-timeout": 10000,
  "admit-defeat-hearbeat-count": 5,
  "heartbeat-timeout": 2000,
  "meta-datadir": "/var/lib/xenon/",
  "semi-sync-degrade": true,
  "purge-binlog-disabled": true,
  "super-idle": false
 },
 "backup": {
  "ssh-host": "%s",
  "ssh-user": "mysql",
  "ssh-passwd": "mysql",
  "mysqld-monitor-interval": 5000,
  "backup-use-memory": "2048M",
  "ssh-port": 22,
  "xtrabackup-bindir": "/usr/bin",
  "backup-parallel": 2,
  "backupdir": "/var/lib/mysql/",
  "backup-iops-limits": 100000
 }
}' $ipaddr $MYSQL_REPL_PASSWORD $ipaddr > /etc/xenon/xenon.json
}

start_ssh(){
	# start the ssh server.
	sudo service ssh start
}

start_mysql(){
	mysqld_safe --defaults-file=/etc/mysql/my.cnf --server-id=$server_id &
}

start_xenon(){
	/xenon/xenon -c /etc/xenon/xenon.json >> /var/log/xenon/xenon.log 2>&1 &
}

cmd=$1
shift 1

case $cmd in
	start)
		init_server
		start_mysql
		start_ssh
		start_xenon
		while [ -n "$(pgrep mysqld)" -a -n "$(pgrep sshd)" -a -n "$(pgrep xenon)" ]
		do
			sleep 60
		done
		;;
	*)
		help "unknow command $cmd."
		exit 1
		;;
esac

exit 0
