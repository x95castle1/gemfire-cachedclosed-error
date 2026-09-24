FROM eclipse-temurin:17-jre

ARG GEODE_VERSION=1.15.1

# The tarball is downloaded and sha256-checked by scripts/cluster-up.sh.
COPY apache-geode-${GEODE_VERSION}.tgz /tmp/geode.tgz
RUN mkdir -p /opt/geode /data \
 && tar -xzf /tmp/geode.tgz -C /opt/geode --strip-components=1 \
 && rm /tmp/geode.tgz

ENV GEODE_HOME=/opt/geode
ENV PATH=/opt/geode/bin:$PATH

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 10334 40404 1099
ENTRYPOINT ["/start.sh"]
