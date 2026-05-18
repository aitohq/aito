#!/bin/bash
set -e

# JDK 17 module access flags (must match jdk17AddOpens in build.sbt)
JVM_ADD_OPENS=(
  "--add-opens=java.base/java.io=ALL-UNNAMED"
  "--add-opens=java.base/java.nio=ALL-UNNAMED"
  "--add-opens=java.base/java.lang=ALL-UNNAMED"
  "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED"
  "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED"
  "--add-opens=java.base/java.util=ALL-UNNAMED"
  "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"
  "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED"
  "--add-opens=java.base/jdk.internal.misc=ALL-UNNAMED"
  "--add-opens=java.base/jdk.internal.ref=ALL-UNNAMED"
)

# JVM memory settings (override via environment)
: "${JVM_XMX:=2g}"
: "${JVM_XMS:=512m}"

VALIDATE_SCRIPT="$(dirname "$0")/validate-license.sh"
if [ -x "${VALIDATE_SCRIPT}" ]; then
  eval "$("${VALIDATE_SCRIPT}")"
  export AITO_ROW_LIMIT_PER_TABLE AITO_ROW_LIMIT_TOTAL
else
  if [ -n "${AITO_LICENSE_KEY:-}" ]; then
    export AITO_ROW_LIMIT_PER_TABLE=0
    export AITO_ROW_LIMIT_TOTAL=0
  else
    export AITO_ROW_LIMIT_PER_TABLE=10000
    export AITO_ROW_LIMIT_TOTAL=50000
  fi
fi

if [ "${AITO_ROW_LIMIT_PER_TABLE}" = "0" ] && [ "${AITO_ROW_LIMIT_TOTAL}" = "0" ]; then
  echo ""
  echo "======================================"
  echo "  Aito Core - Licensed Mode"
  echo "======================================"
  echo ""
else
  echo ""
  echo "======================================"
  echo "  Aito Core - Free Mode"
  echo "  ${AITO_ROW_LIMIT_PER_TABLE} rows/table, ${AITO_ROW_LIMIT_TOTAL} total"
  echo "  Get a license at https://aito.ai"
  echo "======================================"
  echo ""
fi

exec java \
  -Xmx${JVM_XMX} \
  -Xms${JVM_XMS} \
  -XX:+UseG1GC \
  "${JVM_ADD_OPENS[@]}" \
  -jar /opt/aitoai/aitoai.jar \
  "$@"
