FROM alpinelinux/build-base:latest

USER root

RUN apk add --no-cache bash

COPY repo-manager.sh /usr/local/bin/repo-manager.sh
RUN chmod 0755 /usr/local/bin/repo-manager.sh

ENTRYPOINT ["/usr/local/bin/repo-manager.sh"]
