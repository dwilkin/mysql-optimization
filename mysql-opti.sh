#!/bin/bash

## MySQL Pre Optimization Script

### Make sure that the script is being run by root. Exit if not

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   echo "This script will now exit!"
   exit 0
fi

# Define Text Colors
Escape="\033";
BlackF="${Escape}[30m"
RedB="${Escape}[41m"
RedF="${Escape}[31m"
CyanF="${Escape}[36m"
Reset="${Escape}[0m"
BoldOn="${Escape}[1m"
BoldOff="${Escape}[22m"

#Define Constants
epoch=$(date +%s)
# Available disk space in KB
disk_avail=$(df -B 1024 | head -2 | tail -1 | awk '{print $4}')
host_type=''

#See if this is CPanel Or Plesk
function check_panel {
if [ -d '/usr/local/psa' ] && [ ! -d '/usr/local/cpanel' ]
   then
   panel_type='plesk'
   #See If This is MT Or GD
   if [ -d "/usr/local/mt" ]
      then
      host_type='mt'
   else
      host_type='gd'
   fi
elif [ -d '/usr/local/cpanel' ] && [ ! -d '/usr/local/psa' ]
   then
   panel_type='cpanel'
else
   panel_type='none'
fi

if [ "$panel_type" == 'plesk' ]
    then
    sqlConnect="mysql -A -u admin -p`cat /etc/psa/.psa.shadow`"
    db_pass=$(cat /etc/psa/.psa.shadow)
    sql_dump_string="mysqldump -uadmin -p$db_pass --add-drop-table --hex-blob"
    sql_check_string="mysqlcheck -uadmin -p$db_pass"
elif [ "$panel_type" == 'cpanel' ]
   then
   db_pass=$(grep password /root/.my.cnf | awk -F\" '{print $2}')
    sqlConnect="mysql -A -u root -p$db_pass"
    sql_dump_string="mysqldump -uroot -p$db_pass --add-drop-table --hex-blob"
    sql_check_string="mysqlcheck -uroot -p$db_pass"
else
   echo "Could not find control panel. You must enter the admin credentials for MySQL:"
   echo ""
   echo -n "Enter MySQL admin user: "
   read sql_user
   echo -n "Enter MySQL admin pass: "
   read sql_pass
   sqlConnect="mysql -A -u$sql_user -p$sql_pass"
   sql_dump_string="mysqldump -u$sql_user -p$sql_pass --add-drop-table --hex-blob"
   sql_check_string="mysqlcheck -u$sql_user -p$sql_pass"
fi
}

function initial_setup {
check_panel

mysqlBin=$(which mysql)
mysqlSyntax=$($mysqlbin --help --verbose 2>&1 >/dev/null | grep -i 'error')
reportFile="/root/CloudTech/logs/mysql_pre_tuning-$(date +%Y-%m-%d)"

#Make sure we have the ol CloudTech dir, and make a log file!!
if [ ! -d "/root/CloudTech/logs" ]
   then
   mkdir -p /root/CloudTech/logs
fi
   touch $reportFile

#Backup config file
echo -e "${CyanF}${BoldOn}Backing Up MySQL Config File${Reset}" | tee -a $reportFile
echo "" | tee -a $reportFile
cp -vp /etc/my.cnf{,-$epoch.ct} | tee -a $reportFile
echo "" | tee -a $reportFile


 }

##FUNCTIONS
#Make It A Ninja Script
function finish {
    rm -f ./ct-pre-mysql.sh
}
trap finish EXIT

#Run they typical pre-tune:
#1. Check Mysql Syntax
#2. Check disk space for database backups
#3. Backup databases
#4. Backup my.cnf file
#5. Optimize databases and check saved space
#6. Enable slow query logging
function pre_tune {
check_panel
#Check MySQL Syntax
if [ -n "$mysqlSyntax" ]
    then
        echo -e "${redF}${BoldOn}The MySQL configuration has the following errors:${Reset}"
        echo ""
        echo $mysqlSyntax
        echo ""
        echo -n "Do You Want To Proceed? (y or n): "
        read choice2
        echo ""
        if [ "$choice2" == "n" ] || [ "$choice2" == "N" ]
            then
                   exit
        fi
fi

#Get Pre-Optimization Size Of All DB's in KB
preSize=$($sqlConnect -Nse 'select Round(((Sum(DATA_LENGTH) + SUM(INDEX_LENGTH)) / 1024),0) from information_schema.tables;')
avail_diff=$(($disk_avail - $preSize))
# Get percentage of available disk space that databases would consume
# Being as accurate as possible without requiring bc
backup_percent=$( printf "%.0f" $(perl -le "print (($preSize/$disk_avail) * 100)"))
# Exit if the backups would leave less than 2 GB
if [ $backup_percent -gt 75 ]
    then
        echo "The databases are too large ($(($preSize / 1024)) MB) to safely export. Please resolve this issue before proceeding.... Exiting!"
        exit
fi

#Backup Databases

#See If Otto Directory Exists. If so, export the DB's in there
if [ ! -d "/root/CloudTech/db-backups" ]; then
    mkdir -p /root/CloudTech/db-backups
fi
echo -e "${CyanF}${BoldOn}Backing Up All Databases To /root/CloudTech/db-backups${Reset}" | tee -a $reportFile
echo "" | tee -a $reportFile
for i in $($sqlConnect -Nse 'show databases' | grep -v '^information_schema$'); do $sql_dump_string "$i" | gzip > /root/CloudTech/db-backups/$i-$epoch.sql.gz; echo "$i"; done | tee -a $reportFile

#Optimize Databases
echo -e "${CyanF}${BoldOn}Repairing And Optimizing Databases${Reset}" | tee -a $reportFile
echo "" | tee -a $reportFile
$sql_check_string --auto-repair --optimize --all-databases | tee -a $reportFile

#Get Post_Optimization Size Of All DB's
postSize=$($sqlConnect -Nse 'select Round(((Sum(DATA_LENGTH) + SUM(INDEX_LENGTH)) / 1024),0) from information_schema.tables;')
sizeDiff=$(($preSize - $postSize))



#Enable slow query logging
slowLogFile=$(cat /etc/my.cnf | grep 'log_slow_queries' | awk 'BEGIN { FS = "=" } ; { print $2 }' )
if [ "$slowLogFile" == "" ]
   then
       slow_log_enabled='true'
       echo ""
       echo -e "${CyanF}${BoldOn}Enabling Slow Query Logging${Reset}"
       echo ""
       touch /var/log/mysqld.slow.log
       chown mysql:mysql /var/log/mysqld.slow.log
       #Add Entry To my.cnf file
       sed -i '/\[mysqld\]/ a\#Added by CloudTech\nlog_slow_queries = /var/log/mysqld.slow.log\nlong_query_time = 2' /etc/my.cnf
echo -e "${CyanF}${BoldOn}Restarting MySQL${Reset}"
echo ""
        if [ -n "$mysqlSyntax" ]
            then
                echo -e "${RedF}${BoldOn}MySQL is not being restarted because of the following errors:${Reset}"
                echo ""
                echo $mysqlSyntax
        else
            if [ "$panel_type" == 'cpanel' ]
                then
                    service mysql restart
            else
                service mysqld restart
            fi
        fi
else
    slow_log_enabled='false'
    echo ""
    echo "MySQL Slow Query Logging Is Already Enabled"
    echo ""
fi
}

#Apply making it better suggestions https://mediatemple.net/community/products/dv/204404044/making-it-better:-basic-mysql-performance-tuning-#dv
function make_it_better {
  echo "Applying template..."
  ramCount=`awk 'match($0,/vmguar/) {print $4}' /proc/user_beancounters`
  ramBase=-16 && for ((;ramCount>1;ramBase++)); do ramCount=$((ramCount/2)); done

  cat <<EOF > /etc/my.cnf
[mysqld]
#Slow Log Query settings
log_slow_queries = /var/log/mysqld.slow.log
long_query_time = 2

# Basic settings
user = mysql
datadir = /var/lib/mysql
socket = /var/lib/mysql/mysql.sock
 
# Security settings
local-infile = 0
symbolic-links = 0
 
# Memory and cache settings
query_cache_type = 1
query_cache_size = $((2**($ramBase+2)))M
thread_cache_size = $((2**($ramBase+2)))
table_cache = $((2**($ramBase+7)))
tmp_table_size = $((2**($ramBase+3)))M
max_heap_table_size = $((2**($ramBase+3)))M
join_buffer_size = ${ramBase}M
key_buffer_size = $((2**($ramBase+4)))M
max_connections = $((100 + (($ramBase-1) * 50)))
wait_timeout = 300
 
# Innodb settings
innodb_buffer_pool_size = $((2**($ramBase+3)))M
innodb_additional_mem_pool_size = ${ramBase}M
innodb_log_buffer_size = ${ramBase}M
innodb_thread_concurrency = $((2**$ramBase))
 
[mysqld_safe]
# Basic safe settings
log-error = /var/log/mysqld.log
pid-file = /var/run/mysqld/mysqld.pid
EOF
echo "Template Applied!"
}

#Run MySQL Tuner
function mysql_tuner {
  check_panel
#Current tuner requires dependency, so does mysql primer, so installing that first:
if [ "$panel_type" == 'plesk' ]
  then
    mkdir -p /root/CloudTech
    wget --no-check-certificate -O /root/CloudTech/mysqltuner.pl https://raw.githubusercontent.com/major/MySQLTuner-perl/d220a9ac7972af19d0eda3d80721f9673e11243f/mysqltuner.pl && perl /root/CloudTech/mysqltuner.pl > /root/CloudTech/mysql_tuner_$epoch
    rm -rf /root/CloudTech/mysqltuner.pl
    cat /root/CloudTech/mysql_tuner_$epoch
    echo
    echo "Take note of the MySQL Tuner results above and press enter."
    read enterKey
elif [ "$panel_type" == 'cpanel' ]
   then
    echo "This is the root mysql password, copy it then press enter:"
    echo "$db_pass"
    read enterKey
    mkdir -p /root/CloudTech
    wget --no-check-certificate -O /root/CloudTech/mysqltuner.pl https://raw.githubusercontent.com/major/MySQLTuner-perl/d220a9ac7972af19d0eda3d80721f9673e11243f/mysqltuner.pl && perl /root/CloudTech/mysqltuner.pl > /root/CloudTech/mysql_tuner_$epoch
    rm -rf /root/CloudTech/mysqltuner.pl
    cat /root/CloudTech/mysql_tuner_$epoch
    echo
    echo "Take note of the MySQL Tuner results above and press enter."
    read enterKey
else
  echo "Unknown hosting panel, run this manually."
fi
}

function mysql_report {
  check_panel
  if [ "$panel_type" == 'plesk' ]
    then
    wget --no-check-certificate -O /usr/local/src/mysqlreport https://raw.githubusercontent.com/daniel-nichter/hackmysql.com/master/mysqlreport/mysqlreport && perl /usr/local/src/mysqlreport --user admin --password `cat /etc/psa/.psa.shadow`
    echo
    echo "Take note of the MySQL Report results above and press enter."
    read enterKey
  elif [ "$panel_type" == 'cpanel' ]
   then
    #We need a cpanel module for this:
    cpan DBD::mysql

    wget --no-check-certificate -O /usr/local/src/mysqlreport https://raw.githubusercontent.com/daniel-nichter/hackmysql.com/master/mysqlreport/mysqlreport && perl /usr/local/src/mysqlreport --user root --password `grep password /root/.my.cnf | awk -F\" '{print $2}'`
    echo
    echo "Take note of the MySQL Report results above and press enter."
    read enterKey
else
  echo "Unknown hosting panel, run this manually."
fi
}

function mysql_primer {
  check_panel
yum install -y bc

if [ "$panel_type" == 'plesk' ]
    then
      wget -O /usr/local/src/tuning-primer.sh https://launchpad.net/mysql-tuning-primer/trunk/1.6-r1/+download/tuning-primer.sh && bash /usr/local/src/tuning-primer.sh
    echo
    echo "Take note of the MySQL Primer results above and press enter."
    read enterKey

elif [ "$panel_type" == 'cpanel' ]
   then
       echo "This is the root mysql password, copy it then press enter:"
    echo "$db_pass"
    read enterKey

    wget -O /usr/local/src/tuning-primer.sh https://launchpad.net/mysql-tuning-primer/trunk/1.6-r1/+download/tuning-primer.sh && bash /usr/local/src/tuning-primer.sh
    echo
    echo "Take note of the MySQL Primer results above and press enter."
    read enterKey

else
  echo "Unknown hosting panel, run this manually."
fi


}

#Generate Support Request
function support_request {
echo "**************************************************************************************************"
echo "**************************************************************************************************"
echo "Printed below is a template for your support request. You still need to do the actual tuning, and customize the support request accordingly!"
echo "**************************************************************************************************"
echo "**************************************************************************************************"
echo ""
echo "Thanks for ordering the MySQL Optimization service! We have completed your optimization, have made several changes based upon our findings. Here is what we've done:"
echo ""
echo "First and foremost, we've backed up all configuration files, and your databases were exported into /root/CloudTech/db-backups. Everything was timestamped if you need to restore one of these databases in the future."
echo ""
echo -n "We also repaired and optimized all applicable database tables to clear out the overhead. This is the actual size of a table datafile relative to the ideal size of the same datafile (as if when just restored from backup). For performance reasons, MySQL does not compact the datafiles after it deletes or updates rows. This overhead is bad for table scans. For example, when your query needs to run over all table values, it will need to look at more empty space."

#disabling this portion for now, will fix later
#if [ "$sizeDiff" -ne 0 ]
#   then
#   echo -n " The optimization we performed removed " | tee -a $reportFile
#   if [ "$sizeDiff" > 10240 ]
#       then
#          diffMB=$(($sizeDiff / 1024))
#          echo -n "$diffMB MB" | tee -a $reportFile
#       else
#          echo -n "$sizeDiff KB" | tee -a $reportFile
#   fi
#   echo -n " of overhead from your databases!" | tee -a $reportFile
#fi
echo "" tee -a $reportFile
echo ""
echo "On the server level, we've also adjusted several parameters, including increases to query_cache_size, tmp_table_size, and max_heap_table_size. Here are the new parameters:"
echo ""
echo "RUN THIS COMMAND TO GET THE CHANGES:"
echo ""
echo "diff /etc/my.cnf-$epoch.ct /etc/my.cnf | grep '>'"
echo ""
slowLog=$(cat /etc/my.cnf | grep 'log_slow_queries')
if [ "$slowLog" == "" ]
   then
echo "SLOW QUERY LOGGING ISN'T ENABLED, IT PROBABLY SHOULD BE"
else
echo "Finally, we've enabled the slow query log, which is located as follows:"
echo ""
echo "/var/log/mysqld.slow.log"
echo ""
echo "You can utilize the following SSH command to view the contents of this file in an organized fashion:"
echo ""
echo "mysqldumpslow -r -a /var/log/mysqld.slow.log"
echo ""
echo "IF THERE IS ANY GOOD DATA IN THERE, TELL THEM ABOUT IT."
echo ""
fi
    echo "In an effort to continue improving our CloudTech services, we are including a link to a brief survey below. Your input is very important to (mt) Media Temple and will be kept confidential."
    echo ""
    echo "Simply click on the link below, or cut and paste the entire URL into your browser to access the survey:"
    echo ""
    echo "http://goo.gl/cxWO4"
    echo ""
echo "If you have any questions or concerns about the MySQL Optimization we've performed or notice any subsequent issues as a result of the work we've done, please reply to this support request, and we would be happy to investigate further. We're confident your MySQL service should be running much better."
}

#Bash Menu to select options
clear
initial_setup
while [ "$action" != "Q" ] && [ "$action" != "q" ]
do
echo
echo
echo -e "\033[31m######################################\e[0m"
echo
echo -e "\033[31mMySQL Optimization Tools\e[0m"
echo
echo -e "\033[34m1) Pre-Tune (Run first if you haven't yet)"
echo "2) Apply 'Making it better' Template"
echo "3) MySQL Tuner"
echo "4) MySQL Report"
echo "5) Mysql Primer"
echo "6) Generate Support request (do this after you've made all changes)"
echo -e "Q) Exit\e[0m"
echo
echo -e "\033[31m######################################\e[0m"
echo
read -p "Please select an option to continue: " action
echo
clear
case $action in
1)

pre_tune

;;
2)

make_it_better

;;
3)

mysql_tuner

;;
4)

mysql_report

;;
5)

mysql_primer

;;
6)

support_request

;;
 *)

   ;;
esac

done
