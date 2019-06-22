#!/bin/bash
# ------------------------------------------------------------------
# [Author]	 ajaypratap
# [File]	 postgresql_migration.sh
# [Description]        
# This script will upgrade  postgresql-9.3 database to postgresql-10 
# [github] https://github.com/appleajay/postgres_upgrade/
#---Variables---------------------------------------------------------------
VERSION=0.3.0
SUBJECT=$0
OLD_POSTGRES_VERSION=9.3
NEW_POSTGRES_VERSION=10
OLD_POSTGRES_DATA_DIR=/var/lib/pgsql/"$OLD_POSTGRES_VERSION"/data
NEW_POSTGRES_DATA_DIR=/var/lib/pgsql/"$NEW_POSTGRES_VERSION"/data
OLD_POSTGRES_BIN_DIR=/usr/pgsql-"$OLD_POSTGRES_VERSION"/bin
NEW_POSTGRES_BIN_DIR=/usr/pgsql-"$NEW_POSTGRES_VERSION"/bin
RESTORE_REGEX_TABLES=false
FAILOVER_SETUP=false
LOG=/tmp/pg_upgrade_`date +%s`.log
#---Util-------------------------------------------------------

LOCK_FILE=/tmp/postgres_migration.lock

if [ -f "$LOCK_FILE" ]; then
	echo "Script is already running. EXITING"
	exit
fi

trap "rm -f $LOCK_FILE" EXIT
touch $LOCK_FILE

log() {
    echo `date` " : [$1] : $2" >>  $LOG 
    if [ $1 == "ERROR" ] || [ $1 == "WARN" ] || [ $1 == "INFO" ] ; then
        echo  "[$1] $2"
    fi
}
#---Body ---------------------------------------------------------
sanity_checks() {
	log "INFO" "Validating setup..."
	log "INFO" "Checking Postgresql-10 Packages"
	#check if postgresql10 is installed or not
	if [ `rpm -qa | grep postgresql"$NEW_POSTGRES_VERSION"-server | wc -l` -eq 0 ]; then 
		log "ERROR" "postgresql"$NEW_POSTGRES_VERSION"-server is not Installed. Please install the following packages before proceding further: postgresql"$NEW_POSTGRES_VERSION"-server postgresql"$NEW_POSTGRES_VERSION"-10 postgresql"$NEW_POSTGRES_VERSION"-libs postgresql"$NEW_POSTGRES_VERSION"-contrib \n"
		exit
	fi
	
	if [ `rpm -qa | grep postgresql"$NEW_POSTGRES_VERSION"-"$NEW_POSTGRES_VERSION" | wc -l` -eq 0 ]; then 
		log "ERROR" "postgresql"$NEW_POSTGRES_VERSION"-$NEW_POSTGRES_VERSION is not Installed. Please install the following packages before proceding further: postgresql"$NEW_POSTGRES_VERSION"-server postgresql"$NEW_POSTGRES_VERSION"-10 postgresql"$NEW_POSTGRES_VERSION"-libs postgresql"$NEW_POSTGRES_VERSION"-contrib \n"
        exit
	fi	

	if ! [ -d "$OLD_POSTGRES_DATA_DIR" ]; then
		log "ERROR" "Data dir($OLD_POSTGRES_DATA_DIR) for postgresql-$OLD_POSTGRES_VERSION Doesn't exits. Cannot proceed. Exiting"
		exit
	fi

	if [ -d "$NEW_POSTGRES_DATA_DIR" ]; then
		log "ERROR" "Data dir for postgresql-$NEW_POSTGRES_VERSION already exits $NEW_POSTGRES_DATA_DIR Cannot upgrade. Exiting"
		log "ERROR" "Try removing data dir for newer Postgresql version first"
		exit
	fi
	log "INFO" "Checking Disk Space."
    data_dir_size=`du -s "$OLD_POSTGRES_DATA_DIR" | cut -f -1`
    free_disk_space=` df /var/lib/pgsql/ | awk '{print $4}' | awk 'NR==2'`
    ten_gb=10485760
    if [ $(($data_dir_size + $ten_gb)) -gt $(($free_disk_space)) ] ; then
        log "ERROR" "Not enough space to Migrate Postgres Data. Clear up  $(( $(($data_dir_size + $ten_gb - $free_disk_space ))/1024)) MB more space."

    fi

	if [ -f "$OLD_POSTGRES_DATA_DIR/global/pg_control.old" ] ; then
		log "WARN" "Seems like you are retrying to migrate postgresql."

		read -p "Are you sure you want to continue(yes/no)? "
		if [[ $REPLY =~ ^[Yy][eE][sS]$ ]] ; then
           	`/bin/mv $OLD_POSTGRES_DATA_DIR/global/pg_control.old $OLD_POSTGRES_DATA_DIR/global/pg_control`
		else
			log "INFO" "Exiting."
			exit
        fi
	fi

	log "INFO" "Validation Done."
}

