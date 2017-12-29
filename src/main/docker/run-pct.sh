#!/bin/bash
set -e
set -x

if [ $# -eq 1 ]; then
  # if `docker run` only has one argument, we assume that the user is running an alternate command 
  # like `bash` to inspect the image. All options passed to the executable shoud have at least 2 arguments.
  echo "Only one argument is specified, running a custom command"
  exec "$@"
  exit 0
fi

###
# Process arguments
###
if [ -n "${ARTIFACT_ID}" ]; then
  echo "Running PCT for plugin ${ARTIFACT_ID}"
fi

if [ -n "${CHECKOUT_SRC}" ] ; then
  echo "Using custom checkout source: ${CHECKOUT_SRC}"
else
  if [ -z "${ARTIFACT_ID}" ] ; then
    if [ ! -e "/pct/plugin-src/pom.xml" ] ; then
      echo "Error: Plugin source is missing, cannot generate a default checkout path without ARTIFACT_ID"
      exit -1
    fi
  else
    CHECKOUT_SRC="https://github.com/jenkinsci/${ARTIFACT_ID}-plugin.git"
  fi
fi

if [ -z "${VERSION}" ] ; then
  VERSION="master"
fi

if [ -f "${JENKINS_WAR_PATH}" ]; then
  echo "Using custom Jenkins WAR from ${JENKINS_WAR_PATH}"
  mkdir -p "${PCT_TMP}"
  # WAR is accessed many times in the PCT runs, let's keep it local insead of pulling it from a volume
  cp "${JENKINS_WAR_PATH}" "${PCT_TMP}/jenkins.war"
  WAR_PATH_OPT="-war ${PCT_TMP}/jenkins.war "
else
  WAR_PATH_OPT=""
fi

extra_java_opts=()
if [[ "$DEBUG" ]] ; then
  extra_java_opts+=( \
    '-Xdebug' \
    '-Xrunjdwp:server=y,transport=dt_socket,address=5005,suspend=y' \
  )
fi

###
# Checkout sources
###
mkdir -p "${PCT_TMP}/localCheckoutDir"
cd "${PCT_TMP}/localCheckoutDir"
TMP_CHECKOUT_DIR="${PCT_TMP}/localCheckoutDir/undefined"
if [ -e "/pct/plugin-src/pom.xml" ] ; then
  echo "Located custom plugin sources on the volume"
  mkdir "${TMP_CHECKOUT_DIR}"
  cp -R /pct/plugin-src/* "${TMP_CHECKOUT_DIR}/"
  # Due to whatever reason PCT blows up if you have work in the repo
  cd "${TMP_CHECKOUT_DIR}" && mvn clean && rm -rf work
else
  echo "Checking out from ${CHECKOUT_SRC}:${VERSION}"
  git clone "${CHECKOUT_SRC}"
  mv $(ls .) ${TMP_CHECKOUT_DIR}
  cd ${TMP_CHECKOUT_DIR} && git checkout "${VERSION}"
fi

###
# Determine artifact ID and then move the project to a proper location
###
cd "${TMP_CHECKOUT_DIR}"
if [ -z "${ARTIFACT_ID}" ] ; then
  ARTIFACT_ID=$(mvn org.apache.maven.plugins:maven-help-plugin:2.2:evaluate -Dexpression=project.artifactId | grep -Ev '(^\[|Download.*)')
  echo "ARTIFACT_ID is not specified, using ${ARTIFACT_ID} defined in the POM file"
  mvn clean
fi
mv "${TMP_CHECKOUT_DIR}" "${PCT_TMP}/localCheckoutDir/${ARTIFACT_ID}"

mkdir -p "${PCT_TMP}/work"
mkdir -p "${PCT_OUTPUT_DIR}"

# The image always uses external Maven due to https://issues.jenkins-ci.org/browse/JENKINS-48710
exec java ${JAVA_OPTS} ${extra_java_opts[@]} -jar /pct/pct-cli.jar -reportFile ${PCT_OUTPUT_DIR}/pct-report.xml -workDirectory "${PCT_TMP}/work" ${WAR_PATH_OPT} -skipTestCache true -localCheckoutDir "${PCT_TMP}/localCheckoutDir/${ARTIFACT_ID}" -includePlugins "${ARTIFACT_ID}" -mvn "/usr/bin/mvn" "$@"
