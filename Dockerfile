# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
FROM centos:centos6
MAINTAINER David Lawrence <dkl@mozilla.com>

# Environment configuration
ENV USER bugzilla
ENV HOME /home/bugzilla
ENV BUGZILLA_ROOT $HOME/devel/htdocs/bmo
ENV GITHUB_BASE_GIT https://github.com/mozilla-bteam/bmo
ENV GITHUB_BASE_BRANCH upstream-merge

# Copy over configuration files
COPY docker_files/files /files

# Distribution package installation
RUN yum -y -q install https://dev.mysql.com/get/mysql-community-release-el6-5.noarch.rpm epel-release centos-release-scl yum-utils \
    && yum -y -q groupinstall "Development Tools" \
    && yum-config-manager --enable rhel-server-rhscl-6-rpms \
    && yum -y -q install `cat /files/rpm_list` \
    && yum clean all

# User configuration
RUN useradd -m -G wheel -u 1000 -s /bin/bash $USER \
    && passwd -u -f $USER \
    && echo "bugzilla:bugzilla" | chpasswd

# Apache configuration
RUN cp /files/bugzilla.conf /etc/httpd/conf.d/bugzilla.conf \
    && sed -e "s?User apache?User $USER?" --in-place /etc/httpd/conf/httpd.conf \
    && sed -e "s?Group apache?Group $USER?" --in-place /etc/httpd/conf/httpd.conf

# MySQL configuration
RUN cp /files/my.cnf /etc/my.cnf \
    && chmod 644 /etc/my.cnf \
    && chown root.root /etc/my.cnf \
    && rm -rf /etc/mysql \
    && rm -rf /var/lib/mysql/* \
    && /usr/bin/mysql_install_db --user=$USER --basedir=/usr --datadir=/var/lib/mysql

# Sudoer configuration
RUN cp /files/sudoers /etc/sudoers \
    && chown root.root /etc/sudoers \
    && chmod 440 /etc/sudoers

# Clone the code repo
RUN su $USER -c "git clone $GITHUB_BASE_GIT -b $GITHUB_BASE_BRANCH $BUGZILLA_ROOT"

# Bugzilla dependencies and setup
COPY docker_files/scripts /scripts
RUN chmod a+x /scripts/* \
    && wget https://cpanmin.us/ -O /usr/local/bin/cpanm \
    && chmod +x /usr/local/bin/cpanm
RUN /scripts/install_deps.sh
RUN /scripts/bugzilla_config.sh
RUN /scripts/my_config.sh
RUN chown -R $USER.$USER $HOME

# Networking
RUN echo "NETWORKING=yes" > /etc/sysconfig/network
EXPOSE 80
EXPOSE 5900

# Testing scripts for CI\
ADD https://selenium-release.storage.googleapis.com/2.53/selenium-server-standalone-2.53.0.jar /selenium-server.jar

# Supervisor
RUN cp /files/supervisord.conf /etc/supervisord.conf \
    && chmod 700 /etc/supervisord.conf
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
