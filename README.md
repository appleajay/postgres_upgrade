# postgres_upgrade
A simple bash script to upgrade postgresql on redhat based systems(RHEL, CentOS 6/7). 

**Requirements**
1. New postgresql packages should already be installed.
2. Old postgresql service should be stopped in read-write mode. (If you are using hotstandby mode, remove recovery file then start-stop postgresql service)
3. New Data dir mount point must have size greater then existing data size

**How to?**
1. Stop old postgresql service.
2. Install new Postgresql Packages.
3. Run the script with root user.
4. Remove the old Postgresql packages.
5. Remove old data dir.

**Validations**
1. Tested on Centos 6.5, centos 7.5 and RHEL 7.5
2. Tested migration of Postgresql9.3 to postgresql-10.
3. Following are the test cases results

| Data dir size |  script runtime |
|--|--|
| 14GB |  3.2 Mins|
| 248GB | 19 Mins |
| 20GB |4 Min |
