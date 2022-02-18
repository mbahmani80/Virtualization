#!/bin/bash - 
#===============================================================================
#
#          FILE: System_related_commands.sh
# 
#         USAGE: ./System_related_commands.sh 
# 
# 
#        AUTHOR: Mahdi Bahamni, 
#  ORGANIZATION: 
#       CREATED: 02/18/2022 12:02
#      REVISION:  ---
#===============================================================================

# ESXCLI System related commands

# Show ESXi version and build
[root@localhost:~] esxcli system version get

# List only advanced settings that have been changed from the system defaults
[root@localhost:~] esxcli system settings advanced list –d

# List only kernel settings that have been changed from the system defaults
[root@localhost:~] esxcli system settings kernel list –d

# List / Change / Test SNMP
[root@localhost:~] esxcli system snmp get | hash | set | test

# Returns the ESXi build and version numbers.
[root@localhost:~] esxcli system version get
   Product: VMware ESXi
   Version: 6.5.0
   Build: Releasebuild-8294253
   Update: 2
   Patch: 50

# Returns the hostname, domain and FQDN for the host.
[root@localhost:~]   esxcli system hostname get
   Domain Name: 
   Fully Qualified Domain Name: localhost
   Host Name: localhost
[root@localhost:~]   

# Returns the date and time of when ESXi was installed.
[root@localhost:~]   esxcli system stats installtime get
2018-12-02T05:25:49

# Lists the local users created on the ESXi host.
[root@localhost:~]   esxcli system account list
User ID  Description                                
-------  -------------------------------------------
root     Administrator                              
dcui     DCUI User                                  
vpxuser  VMware VirtualCenter administration account

# This command allows you to create local ESXi users. All the parameters used in the example are mandatory.
[root@localhost:~]     esxcli system account add --help
Usage: esxcli system account add [cmd options]

Description: 
  add                   Create a new local user account.

Cmd options:
  -d|--description=<str>
                        User description, e.g. full name.
  -i|--id=<str>         User ID, e.g. "administrator". (required)
  -p|--password=<str>   User password. (secret)
                        WARNING: Providing secret values on the command line is insecure because it may be
                        logged or preserved in history files. Instead, specify this option with no value on
                        the command line, and enter the value on the supplied prompt.
  -c|--password-confirmation=<str>
                        Password confirmation. Required if password is specified. (secret)
                        WARNING: Providing secret values on the command line is insecure because it may be
                        logged or preserved in history files. Instead, specify this option with no value on
                        the command line, and enter the value on the supplied prompt.
[root@localhost:~] 
[root@localhost:~]   esxcli system account add --help

# This command allows you to create local ESXi users. All the parameters used in the example are mandatory.
[root@localhost:~]   esxcli system account add -d="Mahdi Guest" -i="Mahdi" -p="P@ssw0rd12" -c="P@ssw0rd12"
[root@localhost:~]   esxcli system account list
User ID  Description                                
-------  -------------------------------------------
root     Administrator                              
dcui     DCUI User                                  
vpxuser  VMware VirtualCenter administration account
Mahdi    Mahdi Guest  

# Use this command to put ESXi in maintenance mode or take it out.
[root@localhost:~]  esxcli system maintenanceMode set -enable true

# Enter Maintenance Mode
[root@localhost:~]  esxcli system maintenanceMode set –-enable yes

# Exit maintenance Mode
[root@localhost:~]  esxcli system maintenanceMode set --enable no

# Use this command to reboot or shutdown ESXi. The -d parameter is a countdown timer; minimum 10 seconds. ESXi must be in maintenance mode before you can use the command.
[root@localhost:~]  esxcli system shutdown reboot -d 10 -r "Patch Updates"
