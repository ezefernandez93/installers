#!/bin/bash
#
# Copyright (c) 2015 - 2020 imm studios, z.s.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
##############################################################################
## COMMON UTILS

base_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
temp_dir=/tmp/$(basename "${BASH_SOURCE[0]}")

function error_exit {
    printf "\n\033[0;31mInstallation failed\033[0m\n"
    cd $base_dir
    exit 1
}

function finished {
    printf "\n\033[0;92mInstallation completed\033[0m\n"
    cd $base_dir
    exit 0
}

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   error_exit
fi

if [ ! -d $temp_dir ]; then
    mkdir $temp_dir || error_exit
fi

## COMMON UTILS
##############################################################################

NGINX_VERSION="1.19.8"
ZLIB_VERSION="1.2.11"
PCRE_VERSION="8.44"
OPENSSL_VERSION="1.1.1j"

MODULES=(
    "https://github.com/openresty/echo-nginx-module"
    "https://github.com/openresty/headers-more-nginx-module"
    "https://github.com/slact/nchan"
)

echo "" > $temp_dir/rtmp.conf
echo "" > $temp_dir/http.conf

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --with-rtmp)
            MODULES+=("https://github.com/martastain/nginx-rtmp-module")

            echo "rtmp {" >> $temp_dir/rtmp.conf
            echo "    server {" >> $temp_dir/rtmp.conf
            echo "        listen 1935;" >> $temp_dir/rtmp.conf
            echo "        chunk_size 4000;" >> $temp_dir/rtmp.conf
            echo "        include /var/www/*/rtmp.conf;" >> $temp_dir/rtmp.conf
            echo "    }" >> $temp_dir/rtmp.conf
            echo "}" >> $temp_dir/rtmp.conf
            ;;

        --with-kaltura)
            MODULES+=("https://github.com/kaltura/nginx-vod-module")
            echo "vod_metadata_cache              metadata_cache   512m;" >> $temp_dir/http.conf
            echo "vod_response_cache              response_cache   64m;" >> $temp_dir/http.conf
            echo "vod_mapping_cache               mapping_cache    64m;" >> $temp_dir/http.conf
            echo "vod_max_mapping_response_size                    4k;" >> $temp_dir/http.conf
            ;;

        --with-push-stream)
            MODULES+=("https://github.com/wandenberg/nginx-push-stream-module")
            echo "push_stream_shared_memory_size      64M;" >> $temp_dir/http.conf
            ;;

        --with-upload)
            MODULES+=("https://github.com/fdintino/nginx-upload-module")
            ;;

        *)
            echo "Unrecognized option '$key'. Ignoring."
        ;;
    esac
    shift
done

echo ""
echo "Following modules are going to be installed:"
echo ""
for m in ${MODULES[@]}; do
    echo " - $(basename $m)"
done
echo ""


LIBS=(
    "http://zlib.net/zlib-${ZLIB_VERSION}.tar.gz"
    "https://ftp.pcre.org/pub/pcre/pcre-${PCRE_VERSION}.tar.gz"
    "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
)

function install_prerequisites {
    apt-get -y install \
        git \
        build-essential \
        curl \
        libxml2 \
        libxml2-dev \
        libgeoip-dev \
        libxslt-dev \
	wget
}

function download_all {
    cd $temp_dir
    installer_name="nginx-${NGINX_VERSION}"

    if [ ! -f ${installer_name}.tar.gz ]; then
        wget "http://nginx.org/download/${installer_name}.tar.gz" || return 1
    fi
    if [ ! -d ${installer_name} ]; then
        echo "Unpacking ${installer_name}"
        tar -xf ${installer_name}.tar.gz || return 1
    fi

    # Libs

    for lib_url in ${LIBS[@]}; do
        lib_name=`basename ${lib_url}`
        if [ ! -f ${lib_name} ]; then
            echo "Downloading ${lib_name}"
            wget ${lib_url} || return 1
        fi
        if [ ! -d `basename ${lib_url} | cut -f 1 -d "."` ]; then
            echo "Unpacking ${lib_name}"
            tar -xf ${lib_name} || return 1
        fi
    done

    # Modules

    for module_url in ${MODULES[@]}; do
        module_name=$(basename $module_url)
        if [ -d ${module_name} ]; then
            cd ${module_name}
            git pull || return 1
            cd ..
        else
            git clone ${module_url} || return 1
        fi
    done
}


function build_nginx {
    cd $temp_dir/nginx-${NGINX_VERSION}

    cmd="./configure \
        --prefix=/usr/share/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --pid-path=/run/nginx.pid \
        --lock-path=/var/lock/nginx.lock \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --user=www-data \
        --group=www-data"

    cmd="$cmd \
        --with-pcre=$temp_dir/pcre-$PCRE_VERSION \
        --with-zlib=$temp_dir/zlib-$ZLIB_VERSION \
        --with-openssl=$temp_dir/openssl-$OPENSSL_VERSION \
        --with-ipv6 \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_addition_module \
        --with-http_xslt_module \
        --with-http_geoip_module \
        --with-http_sub_module \
        --with-http_stub_status_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --without-mail_pop3_module \
        --without-mail_smtp_module \
        --without-mail_imap_module"

    for module_url in ${MODULES[@]}; do
        module_name=$(basename ${module_url})
        cmd="$cmd --add-module=$temp_dir/${module_name}"
    done

    $cmd || return 1
    make && make install || return 1

    return 0
}

function post_install {
    echo "Running post-install configuration..."
    cd $base_dir

    html_dir="/var/www"
    default_dir="$html_dir/default"

    if [ ! -d $html_dir ]; then
        mkdir $html_dir
    fi

    if [ ! -d $default_dir ]; then
        mkdir $default_dir
        cp nginx/http.conf $default_dir/http.conf
        cp nginx/index.html $default_dir/index.html
    fi

    cd $base_dir
    cp nginx/nginx.conf /etc/nginx/nginx.conf || return 1
    cp $temp_dir/http.conf /etc/nginx/http.conf || return 1
    cp $temp_dir/rtmp.conf /etc/nginx/rtmp.conf || return 1
    touch /etc/nginx/cache.conf || return 1
    touch /etc/nginx/ssl.conf || return 1
    cp nginx/nginx.service /lib/systemd/system/nginx.service || return 1

    return 0
}

function add_security {
    dhparam_path="/etc/ssl/certs/dhparam.pem"
    if [ ! -f $dhparam_path ]; then
        openssl dhparam -out $dhparam_path 4096
    fi
    cp nginx/ssl.conf /etc/nginx/ssl.conf
}

function start_nginx {
    echo "(re)starting NGINX service..."
    systemctl daemon-reload
    systemctl enable nginx
    systemctl stop nginx
    systemctl start nginx || error_exit
}


##############################################################################
# TASKS

install_prerequisites || error_exit
download_all || error_exit
build_nginx || error_exit
post_install || error_exit
add_security || error_exit
start_nginx || error_exit

finished
