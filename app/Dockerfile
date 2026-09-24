FROM eclipse-temurin:17-jre

COPY target/repro-client.jar /app.jar

# Exec form so the JVM is PID 1 and receives the kubelet's SIGTERM directly.
# Module flags match what gfsh adds for Geode 1.15 members on JDK 11+ (MemberJvmOptions).
ENTRYPOINT ["java", \
  "--add-exports=java.base/sun.nio.ch=ALL-UNNAMED", \
  "--add-exports=java.management/com.sun.jmx.remote.security=ALL-UNNAMED", \
  "--add-opens=java.base/java.lang=ALL-UNNAMED", \
  "--add-opens=java.base/java.nio=ALL-UNNAMED", \
  "--add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED", \
  "-jar", "/app.jar"]
