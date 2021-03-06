#!/bin/bash

[[ ! -f /etc/redhat-release ]] && PrintLog ERROR "Opss... run this script only in RedHat OS. Exiting..." && exit 1

PrintLog() {
    level=$1
    msg=$2
    timestamp=$(date +"%d/%b/%Y:%H:%M:%S %z")
    echo "[${timestamp}] [${level}] ${msg}"
}


PrintLog DEBUG "project_branch: ${project_branch}"
PrintLog DEBUG "globodns_host: ${globodns_host}"
PrintLog DEBUG "globodns_resolver_nameserver: ${globodns_resolver_nameserver}"

# virtual env vars
virtualenv_name='cloudstack'

if [ -f "/opt/generic/python27/bin/virtualenvwrapper.sh" ]; then
    source /opt/generic/python27/bin/virtualenvwrapper.sh

    req_pkgs=$(rpm -qa | egrep -c "(python-devel|gmp-devel)")
    if [ ${req_pkgs} -ne 2 ]; then
        PrintLog FATAL "Please install python-devel and gmp-devel packages"
        exit 1
    fi
    PrintLog INFO "Switching to '${virtualenv_name}' virtualenv"

    [[ -z ${WORKON_HOME} ]] && WORKON_HOME=~jenkins/.virtualenvs
    [[ ! -d "${WORKON_HOME}/${virtualenv_name}" ]] && mkvirtualenv -p /opt/generic/python27/bin/python ${virtualenv_name}
    source $WORKON_HOME/${virtualenv_name}/bin/activate
    
    pip="${WORKON_HOME}/${virtualenv_name}/bin/pip"
    pip_options="--extra-index-url=https://artifactory.globoi.com/artifactory/pypi/ --extra-index-url=https://artifactory.globoi.com/artifactory/api/pypi/pypi/simple --extra-index-url=https://pypi.python.org"
    python="${WORKON_HOME}/${virtualenv_name}/bin/python"
    nosetests="${WORKON_HOME}/${virtualenv_name}/bin/nosetests"
    ${pip} freeze | grep -q simple-db-migrate || ${pip} install simple-db-migrate
    # require for dnsapi
    ${pip} freeze | grep -q beautifulsoup4 || ${pip} install beautifulsoup4==4.3.2 ${pip_options}
    # {pip} freeze | grep -q pycrypto || {pip} install pycrypto
else
    PrintLog FATAL "No virtualenv wrapper was found, please install it!"
fi

project_basedir=$(pwd)
globo_test_basedir="${project_basedir}/test/integration/globo"
maven_log='/tmp/cloudstack.log'

cloudstack_deploy_dir='/var/lib/jenkins/cloudstack-deploy'
export JAVA_HOME='/usr/lib/jvm/java-1.7.0-openjdk-1.7.0.65.x86_64'
export PATH="$JAVA_HOME/bin:$PATH"

debug=1

StartJetty() {
    max_retries=18
    sleep_time=10
    ret_count=1
    PrintLog INFO "Starting cloudstack w/ simulator..."
    MAVEN_OPTS="-Xmx2048m -XX:MaxPermSize=512m -Xdebug -Xrunjdwp:transport=dt_socket,address=8787,server=y,suspend=n" mvn --log-file ${maven_log} -pl client jetty:run -Dsimulator >/dev/null &
    [[ $debug ]] && PrintLog DEBUG "Checking if jetty is ready..."
    [[ ! -f $maven_log ]] && sleep 5
    while [ $ret_count -le $max_retries ]; do
        if grep -q '\[INFO\] Started Jetty Server' ${maven_log}; then
            [[ $debug ]] && PrintLog INFO "Jetty is running and ready"
            return 0
        else
            [[ $debug ]] && PrintLog DEBUG "Jetty is not ready yet... sleeping more ${sleep_time}sec (${ret_count}/${max_retries})"
            sleep $sleep_time
            ret_count=$[$ret_count+1]
        fi
    done
    PrintLog ERROR "Jetty is not ready after waiting for $((${max_retries}*${sleep_time})) sec."
    exit 1
}

ShutdownJetty() {
    max_retries=7
    sleep_time=3
    ret_count=1
    PrintLog INFO "Stopping cloudstack..."
    kill $(ps wwwaux | awk '/[m]aven.*jetty:run -Dsimulator/ {print $2}') 2>/dev/null
    [[ $? -ne 0 ]] && PrintLog WARN "Failed to stop jetty"
    while [ $ret_count -le $max_retries ]; do
        if [[ -z $(ps wwwaux | awk '/[m]aven.*jetty:run -Dsimulator/ {print $2}') ]]; then
            return 1
        else
            [[ $debug ]] && PrintLog DEBUG "Jetty is alive, waiting more ${sleep_time} (${ret_count}/${max_retries})"
            sleep $sleep_time
            ret_count=$[$ret_count+1]
        fi
    done
    PrintLog WARN "Kill -9 to jetty process!!!"
    kill -9 $(ps wwwaux | awk '/[m]aven.*jetty:run -Dsimulator/ {print $2}')
}

WaitForInfrastructure() {
    max_retries=22
    sleep_time=10
    ret_count=1
    PrintLog INFO "Waiting for infrastructure..."
    while [ $ret_count -le $max_retries ]; do
        if grep -q 'server resources successfully discovered by SimulatorSecondaryDiscoverer' ${maven_log}; then
            [[ $debug ]] && PrintLog INFO "Infrastructure is ready"
            return 1
        else
            [[ $debug ]] && PrintLog DEBUG "Infrasctructure is not ready yet... sleeping more ${sleep_time}sec (${ret_count}/${max_retries})"
            sleep $sleep_time
            ret_count=$[$ret_count+1]
        fi
    done
    PrintLog ERROR "Infrastructure was not ready in $((${max_retries}*${sleep_time})) seconds..."
    exit 1
}

