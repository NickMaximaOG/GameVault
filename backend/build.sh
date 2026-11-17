#!/usr/bin/env bash
# Maven-free build for Debian/Ubuntu using libraries installed with apt:
#   sudo apt install openjdk-21-jdk libmariadb-java libjackson2-databind-java libhikaricp-java libslf4j-java junit5
# Normal development uses Maven instead:  mvn package
# Usage: ./build.sh            compile to target/classes
#        ./build.sh test       compile and run the tests (needs MySQL, see ../README.md)
set -euo pipefail
cd "$(dirname "$0")"
J=/usr/share/java
CP="$J/mariadb-java-client.jar:$J/HikariCP.jar:$J/slf4j-api.jar:$J/slf4j-simple.jar:$J/jackson-core.jar:$J/jackson-databind.jar:$J/jackson-annotations.jar"
rm -rf target && mkdir -p target/classes target/test-classes
javac --release 21 -Xlint:all -d target/classes -cp "$CP" $(find src/main/java -name '*.java')
echo "compiled main: $(find target/classes -name '*.class' | wc -l) classes"
if [ "${1:-}" = "test" ]; then
  CON="$J/junit-platform-console-standalone.jar"
  javac --release 21 -d target/test-classes -cp "target/classes:$CP:$CON" $(find src/test/java -name '*.java')
  java -Duser.timezone=UTC -jar "$CON" --class-path "target/classes:target/test-classes:$CP" \
       --scan-class-path target/test-classes --details=tree --disable-banner
fi
