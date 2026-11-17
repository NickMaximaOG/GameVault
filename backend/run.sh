#!/usr/bin/env bash
# Starts the API from target/classes (after ./build.sh). Reads settings from the environment.
set -euo pipefail
cd "$(dirname "$0")"
J=/usr/share/java
CP="target/classes:$J/mariadb-java-client.jar:$J/HikariCP.jar:$J/slf4j-api.jar:$J/slf4j-simple.jar:$J/jackson-core.jar:$J/jackson-databind.jar:$J/jackson-annotations.jar"
exec java -Duser.timezone=UTC -cp "$CP" com.gamevault.App