installMarvin() {
    # Tries to install marvin.. just in case..
    ${pip} freeze | grep -qi Marvin || ${pip} install --allow-external mysql-connector-python ${project_basedir}/tools/marvin/dist/Marvin-*.tar.gz

    # Install marvin to ensure that we are using the correct version
    ${pip} freeze | grep -qi Marvin && ${pip} install --upgrade --allow-external mysql-connector-python ${project_basedir}/tools/marvin/dist/Marvin-*.tar.gz

    ls ~/.virtualenvs/cloudstack/lib/python2.7/site-packages/marvin/cloudstackAPI/ | grep addG
}


# Checkout repository, compile, use virtualenv and sync the mavin commands
ShutdownJetty
PrintLog INFO "Removing log file '${maven_log}'"
rm -f ${maven_log}
[[ $debug ]] && PrintLog DEBUG "Change work dir to ${project_basedir}"
[[ ! -d $project_basedir ]] && PrintLog ERROR "Directory ${project_basedir} does not exist...exit" && exit 1
cd ${project_basedir}
PrintLog INFO "Checking out to branch '${project_branch}'"
git checkout ${project_branch} >/dev/null 2>/dev/null
PrintLog INFO "Pulling latest modifications"
git pull

last_commit=$(git log -n 1 | grep commit | cut -d' ' -f2)
last_commit_file="/tmp/cloudstack-integration-tests-last-commit.txt"

PrintLog INFO "last git commit: ${last_commit}"

#vejo se o arquivo de ultimo commit existe
[[ ! -f "$last_commit_file" ]] && echo "" > ${last_commit_file}

saved_last_commit=$(cat ${last_commit_file} | head -1)

if [ "${last_commit}" != "${saved_last_commit}" ]; then

    PrintLog INFO "Solving some dependencies..."
    if [ ! -d "/var/lib/jenkins/cloudstack-deploy" ]; then
        PrintLog INFO "Clone cloudstack-deploy project into ${cloudstack_deploy_dir}"
        git clone https://gitlab.globoi.com/time-evolucao-infra/cloudstack-deploy.git -b master ${cloudstack_deploy_dir}
    fi

    PrintLog INFO "Compiling cloudstack..."

    mvn -Pdeveloper -Dsimulator clean install
    [[ $? -ne 0 ]] && PrintLog ERROR "Failed to compile ACS" && exit 1
    PrintLog INFO "Compiling and packing marvin..."
    mvn -P developer -pl :cloud-marvin
    [[ $? -ne 0 ]] && PrintLog ERROR "Failed to compile marvin" && exit 1

    echo "${last_commit}" > ${last_commit_file}

    installMarvin

    # Deploy DB, Populate DB and create infra structure
    PrintLog INFO "Creating SQL schema"
    mvn -q -P developer -pl developer -Ddeploydb >/dev/null 2>/dev/null
    [[ $? -ne 0 ]] && PrintLog ERROR "Failed to deploy DB" && exit 1
    mvn -Pdeveloper -pl developer -Ddeploydb-simulator >/dev/null 2>/dev/null
    [[ $? -ne 0 ]] && PrintLog ERROR "Failed to deploy DB simulator" && exit 1
    PrintLog INFO "Doing some required SQL migrations"
    (cd /var/lib/jenkins/cloudstack-deploy/dbmigrate && git checkout master && db-migrate >/dev/null)
    cd -
    StartJetty
    PrintLog INFO "Creating an advanced zone..."
    ${python} ${project_basedir}/tools/marvin/marvin/deployDataCenter.py -i ${project_basedir}/test/integration/globo/cfg/advanced-globo.cfg

    # Required restart
    WaitForInfrastructure
    ShutdownJetty
    PrintLog INFO "Removing log file '${maven_log}'"
    rm -f ${maven_log}
else
    PrintLog INFO "There were no code changes, so we don't need compile!!! yaayyyyyyyy"
fi

StartJetty

# Tests
PrintLog INFO "Sync marvin"
cd ${project_basedir}
pwd
mvn -Pdeveloper,marvin.sync -Dendpoint=localhost -pl :cloud-marvin

sleep 5

installMarvin

# check if Globo assets are in marvin tarball file
[[ ! `tar tvzf ${project_basedir}/tools/marvin/dist/Marvin-*.tar.gz | grep Globo` ]] && PrintLog ERROR "Tests will fail!!! Marvin tarball does not contain Globo files" && exit 1

PrintLog INFO "Testing DNS API"
${nosetests} --with-marvin --marvin-config=${globo_test_basedir}/demo.cfg --zone=Sandbox-simulator ${globo_test_basedir}/test_dns_api.py
retval=$?
if [[ $retval -ne 0 ]]; then
    PrintLog ERROR "Tests failed!!!"
    ShutdownJetty
    exit 1
fi

results_file=$(ls -tr /tmp/MarvinLogs/$(date +"%b_%d_%Y")*/results.txt | tail -1)
echo "Results file: ${results_file}"

tail -1 ${results_file} | grep -qw 'OK'
retval=$?
cat ${results_file}
if [[ $retval -eq 0 ]]; then
    ShutdownJetty
    PrintLog INFO "All steps and tests successfully passed"
    exit 0
else
    PrintLog ERROR "Tests failed!!!"
    exit 1
fi
