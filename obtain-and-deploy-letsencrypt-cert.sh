#!/bin/bash
# author: Vojtech Myslivec <vojtech@xmyslivec.cz>
# GPLv2 licence
set -o nounset

SCRIPTNAME=${0##*/}

USAGE="USAGE
    $SCRIPTNAME -h | --help | help
    $SCRIPTNAME

    This script is used for extend the already-deployed apache2
    certificate issued by Let's Encrypt certification authority.

    The script will stop the apache for a while and restart it
    once the certificate is extended and deployed. If the
    obtained certificate isn't valid after all, apache2 will start
    with the old certificate unchanged.

    Suitable to be run via cron.

    Depends on:
        apache2
        letsencrypt-auto utility
        openssl"

# --------------------------------------------------------------------
# -- Variables -------------------------------------------------------
# --------------------------------------------------------------------
# should be in config file o_O

# letsencrypt tool
letsencrypt="/opt/letsencrypt/letsencrypt-auto"
# the name of file which letsencrypt will generate
letsencript_issued_cert_file="0000_cert.pem"
# intermediate CA
letsencript_issued_intermediate_CA_file="0000_chain.pem"
# root CA
root_CA_file="/opt/letsencrypt-apache/DSTRootCAX3.pem"

# apache init script / service name
apache_service="apache2"

# this is the server certificate with CA together -- alias chain
ssl_dir="/etc/ssl/private"
 apache_cert="${ssl_dir}/cert_rsa_vyvoj.meteocentrum.cz.pem"
apache_chain="${ssl_dir}/chain_rsa_vyvoj.meteocentrum.cz.pem"
  apache_key="${ssl_dir}/key_rsa_vyvoj.meteocentrum.cz.pem"

# common name in the certificate
CN1="example.com"
CN2="www.example.com"
CN3="dev.example.com"
# subject in request -- does not matter for letsencrypt but must be there for openssl
cert_subject="/"
# openssl config skeleton
#  it is important to have an alt_names section there!
openssl_config="
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]
[ v3_req ]

basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $CN1
DNS.2 = $CN2
DNS.3 = $CN3
"

# --------------------------------------------------------------------
# -- Functions -------------------------------------------------------
# --------------------------------------------------------------------
# common message format, called by error, warning, information, ...
#  $1 - level
#  $2 - message
message() {
    echo "$SCRIPTNAME[$1]: $2" >&2
}

error() {
    message "err" "$*"
}

warning() {
    message "warn" "$*"
}

information() {
    message "info" "$*"
}

readable_file() {
    [ -f "$1" -a -r "$1" ]
}

executable_file() {
    [ -f "$1" -a -x "$1" ]
}

cleanup() {
    [ -d "$temp_dir" ] && {
        rm -rf "$temp_dir" || {
            warning "Cannot remove temporary directory '$temp_dir'. You should check it for private data."
        }
    }
}

# just a kindly message how to fix stopped apache
fix_apache_message() {
    echo "        You must probably fix it with:
        'service $apache_service restart' command or something." >&2
}

# this function will start the apache
start_apache() {
    service "$apache_service" start > /dev/null || {
        error "There were some error during starting the apache."
        fix_apache_message
        cleanup
        exit 3
    }
}

# and another one to stop it
stop_apache() {
    service "$apache_service" stop > /dev/null || {
        error "There were some error during stopping the apache."
        fix_apache_message
        cleanup
        exit 3
    }
}

# and another one to reload it
reload_apache() {
    service "$apache_service" reload > /dev/null || {
        error "There were some error during reloading the apache."
        fix_apache_message
        cleanup
        exit 5
    }
}


# --------------------------------------------------------------------
# -- Usage -----------------------------------------------------------
# --------------------------------------------------------------------

# HELP?
[ $# -eq 1 ] && {
    if [ "$1" == "-h" -o "$1" == "--help" -o "$1" == "help" ]; then
        echo "$USAGE"
        exit 0
    fi
}