os_version() {
    if ! [ -f /etc/redhat-release ] ; then
            echo "This is not a redhat based OS. This script only support redhat based OS. Failure. Exiting!!!"
            exit
    fi

    ver=`rpm -E %{rhel}`
    if [ $? -ne 0 ]; then
        if [[ "cat /etc/redhat-release" =~ " 6." ]] ; then
            ver="6"
        elif [[ "cat /etc/redhat-release" =~ " 7." ]] ; then
            ver="7"
        else
        	echo "Not able to detect OS version. Failure. Exiting!!!"
            exit          
        fi
    fi
    echo "$ver"
	
}

execute() {
	log "INFO" "Starting postgresql-$OLD_POSTGRES_VERSION "
	service postgresql-"$OLD_POSTGRES_VERSION"  start >/dev/null
	rc=$?

	if [ "$rc" -ne 0 ]; then
		echo "ERROR" "Unable to start postgresql-"$OLD_POSTGRES_VERSION". Exiting"
		exit	
	fi
	lc_colate=`psql -U postgres -c "select  datcollate from pg_database where datname='postgres'" -At -h 127.0.0.1`
	log "DEBUG" "Locale for postgres is $lc_colate"

	log "INFO" "Stopping postgresql-$OLD_POSTGRES_VERSION "
	service postgresql-"$OLD_POSTGRES_VERSION"  stop >/dev/null
	rc=$?
	
	if [ "$rc" -ne 0 ]; then
        echo "ERROR" "Unable to stop postgresql-"$OLD_POSTGRES_VERSION". Exiting"
        exit
	fi

	log "INFO" "Initializing postgresql-$NEW_POSTGRES_VERSION data Dir."

	version=$(os_version)
	if [ "$version" == "7" ] ; then
		log "INFO" "Redhat based ver 7 OS"
		initdb="$NEW_POSTGRES_BIN_DIR/postgresql-$NEW_POSTGRES_VERSION-setup initdb"
	elif [ "$version" == "6" ] ; then
        log "INFO" "Redhat based ver 6 OS"
        initdb="/etc/init.d/postgresql-$NEW_POSTGRES_VERSION initdb"

	fi

	log "DEBUG" "$initdb"
	export PGSETUP_INITDB_OPTIONS="--locale=$lc_colate"
 	rc=`$initdb 2>&1`
	if [ $? -ne 0 ] ; then
		log "ERROR" "Unable to initializing Postgresql-$NEW_POSTGRES_VERSION Data Directory. $rc . Exiting"
		exit
	fi
	
	log "INFO" "Checking Postgresql compatibility.."
	pg_upgrade_compatibility="$NEW_POSTGRES_BIN_DIR/pg_upgrade -b $OLD_POSTGRES_BIN_DIR -B $NEW_POSTGRES_BIN_DIR -d $OLD_POSTGRES_DATA_DIR -D $NEW_POSTGRES_DATA_DIR  –v -c" 
	log "DEBUG" "$pg_upgrade_compatibility"
	rc=`su - postgres -c "$pg_upgrade_compatibility" 2>&1`
	if [ $? -ne 0 ] ; then
		log "ERROR" "$rc"

		if [[ "$rc" =~ "Your installation contains one of the reg" ]]; then
			
			log "ERROR" "Some table column use regex data type. Need to remove those tables before starting process."
			
			if ! [ -d /var/lib/pgsql/migration/ ]; then
				mkdir /var/lib/pgsql/migration/
			fi
			rm -rf /var/lib/pgsql/migration/*
			database=''
			pg_dump_command=''
			input="/var/lib/pgsql/tables_using_reg.txt"
			while IFS= read -r line
			do
			  if [[ "$line" =~ "Database:"  ]] ; then
			      if [ "$database" != "" ] ; then
			          echo "$pg_dump_command" >> /var/lib/pgsql/migration/pgdump_regex_tables.sh
			      fi
			        database=`echo "$line" | cut -d : -f 2 | tr -d ' '`
				    filename="$database"_regex_tables_`date +%s`.sql
			        pg_dump_command="$OLD_POSTGRES_BIN_DIR/pg_dump -U postgres -h 127.0.0.1 $database > /var/lib/pgsql/$filename"
			        echo "$NEW_POSTGRES_BIN_DIR/psql -U postgres -h 127.0.0.1 $database< /var/lib/pgsql/$filename" >> /var/lib/pgsql/migration/restore_regex_tables.sh

			  else

			        table=${line%.*};
			        table=`echo $table | tr -d ' '`
			        pg_dump_command="$pg_dump_command --table=$table"
			        echo "$OLD_POSTGRES_BIN_DIR/psql -U postgres -h 127.0.0.1 $database  -c 'drop table $table' " >> /var/lib/pgsql/migration/drop_regex_tables.sh
			  fi
       		  done < "$input"
			  echo "$pg_dump_command" >> /var/lib/pgsql/migration/pgdump_regex_tables.sh

		    log "INFO" "Start postgresql-$OLD_POSTGRES_VERSION "
		    service postgresql-"$OLD_POSTGRES_VERSION"  start >/dev/null
		    rc=$?

 		    if [ "$rc" -ne 0 ]; then
            		echo "ERROR" "Unable to Start postgresql-"$OLD_POSTGRES_VERSION". Exiting"
		            exit
		    fi
			log "INFO" "Taking dump of postgresql regex_tables"
			dump_tables=`cat /var/lib/pgsql/migration/pgdump_regex_tables.sh`
			log "DEBUG" "$dump_tables"
			sh /var/lib/pgsql/migration/pgdump_regex_tables.sh			 
			if [ $? -ne 0 ] ; then
				reg_tables=`cat /var/lib/pgsql/tables_using_regex.txt`
				log "ERROR" "unable to dump following tables $reg_tables Please take dump of these tables manually, and drop them before to proceed further."
				exit	
			fi
			log "INFO" "Regex tables backup at /var/lib/pgsql/"
			
			log "INFO" "Droping regex tables "
			rc=`cat /var/lib/pgsql/migration/drop_regex_tables.sh`
			log "INFO" "$rc"
			sh /var/lib/pgsql/migration/drop_regex_tables.sh

			if [ $? -ne 0 ] ; then
                   log "ERROR" "unable to drop troublesome tabes(regex) please do manually to proceed."
                   exit
            fi
			log "INFO" "Tables dropped."
	        log "INFO" "Stoping postgresql-$OLD_POSTGRES_VERSION "
            service postgresql-"$OLD_POSTGRES_VERSION"  stop >/dev/null
            rc=$?

            if [ "$rc" -ne 0 ]; then
                 echo "ERROR" "Unable to Stop postgresql-"$OLD_POSTGRES_VERSION". Exiting"
                 exit
            fi

			RESTORE_REGEX_TABLES=true

		else 
			log "ERROR" "Clusters are not compatible. Please refer logs($LOG) for more info . Exiting"
			exit
		fi
	fi
	log "INFO" "$rc"
	log "INFO" "Updating Postgresql. This may take few minutes depending upon DATA size."
	pg_upgrade="$NEW_POSTGRES_BIN_DIR/pg_upgrade -b $OLD_POSTGRES_BIN_DIR -B $NEW_POSTGRES_BIN_DIR -d $OLD_POSTGRES_DATA_DIR -D $NEW_POSTGRES_DATA_DIR  –v -k"
	log "DEBUG" "$pg_upgrade"
	rc=`su - postgres -c "$pg_upgrade" 2>&1`
	if [ $? -ne 0 ] ; then

		log "ERROR" "$rc"
		log "ERROR" "Postgresql Migration failed. Please refer logs($LOG) for more info . Exiting"
		exit
	fi

	log "INFO" "$rc"
	log "INFO" "Updating pg_hba and postgresql.conf"
	copy_pghba=" /bin/cp $OLD_POSTGRES_DATA_DIR/pg_hba.conf  $NEW_POSTGRES_DATA_DIR/pg_hba.conf "
	log "DEBUG" "$copy_pghba"
	rc=`$copy_pghba`
	if [ $? -ne 0 ] ; then
		log "WARN" "Unable to update pg_hba. Do it manually"
		
	fi

	copy_postgresql_conf=" /bin/cp $OLD_POSTGRES_DATA_DIR/postgresql.conf  $NEW_POSTGRES_DATA_DIR/postgresql.conf "
    log "DEBUG" "$copy_postgresql_conf"
    rc=`$copy_postgresql_conf`
    if [ $? -ne 0 ] ; then
            log "WARN" "Unable to update pg_hba. Do it manually"

    fi
	

	log "INFO" "Starting Postgresql-$NEW_POSTGRES_VERSION"
	start_new_postgres="service postgresql-$NEW_POSTGRES_VERSION start"
	log "DEBUG" "$start_new_postgres"
	rc=`$start_new_postgres`
	if [ $? -ne 0 ] ; then
		if [ "$RESTORE_REGEX_TABLES" =  true ] ; then
			log "ERROR" "UNABLE to start Postgresql-10 service."
			log "ERROR" "Run the script mannually to restore regex tables /var/lib/pgsql/migration/restore_regex_tables.sh  proceding."
			
		fi
		
		log "WARN" "Unable to Start Postgresql-$NEW_POSTGRES_VERSION. Analyse the DB after you start mannually. su - postgres -c /var/lib/pgsql/analyze_new_cluster.sh "
		exit
		
	else
	
		if [ "$RESTORE_REGEX_TABLES" =  true ] ; then
			log "INFO" "Restoring dropped regex tables"		
			restore_regex_tables=`cat /var/lib/pgsql/migration/restore_regex_tables.sh`
			log "INFO" "$restore_regex_tables"
			sh /var/lib/pgsql/migration/restore_regex_tables.sh
			if [ $? -ne 0 ]; then
				log  "ERROR" "UNABLE TO RESTORE TABLES /var/lib/pgsql/migration/restore_regex_tables.sh please do it mannually."
				exit
			fi
		fi
		log "INFO" "Analysing newly migrated DB"
		CPU=`grep -c ^processor /proc/cpuinfo` 
		if [ $(($CPU))  -lt 4 ] ; then
			CPU=2
		else
			CPU=$(($CPU - 2))
		fi 
		analyze_DB="/usr/pgsql-10/bin/vacuumdb --all --analyze-in-stages  -j "$CPU" "
		rc=`su - postgres -c "$analyze_DB" 2>&1`

		log "INFO" "$rc"
	fi



	
}


sanity_checks
execute
log "INFO" "Operation Completed Successfully"
