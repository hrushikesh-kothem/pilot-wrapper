ARG PILOT_VERSION=3.12.1.99

ARG PYTHON_VERSION=3.12.11
ARG BOOST_VERSION=1.88.0

FROM docker.io/almalinux:9.6

ARG PYTHON_VERSION
ARG PILOT_VERSION
ARG BOOST_VERSION

RUN dnf install -y epel-release yum-utils \
    && yum-config-manager --enable crb \
    && dnf update -y

# install rucio dependencies
RUN dnf install -y \
        gfal2-all \
        gfal2-devel \
        nordugrid-arc-client \
        nordugrid-arc-plugins-gfal \
        nordugrid-arc-plugins-globus \
        nordugrid-arc-plugins-s3 \
        nordugrid-arc-plugins-xrootd \
        xrootd-client \
        git

# install other dependencies mainly for building Python and Boost
RUN dnf install -y gcc make voms-clients apptainer wget openssl-devel bzip2-devel libffi-devel zlib-devel \
    which emacs unzip cmake bzip2 gcc-c++ glib2-devel

# install Python
RUN mkdir /tmp/python && cd /tmp/python && \
    wget https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz && \
    tar -xzf Python-*.tgz && rm -f Python-*.tgz && \
    cd Python-* && \
    ./configure  && \
    make altinstall && \
    echo /usr/local/lib > /etc/ld.so.conf.d/local.conf && ldconfig && cd / && rm -rf /tmp/python

# install Boost Python
RUN mkdir /tmp/boost && cd /tmp/boost && \
    wget https://archives.boost.io/release/${BOOST_VERSION}/source/boost_$(echo ${BOOST_VERSION} | sed 's/\./_/g').tar.bz2 && \
    tar -xf boost_*.tar.bz2 && rm -f boost_*.tar.bz2 && \
    cd boost_* && \
    export CPLUS_INCLUDE_PATH=$CPLUS_INCLUDE_PATH:/usr/local/include/python$(echo ${PYTHON_VERSION} | sed -E 's/\.[0-9]+$//') && \
    ./bootstrap.sh --with-python=/usr/local/bin/python$(echo ${PYTHON_VERSION} | sed -E 's/\.[0-9]+$//') && \
    ./b2 install && cd / && rm -rf /tmp/boost

RUN  dnf clean all && rm -rf /var/cache/dnf

# setup venv with pythonX.Y
RUN python$(echo ${PYTHON_VERSION} | sed -E 's/\.[0-9]+$//') -m venv /opt/pilot

RUN /opt/pilot/bin/pip install --no-cache-dir -U pip setuptools
RUN /opt/pilot/bin/pip install --no-cache-dir -U rucio-clients psutil gfal2-python

# rucio clients configuration
RUN mkdir -p /opt/rucio/etc && \
    ln -s /scratch/rucio.cfg /opt/rucio/etc/rucio.cfg

# install CA certificates
RUN mkdir -p /etc/grid-security/certificates &&  \
    mkdir /tmp/cert && \
    cd /tmp/cert && \
    wget -l1 -r -np -nH -e robots=off --cut-dirs=7 http://repository.egi.eu/sw/production/cas/1/current/tgz/ && \
    bash -c 'for tgz in $(ls *.tar.gz); do tar xzf ./$tgz --strip-components=1 -C /etc/grid-security/certificates; done' && \
    cd - && \
    rm -rf /tmp/cert

ENV X509_CERT_DIR=/etc/grid-security/certificates

# setup pilot
RUN mkdir /pilot
WORKDIR /pilot

ARG WRAPPER_NAME=runpilot2-wrapper.sh

# copy the wrapper script
COPY ${WRAPPER_NAME} .
RUN chmod +x ${WRAPPER_NAME}

# download and extract pilot tarball
# RUN wget -O pilot3.tar.gz https://github.com/PanDAWMS/pilot3/archive/refs/tags/${PILOT_VERSION}.tar.gz && \
#     tar xvfz pilot3.tar.gz && rm -f pilot3.tar.gz && mv pilot3-* pilot3

# download pilot3 from fork (master-k8s branch, shallow clone for latest commit)
ADD https://api.github.com/repos/hrushikesh-kothem/pilot3/commits/k8s_native_pilot /tmp/cachebust
RUN git clone --branch k8s_native_pilot --depth 1 https://github.com/hrushikesh-kothem/pilot3.git pilot3

# install kubernetes python client (k8s-native feature)
RUN /opt/pilot/bin/pip install --no-cache-dir kubernetes

# create entrypoint script
RUN echo '#!/bin/bash' > entrypoint.sh && \
    echo 'cp /scratch/* .' >> entrypoint.sh && \
    echo 'source /opt/pilot/bin/activate' >> entrypoint.sh && \
    echo './'${WRAPPER_NAME}' $@' >> entrypoint.sh && \
    chmod +x entrypoint.sh

ENTRYPOINT ["/pilot/entrypoint.sh"]
CMD ["/bin/bash"]