[ $# -eq 0 ] || {
    echo "$USAGE" >&2
    exit 1
}

# --------------------------------------------------------------------
# -- Tests -----------------------------------------------------------
# --------------------------------------------------------------------

executable_file "$letsencrypt" || {
    error "Letsencrypt tool '$letsencrypt' isn't executable file."
    exit 2
}

readable_file "$apache_key" || {
    error "Private key '$apache_key' isn't readable file."
    exit 2
}

readable_file "$root_CA_file" || {
    error "The root CA certificate '$root_CA_file' isn't readable file."
    exit 2
}

# --------------------------------------------------------------------
# -- Temporary files -------------------------------------------------
# --------------------------------------------------------------------

temp_dir=$( mktemp -d ) || {
    error "Cannot create temporary directory."
    exit 2
}
openssl_config_file="${temp_dir}/openssl.cnf"
request_file="${temp_dir}/request.pem"

# create the openssl config file
echo "$openssl_config" > "$openssl_config_file"

# --------------------------------------------------------------------
# -- Obtaining the certificate ---------------------------------------
# --------------------------------------------------------------------

# create the certificate signing request [crs]
openssl req -new -nodes -sha256 -outform der \
    -config "$openssl_config_file" \
    -subj "$cert_subject" \
    -key "$apache_key" \
    -out "$request_file" || {
    error "Cannot create the certificate signing request."
    cleanup
    exit 3
}

# release the 443 port -- stop the apache
stop_apache

# ----------------------------------------------------------
# letsencrypt utility stores the obtained certificates in PWD,
# so we must cd in the temp directory
cd "$temp_dir"

"$letsencrypt" certonly --csr "$request_file" --standalone > /dev/null || {
    error "The certificate cannot be obtained with '$letsencrypt' tool."
    start_apache
    cleanup
    exit 4
}

# cd back -- which is not really neccessarry
cd - > /dev/null
# ----------------------------------------------------------

# start the apache again
start_apache


# --------------------------------------------------------------------
# -- Deploying the certificate ---------------------------------------
# --------------------------------------------------------------------

cert_file="${temp_dir}/${letsencript_issued_cert_file}"
intermediate_CA_file="${temp_dir}/${letsencript_issued_intermediate_CA_file}"
chain_file="${temp_dir}/chain.pem"

readable_file "$cert_file" || {
    error "The issued certificate file '$cert_file' isn't readable file. Maybe it was created with different name?"
    cleanup
    exit 4
}

readable_file "$intermediate_CA_file" || {
    error "The issued intermediate CA file '$intermediate_CA_file' isn't readable file. Maybe it was created with different name?"
    cleanup
    exit 4
}

# # create one CA chain file
# cat "$root_CA_file" "$intermediate_CA_file" > "$chain_file"
# # create one cert with  chain file
# cat "$cert_file" "$intermediate_CA_file" > "$chain_file"
# CA file for apache will be just the intermediate cert file
cp "$intermediate_CA_file" "$chain_file"

# install the certificate to apache -- simply copy the file on the place
# keep one last certificate in ssl_dir
mv "$apache_cert" "$apache_cert-bak" || {
    error "Cannot backup (move) the old certificate '$apache_cert'."
    exit 4
}
# replace it with the new issued certificate
mv "$cert_file" "$apache_cert" || {
    error "Cannot move new certificate to a file '$apache_cert'."
    exit 4
}
# keep one last chain in ssl_dir
mv "$apache_chain" "$apache_chain-bak" || {
    error "Cannot backup (move) the old certificate chain '$apache_chain'."
    exit 4
}
# replace it with the new issued certificate
mv "$chain_file" "$apache_chain" || {
    error "Cannot move new certificate chain to a file '$apache_cert'."
    exit 4
}


# finally, reload the apache to load new certificate
reload_apache


# --------------------------------------------------------------------
# -- Cleanup ---------------------------------------------------------
# --------------------------------------------------------------------

cleanup

