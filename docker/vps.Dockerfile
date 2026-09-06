# Plain ubuntu:22.04 with systemd installed, so the real install.sh
# (systemctl enable/start) works unmodified — built ourselves for arm64/amd64
# portability instead of relying on a prebuilt systemd image.
FROM ubuntu:22.04

ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y systemd systemd-sysv curl iproute2 iptables sudo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/log/*log /var/cache/apt/*.bin /tmp/* /var/tmp/*

RUN cd /lib/systemd/system/sysinit.target.wants/ && \
      (ls | grep -v systemd-tmpfiles-setup | xargs rm -f) ; \
    rm -f /lib/systemd/system/multi-user.target.wants/* ; \
    rm -f /etc/systemd/system/*.wants/* ; \
    rm -f /lib/systemd/system/local-fs.target.wants/* ; \
    rm -f /lib/systemd/system/sockets.target.wants/*udev* ; \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl* ; \
    rm -f /lib/systemd/system/basic.target.wants/* ; \
    true

VOLUME ["/sys/fs/cgroup"]

COPY install.sh /root/install.sh
RUN chmod +x /root/install.sh

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
