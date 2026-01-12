#!/bin/sh
# keepalived-gateway.sh. Gateway switcher.
#
# Copyright (c) 2025 Semyon A Mironov
#
# Authors: Semyon A Mironov <s.mironov@mgmsam.pro>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

is_diff ()
{
    case "${1:-}" in
        "${2:-}")
            return 1
    esac
}

is_empty ()
{
    case "${1:-}" in
        ?*)
            return 1
    esac
}

is_equal ()
{
    case "${1:-}" in
        "${2:-}")
            return 0
    esac
    return 1
}

is_not_empty ()
{
    case "${1:-}" in
        "")
            return 1
    esac
}

is_digit ()
{
    case "${1:-}" in
        *[!0123456789]*)
            return 1
    esac
}

is_dir ()
{
    test -d "${1:-}"
}

is_file ()
{
    test -f "${1:-}"
}

is_term ()
{
    test -t "${1:-1}" && IS_TERM=0 || IS_TERM=1
    return "$IS_TERM"
}

if is_not_empty "${KSH_VERSION:-}"
then
    PUTS=print
    puts ()
    {
        print "${PUTS_OPTIONS:--r}" -- "$*"
    }
else
    if type printf >/dev/null 2>&1
    then
        PUTS=printf
        puts ()
        {
            printf "${PUTS_OPTIONS:-%s\n}" "$*"
        }
    elif type echo >/dev/null 2>&1
    then
        PUTS=echo
        puts ()
        {
            echo "${PUTS_OPTIONS:-}" "$*"
        }
    else
        exit 1
    fi
fi

say ()
{
    SAY_RETURN=$?
    PUTS_OPTIONS=""
    while is_diff $# 0
    do
        case "${1:-}" in
            -n)
                is_equal "$PUTS" printf &&
                    PUTS_OPTIONS=%s ||
                    PUTS_OPTIONS=-n
            ;;
            *[!0123456789]* | "")
                break
            ;;
            *)
                SAY_RETURN=$1
            ;;
        esac
        shift
    done
    is_empty "$*" || {
        puts "${LOG_PREFIX:="${0##*/}"}:${1:+" $*"}"
        PUTS_OPTIONS=
    }
}

die ()
{
    say "$@" >&2
    exit "$SAY_RETURN"
}

set_state ()
{
    STATE="$1"
    LOG_PREFIX="kg [$1]"
}

check_base_dependencies ()
{
    RETURN=0
    for COMMAND in awk id ip ping printf sleep timeout
    do
        type "$COMMAND" >/dev/null 2>&1 || {
            say "dependency not found: '$COMMAND'" >&2
            RETURN="$SAY_RETURN"
        }
    done
    is_equal "$RETURN" 0 || die "$RETURN"

    if ping -4 -c 1 -w 1 127.0.0.1
    then
        PING4="ping -4"
    else
        PING4="ping"
    fi >/dev/null 2>&1

    if ping -6 -c 1 -w 1 ::1
    then
        PING6="ping -6"
    elif ping6 -c 1 -w 1 ::1
    then
        PING6="ping6"
    else
        PING6=""
    fi >/dev/null 2>&1

    if timeout -t 1 sleep 0
    then
        TIMEOUT="timeout -t"
    else
        TIMEOUT="timeout"
    fi >/dev/null 2>&1
}

check_permissions ()
{
    is_equal "$(id -u)" 0 ||
        die "error: must be run as root to manage routes and interfaces."
}

setup_core_env ()
{
    LF="
"
    CR="$(printf "\r")"
    TAB="$(printf "\t")"
    SPACE=" "
    POSIX_IFS="$SPACE$TAB$LF"
    IFS="$POSIX_IFS"
}

include_config ()
{
    CONFIG_FILE="/etc/keepalived-gateway.conf"
    is_file "$CONFIG_FILE" || die "error: no such config file: '$CONFIG_FILE'"
          . "$CONFIG_FILE" || die
}

parse_interval ()
{
    case "${2%[smhdwMy]}" in
        "" | *[!0123456789]*)
            return 1
        ;;
    esac
    case "$2" in
        *m) INTERVAL=$((${2%m} * 60)) ;;
        *h) INTERVAL=$((${2%h} * 3600)) ;;
        *d) INTERVAL=$((${2%d} * 86400)) ;;
        *w) INTERVAL=$((${2%w} * 604800)) ;;
        *M) INTERVAL=$((${2%M} * 2678400)) ;;
        *y) INTERVAL=$((${2%y} * 32140800)) ;;
         *) INTERVAL="${2%s}" ;;
    esac
}

format_duration ()
{
    S=${1:-0}

    D=$((S / 86400))
    S=$((S % 86400))
    H=$((S / 3600))
    S=$((S % 3600))
    M=$((S / 60))
    S=$((S % 60))

    RESULT=""
    test "$D" -gt 0 && RESULT="${D}d" || :
    test "$H" -gt 0 && RESULT="${RESULT:+"$RESULT, "}${H}h" || :
    test "$M" -gt 0 && RESULT="${RESULT:+"$RESULT, "}${M}m" || :
    test "$S" -gt 0 || is_empty "${RESULT:-}" && RESULT="${RESULT:+"$RESULT, "}${S}s"

    puts "$RESULT"
}

resolve_ips ()
{
    IPV4="$($TIMEOUT 5 $PING4 -c 3 "$1" 2>/dev/null | awk '
        /PING/ {
            split($0, a, /[()]/)
            print a[2]
            exit
        }
    ')" || :

    is_empty "${PING6:-}" ||
        IPV6="$($TIMEOUT 5 $PING6 -c 3 "$1" 2>/dev/null | awk '
            /PING/ {
                split($0, a, /[()]/)
                print a[2]
                exit
            }
        ')" || :

    is_empty "${IPV4:+"${IPV6:-}"}" && is_file "/etc/hosts" || return 0

    is_not_empty "${IPV4:-}" ||
        IPV4=$(awk '
            /^[ \t]*[^#]/ {
                for (i=2; i<=NF; i++) if ($i == "'"$1"'") {
                    if ($1 ~ /\./) {
                        print $1
                        exit
                    }
                }
            }
        ' /etc/hosts)

    is_not_empty "${IPV6:-}" ||
        IPV6=$(awk '
            /^[ \t]*[^#]/ {
                for (i=2; i<=NF; i++) if ($i == "'"$1"'") {
                    if ($1 ~ /:/) {
                        print $1
                        exit
                    }
                }
            }
        ' /etc/hosts)
}

parse_resource ()
{
    SCHEME=""
    USER_INFO=""
    USER=""
    PASS=""
    AUTHORITY=""
    MASK=""
    PORT=""
    RESOURCE=""
    IPV4=""
    IPV6=""

    HOST="$1"
    HOST="${HOST#"${HOST%%[![:blank:]]*}"}"
    HOST="${HOST%"${HOST##*[![:blank:]]}"}"
    case "$HOST" in
        *://*)
            SCHEME="${HOST%%://*}"
            HOST="${HOST#*://}"
            HOST="${HOST#"${HOST%%[!/]*}"}"
        ;;
    esac
    case "$HOST" in
        */*)
            AUTHORITY="${HOST%%/*}"
            RESOURCE="${HOST#*/}"
            case "$RESOURCE" in
                [0-9] | [0-9][0-9] | 1[0-2][0-8])
                    MASK="$RESOURCE"
                    RESOURCE=""
                ;;
            esac
        ;;
        *)
            AUTHORITY="$HOST"
            RESOURCE=""
        ;;
    esac
    case "$AUTHORITY" in
        *@*)
            USER_INFO="${AUTHORITY%@*}"
            AUTHORITY="${AUTHORITY##*@}"
            case "$USER_INFO" in
                *:*)
                    USER="${USER_INFO%%:*}"
                    PASS="${USER_INFO#*:}"
                ;;
                *)
                    USER="$USER_INFO"
                ;;
            esac
        ;;
    esac
    case "$AUTHORITY" in
        *]:*)
            HOST="${AUTHORITY%]*}"
            HOST="${HOST#[}"
            PORT="${AUTHORITY##*:}"
        ;;
        *]*)
            HOST="${AUTHORITY#[}"
            HOST="${HOST%]}"
        ;;
        *:*)
            case "${AUTHORITY%:*}" in
                *:*)
                    HOST="$AUTHORITY"
                ;;
                *)
                    HOST="${AUTHORITY%:*}"
                    PORT="${AUTHORITY##*:}"
                ;;
            esac
        ;;
        *)
            HOST="$AUTHORITY"
        ;;
    esac
    case "${HOST:-}" in
        "")
            return 1
        ;;
        *:*:*)
            IPV6="$HOST"
        ;;
        *[a-zA-Z]*)
            resolve_ips "$HOST"
        ;;
        *)
            IPV4="$HOST"
        ;;
    esac
    is_not_empty "${IPV4:-"${IPV6:-}"}"
}

is_valid_ip ()
{
    case "${1:-}" in
        *.*.*.*)
            IFS="."
            set -- $1
            IFS="$POSIX_IFS"
            is_equal $# 4 || return 1
            for OCTET
            do
                case "$OCTET" in
                    [0-9] | [0-9][0-9] | 1[0-9][0-9] | 2[0-4][0-9] | 25[0-5])
                    ;;
                    *)
                        return 1
                    ;;
                esac
            done
            FAMILY="inet"
        ;;
        *:*:*)
            case "$1" in
                *[!0-9a-fA-F:]*)
                    return 1
                ;;
            esac
            FAMILY="inet6"
        ;;
        *)
            return 1
        ;;
    esac
}

parse_gateway_entry ()
{
    IFS="@#="
    set -- $GATEWAY
    IFS="$POSIX_IFS"

    case "${1:-}" in
        *[.:]*)
            INTERFACE=
            GATEWAY="$1"
            METRIC="${2:-}"
        ;;
        *)
            INTERFACE="${1:-}"
            GATEWAY="${2:-}"
            METRIC="${3:-}"
        ;;
    esac

    is_valid_ip "${GATEWAY:-}" || {
        ERROR="gateway is not a valid IP address: '${GATEWAY:-}'"
        return 1
    }

    case "${INTERFACE:-}" in
        "")
            is_not_empty "${DEFAULT_INTERFACE:-}" || {
                ERROR="missing interface for gateway: '$GATEWAY'"
                return 1
            }
            INTERFACE="$DEFAULT_INTERFACE"
        ;;
    esac

    case "${METRIC:-}" in
        "")
            is_empty "${DEFAULT_METRIC:-}" || METRIC="$DEFAULT_METRIC"
        ;;
        *[!0123456789]*)
            ERROR="invalid route metric for gateway '$INTERFACE=$GATEWAY': '$METRIC'"
            return 1
        ;;
        0*)
            METRIC="${METRIC#"${METRIC%%[!0]*}"}"
        ;;
    esac
}

get_local_ip ()
{
    case "${1:-}" in
        -4 | 4 | inet)
            set -- "inet" ${2:-}
        ;;
        -6 | 6 | inet6)
            set -- "inet6" ${2:-}
        ;;
        *)
            set -- "inet6?" ${2:-}
        ;;
    esac
    ip address show | awk '
        $1 ~ /^'"$1"'$/ {
            if ("'"${2:-}"'" == "mask") {
                print $2
            } else {
                split($2, ip, "/")
                print ip[1]
            }
        }
    '
}

is_local_ip ()
{
    case "${1:-}" in
        "")
            return 1
        ;;
        */*)
            set -- "$1" "${2:-}" mask
        ;;
        *)
            set -- "$1" "${2:-}"
        ;;
    esac
    get_local_ip "${2:-}" ${3:-} | awk '
        $0 == "'"$1"'" {
            found = "yes"
            exit
        }
        END {
            if (found == "yes") exit 0
            exit 1
        }
    '
}

collect_interface ()
{
    case " ${IFACES:-} " in
        *" $INTERFACE "*)
        ;;
        *)
            IFACES="${IFACES:+"$IFACES "}$INTERFACE"
        ;;
    esac
}

collect_metrics_ipv4 ()
{
    case " ${METRICS_IPV4:-} " in
        *" ${METRIC:-0} "*)
        ;;
        *)
            METRICS_IPV4="${METRICS_IPV4:+"$METRICS_IPV4 "}${METRIC:-0}"
        ;;
    esac
}

collect_metrics_ipv6 ()
{
    case " ${METRICS_IPV6:-} " in
        *" ${METRIC:-0} "*)
        ;;
        *)
            METRICS_IPV6="${METRICS_IPV6:+"$METRICS_IPV6 "}${METRIC:-0}"
        ;;
    esac
}

optimize_gateways ()
{
    awk '
        BEGIN {
            FS = "="
        }

        {
            interface = $1
            gateway = $2
            metric = ($3 == "" ? 0 : $3)
            key = interface "=" gateway

            if (!(key in best_metric) || metric < best_metric[key]) {
                best_metric[key] = metric
                pos[key] = $0
            }

            if (!(key in seen)) {
                keys[++count] = key
                seen[key] = 1
            }
        }

        END {
            for (i = 2; i <= count; i++) {
                for (j = i; j > 1 && best_metric[keys[j-1]] > best_metric[keys[j]]; j--) {
                    tmp = keys[j]
                    keys[j] = keys[j-1]
                    keys[j-1] = tmp
                }
            }

            gateways = ""
            for (i = 1; i <= count; i++) {
                gateways = (gateways == "" ? "" : gateways " ") pos[keys[i]]
            }

            if (gateways != "") print gateways
        }
    ' <<EOF
$1
EOF
}

count_metrics ()
{
    set -- $1
    puts $#
}

parse_gateway ()
{
    IFACES=""
    GATEWAYS_IPV4=""
    GATEWAYS_IPV6=""
    METRICS_IPV4=""
    METRICS_IPV6=""
    RETURN=0
    for GATEWAY
    do
        parse_gateway_entry || {
            say "error: variable 'GATEWAYS': $ERROR"
            RETURN=2
            continue
        }

        if is_local_ip "$GATEWAY" "$FAMILY"
        then
            say "error: variable 'GATEWAYS': gateway is a local address on this host: '$GATEWAY'"
            RETURN=2
            continue
        fi

        case "$FAMILY" in
            inet)
                PROTO="IPv4"
                is_not_empty "${PING4:-}" && {

                    is_empty "${PING_HOST:-}" || is_not_empty "${PING_IPV4:-}" ||
                        say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but failed to resolve '$PROTO' address for PING_HOST: '$PING_HOST'"
                        say "WARNING: gateway '$GATEWAY' will be checked by its IP only (direct reachability), skipping internet check."

                    is_empty "${SPEEDTEST_HOST:-}" || is_not_empty "${SPEEDTEST_IPV4:-}" ||
                        say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but failed to resolve '$PROTO' address for SPEEDTEST_HOST: '$SPEEDTEST_HOST'"
                        say "WARNING: gateway '$GATEWAY' will be checked by its IP only (direct reachability), skipping internet check."

                    collect_metrics_ipv4
                    GATEWAYS_IPV4="${GATEWAYS_IPV4:+"$GATEWAYS_IPV4$LF"}$INTERFACE=$GATEWAY${METRIC:+"=$METRIC"}"
                }
            ;;
            inet6)
                PROTO="IPv6"
                is_not_empty "${PING6:-}" && {

                    is_empty "${PING_HOST:-}" || is_not_empty "${PING_IPV6:-}" ||
                        say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but failed to resolve '$PROTO' address for PING_HOST: '$PING_HOST'"
                        say "WARNING: gateway '$GATEWAY' will be checked by its IP only (direct reachability), skipping internet check."

                    is_empty "${SPEEDTEST_HOST:-}" || is_not_empty "${SPEEDTEST_IPV6:-}" ||
                        say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but failed to resolve '$PROTO' address for SPEEDTEST_HOST: '$SPEEDTEST_HOST'"
                        say "WARNING: gateway '$GATEWAY' will be checked by its IP only (direct reachability), skipping internet check."

                    collect_metrics_ipv6
                    GATEWAYS_IPV6="${GATEWAYS_IPV6:+"$GATEWAYS_IPV6$LF"}$INTERFACE=$GATEWAY${METRIC:+"=$METRIC"}"
                }
            ;;
        esac || {
            say "error: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but your system ping does not support: '$PROTO'"
            RETURN=2
            continue
        }

        collect_interface
    done >&2
    is_equal "$RETURN" 0 || die "$RETURN"
    GATEWAYS_IPV4="$(optimize_gateways "${GATEWAYS_IPV4:-}")"
    GATEWAYS_IPV6="$(optimize_gateways "${GATEWAYS_IPV6:-}")"
    TOTAL_METRICS_IPV4="$(count_metrics "${METRICS_IPV4:-}")"
    TOTAL_METRICS_IPV6="$(count_metrics "${METRICS_IPV6:-}")"
}

set_variables ()
{
    DEFAULT_INTERFACE="${INTERFACE:-}"

    is_digit "${METRIC:=0}" ||
        die 2 "error: variable 'METRIC': invalid route metric: '$METRIC'"
    METRIC="${METRIC#"${METRIC%%[!0]*}"}"
    DEFAULT_METRIC="${METRIC:-}"

    parse_interval CHECK_INTERVAL "${CHECK_INTERVAL:-60}" ||
        die 2 "error: variable 'CHECK_INTERVAL': must be an integer [s|m|h|d|w|M|y], but got: '$CHECK_INTERVAL'"
    CHECK_INTERVAL="$INTERVAL"
    HUMAN_INTERVAL="$(format_duration "$CHECK_INTERVAL")"

    is_empty "${PING_HOST:-}" || {

        parse_resource "$PING_HOST" ||
            die 2 "error: failed to resolve PING_HOST IP: '$PING_HOST'"

        is_empty "${IPV4:-}" || is_valid_ip "$IPV4" ||
            die 2 "error: variable 'PING_HOST': resolved to invalid IPv4 address: '$IPV4'"

        is_empty "${IPV6:-}" || is_valid_ip "$IPV6" ||
            die 2 "error: variable 'PING_HOST': resolved to invalid IPv6 address: '$IPV6'"

        # is_not_empty "${PING4:-}" ||
        #     die 2 "error: variable 'PING_HOST': resolved to IPv4, but IPv4 ping tool is missing"

        # is_not_empty "${PING6:-}" ||
        #     die 2 "error: variable 'PING_HOST': resolved to IPv6, but IPv6 ping tool is missing"

        PING_HOST="$HOST"
        PING_IPV4="${IPV4:-}"
        PING_IPV6="${IPV6:-}"
    }

    case "${SPEEDTEST:-}" in
        "" | 0 | [nN] | [nN][oO] | [oO][fF][fF] | [fF][aA][lL][sS][eE])
            SPEEDTEST=no
        ;;
        1 | [yY] | [yY][eE][sS] | [oO][nN] | [tT][rR][uU][eE])
            SPEEDTEST=yes
        ;;
        *)
            die 2 "error: variable 'SPEEDTEST': must be 'yes|no', but got: '$SPEEDTEST'"
        ;;
    esac

    if is_equal "$SPEEDTEST" "yes"
    then
        is_empty "${SPEEDTEST_HOST:-}" && SPEEDTEST=no || {

            case "${SPEEDTEST_SCOPE:-}" in
                "")
                ;;
                *[\'\"\;\|\<\>\`\$]*)
                    die 2 "error: variable 'SPEEDTEST_SCOPE': contains illegal shell characters: '$SPEEDTEST_SCOPE'"
                ;;
                /*)
                    SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE#/}"
                ;;
            esac

            parse_resource "$SPEEDTEST_HOST" ||
                die "error: failed to resolve SPEEDTEST_HOST IP: '$SPEEDTEST_HOST'"

            is_empty "${IPV4:-}" || is_valid_ip "$IPV4" ||
                die 2 "error: variable 'SPEEDTEST_HOST': resolved to invalid IPv4 address: '$IPV4'"

            is_empty "${IPV6:-}" || is_valid_ip "$IPV6" ||
                die 2 "error: variable 'SPEEDTEST_HOST': resolved to invalid IPv6 address: '$IPV6'"

            is_diff "$HOST" "${IPV6:-}" || HOST="[$HOST]"
            PING_IPV4="${IPV4:-}"
            PING_IPV6="${IPV6:-}"

            case "${PORT:-}" in
                "")
                ;;
                *[!0123456789]*)
                    die 2 "error: variable 'SPEEDTEST_HOST': invalid port in authority '$AUTHORITY'"
                ;;
                *)
                    HOST="$HOST:$PORT"
                ;;
            esac

            RESOURCE="${RESOURCE:+"/$RESOURCE"}${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
            SPEEDTEST_URL="${SCHEME:-http}://${USER_INFO:+$USER_INFO@}$HOST${RESOURCE:-}"
            SPEEDTEST_IPV4="${IPV4:-}"
            SPEEDTEST_IPV6="${IPV6:-}"
        }
    fi

    case "${ROLE:=single}" in
        master | master-advisor | single | slave)
        ;;
        *)
            die 2 "error: variable 'ROLE': must be 'master|master-advisor|single|slave', but got: '$ROLE'"
        ;;
    esac

    if is_empty "${VIRTUAL_IPADDRESS:-}"
    then
        is_empty "${VIRTUAL_PORT:-}" || is_digit "$VIRTUAL_PORT" ||
            die 2 "error: variable 'VIRTUAL_PORT': invalid port number: '$VIRTUAL_PORT'"

        is_equal "$ROLE" "single" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS' is empty: required for roles 'master|master-advisor|slave'"
    else
        parse_resource "$VIRTUAL_IPADDRESS" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': invalid virtual IP address: '$VIRTUAL_IPADDRESS'"

        is_equal "$HOST" "${IPV4:-}" || is_equal "$HOST" "${IPV6:-}" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': must be an IP address, but got: '$HOST'"

        is_valid_ip "${IPV4:-"$IPV6"}" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': resolved to invalid IP address: '${IPV4:-"$IPV6"}'"

        is_not_empty "${VIRTUAL_PORT:-}" ||
            die 2 "error: variable 'VIRTUAL_PORT' is required when 'VIRTUAL_IPADDRESS' is defined"

        is_port_free "$VIRTUAL_PORT" ||
            die 2 "error: cannot start sync server/client, port $VIRTUAL_PORT is busy"

        VIRTUAL_IPADDRESS="${IPV4:-"$IPV6"}${MASK:+"/$MASK"}"
        VIRTUAL_IPADDRESS_FAMILY="$FAMILY"
    fi

    case "${GATEWAYS:-}" in
        *[![:space:],]*)
            IFS="$IFS,"
            set -- $GATEWAYS
            IFS="$POSIX_IFS"
            parse_gateway "$@"
        ;;
        *)
            false
        ;;
    esac || die 2 "error: variable 'GATEWAYS': no valid gateways found: '${GATEWAYS:-}'"

    # detect_sync_transport
    # GATEWAYS_STATE_FILE="/tmp/kg/gateways.state"
}

check_functional_dependencies ()
{
    RETURN=0
    MISSING_DEPS=""

    is_equal "$SPEEDTEST" "no" || {

        for COMMAND in date wc
        do
            type "$COMMAND" >/dev/null 2>&1 || {
                RETURN=$?
                MISSING_DEPS="${MISSING_DEPS:+"$MISSING_DEPS|"}$COMMAND"
            }
        done

        is_empty "${MISSING_DEPS:-}" ||
            say "error: speedtest enabled, but dependency not found: '$MISSING_DEPS'" >&2
    }
    is_equal "$RETURN" 0 || die "$RETURN"
}

is_interface ()
{
    ip link show ${1:-} >/dev/null 2>&1
}

is_port_free ()
{
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '
        $2 ~ /:'"$(printf "%04X" "$1")"'$/ {
            found = "yes"
            exit
        }
        END {
            if (found == "yes") exit 1
            exit 0
        }
    '
}

is_netcat_server_capable ()
{
    case "${NETCAT_STAT:-}" in
        *not_a_port*)
            case "$NETCAT_STAT" in
                *[uU]sage*)
                ;;
                *)
                    return
                ;;
            esac
        ;;
    esac
    return 1
}

detect_netcat_server ()
{
    NETCAT=""
    NETCAT_STAT="$($TIMEOUT 3 nc -l -p not_a_port 2>&1 || :)"
    if is_netcat_server_capable
    then
        NETCAT="nc -l -p"
        return
    fi

    NETCAT_STAT="$($TIMEOUT 3 nc -l not_a_port 2>&1 || :)"
    if is_netcat_server_capable
    then
        NETCAT="nc -l"
        return
    fi

    return 1
}

detect_sync_transport ()
{
    RETURN=0

    GATEWAYS_SERVER_DISPATCHER=""
    GATEWAYS_CLIENT_DISPATCHER=""

    for COMMAND in uhttpd telnetd nc
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            is_diff "$COMMAND" "nc" || detect_netcat_server || break
            GATEWAYS_SERVER_DISPATCHER="serve_gateways_$COMMAND"
            break
        fi
    done

    is_not_empty "${GATEWAYS_SERVER_DISPATCHER:-}" ||
        die "error: no supported sync server found (uhttpd/telnetd/nc required)"

    for COMMAND in wget curl nc
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            GATEWAYS_CLIENT_DISPATCHER="fetch_gateways_$COMMAND"
            break
        fi
    done

    is_not_empty "${GATEWAYS_CLIENT_DISPATCHER:-}" ||
        die "error: no supported sync client found (wget/curl/nc required)"
}

set_variables ()
{
            case "${DOWNLOAD_CMD:-}" in
                "")
                    die 1 "error: speedtest requires 'wget' or 'curl', but neither was found."
                ;;
                wget)
                    DOWNLOAD_OPTIONS="-O -"
                    case "${SCHEME:-}" in
                        https)
                            case "$(wget --help 2>&1)" in
                                *"--no-check-certificate"*)
                                    DOWNLOAD_OPTIONS="--no-check-certificate $DOWNLOAD_OPTIONS"
                                ;;
                                *)
                                    say "WARNING: HTTPS speedtest requested, but wget lacks SSL support. Switching to HTTP."
                                    SCHEME=http
                                ;;
                            esac
                        ;;
                        "")
                            SCHEME=http
                        ;;
                    esac
                ;;
                curl)
                    DOWNLOAD_OPTIONS="-o -"
                    case "${SCHEME:-}" in
                        https)
                            case "$(curl --help all 2>&1 || curl --help 2>&1)" in
                                *"-k"* | *"--insecure"*)
                                    DOWNLOAD_OPTIONS="-k $DOWNLOAD_OPTIONS"
                                ;;
                                *)
                                    say "WARNING: HTTPS speedtest requested, but curl lacks SSL support. Switching to HTTP."
                                    SCHEME=http
                                ;;
                            esac
                        ;;
                        "")
                            SCHEME=http
                        ;;
                    esac
                ;;
            esac
}

run_ip ()
{
    EXEC="$IP_CMD $@"
    $EXEC && echo "$EXEC" >&2
}

remove_route ()
{
    while read ROUTE
    do
        run_ip route del "$ROUTE" || RETURN=$?
    done <<EOF
$REMOVE_ROUTES
EOF
}

remove_test_route ()
{
    IP_CMD="ip -4" REMOVE_ROUTES=""
    for IP in ${PING_IPV4:-} ${SPEEDTEST_IPV4:-}
    do
        ROUTE="$(run_ip route show "$IP" 2>/dev/null)"
        is_empty "${ROUTE:-}" ||
            REMOVE_ROUTES="${REMOVE_ROUTES:+"$REMOVE_ROUTES$LF"}$ROUTE"
    done
    is_empty "${REMOVE_ROUTES:-}" || {
        say "removing test IPv4 routes from the system..."
        remove_route
        REMOVE_ROUTES=""
    }

    IP_CMD="ip -6"
    for IP in ${PING_IPV6:-} ${SPEEDTEST_IPV6:-}
    do
        ROUTE="$(run_ip route show "$IP" 2>/dev/null)"
        is_empty "${ROUTE:-}" ||
            REMOVE_ROUTES="${REMOVE_ROUTES:+"$REMOVE_ROUTES$LF"}$ROUTE"
    done
    is_empty "${REMOVE_ROUTES:-}" || {
        say "removing test IPv6 routes from the system..."
        remove_route
        REMOVE_ROUTES=""
    }

    return "${RETURN:-0}"
}

clean_and_exit ()
{
    EXIT="${1:-$?}"
    echo
    trap - 0
    remove_test_route || RETURN=$?
    is_empty "${GATEWAY_SERVER_PID:-}" || kill $GATEWAY_SERVER_PID 2>/dev/null
    is_equal "${EXIT:-}" 0 && exit "$RETURN" || exit "$EXIT"
}

format_route ()
{
    IFS="="
    read INTERFACE GATEWAY_IP METRIC <<EOF
$GATEWAY
EOF
    IFS="$POSIX_IFS"

    case "$GATEWAY_IP" in
        *:*)
            IP_CMD="ip -6"
            SPEEDTEST_IP="${SPEEDTEST_IPV6:-}"
            PING_IP="${PING_IPV6:-}"
            PING="${PING6:-}"
            DOWNLOAD_INET="-6"
        ;;
        *)
            IP_CMD="ip -4"
            SPEEDTEST_IP="${SPEEDTEST_IPV4:-}"
            PING_IP="${PING_IPV4:-}"
            PING="${PING4:-}"
            DOWNLOAD_INET="-4"
        ;;
    esac

    ROUTE="default via $GATEWAY_IP dev $INTERFACE${METRIC:+" metric $METRIC"}"
    SPEEDTEST_ROUTE="${SPEEDTEST_IP:-} via $GATEWAY_IP dev $INTERFACE"
    PING_ROUTE="${PING_IP:-} via $GATEWAY_IP dev $INTERFACE"
}

is_metric_alive ()
{
    case " $ALIVE_METRICS " in
        *" ${METRIC:-0} "*)
            return 0
        ;;
    esac
    return 1
}

is_failed_metric ()
{
    is_metric_alive && return 1 || return 0
}

collect_gateway ()
{
    DEFAULT_GATEWAYS="${DEFAULT_GATEWAYS:+"$DEFAULT_GATEWAYS "}$BEST_GATEWAY"
    BEST_GATEWAY=""
}

collect_route ()
{
    DEFAULT_ROUTES="${DEFAULT_ROUTES:+"$DEFAULT_ROUTES$LF"}$BEST_ROUTE"
    BEST_ROUTE=""
}

is_vrrp_master ()
{
    is_local_ip "$VIRTUAL_IPADDRESS" "$VIRTUAL_IPADDRESS_FAMILY" >/dev/null 2>&1
}

get_time ()
{
    date "+%s"
}

bit2Human ()
{
    BIT="${1:-0}" REMAINS="" SIZE=1
    while test "$BIT" -ge 1000
    do
        REMAINS=$(( (BIT % 1000) / 10 ))
        REMAINS=$(printf ".%02d" "$REMAINS")
        BIT=$((BIT / 1000))
        SIZE=$((SIZE + 1))
    done
    set -- bit Kbit Mbit Gbit Tbit Ebit Pbit Zbit Ybit
    shift $((SIZE - 1))
    UNIT="$1"
    echo "$BIT${REMAINS:-} $UNIT"
}

speedtest ()
{
    START_SPEEDTEST="$(get_time)"
    BYTE="$(
        2>/dev/null $TIMEOUT "${SPEEDTEST_TIMEOUT:=15}" \
        $DOWNLOAD_CMD $DOWNLOAD_INET $DOWNLOAD_OPTIONS "$SPEEDTEST_URL" | wc -c
    )"
    END_SPEEDTEST="$(get_time)"
    BYTE=$(( ${BYTE:-0} + 0 ))
    DURATION=$((END_SPEEDTEST - START_SPEEDTEST))
    test "$DURATION" -gt 0 || DURATION=1
    test "$BYTE" -gt 1024 && BIT=$(( (BYTE * 8) / DURATION ))
}

check_ping ()
{
    $TIMEOUT "${PING_TIMEOUT:=3}" $PING -c "${PING_COUNT:=3}" "$@" >/dev/null 2>&1
}

evaluate_speed ()
{
    say "measuring speed to host: '$SPEEDTEST_HOST' using route '$SPEEDTEST_ROUTE'"

    run_ip route replace "$SPEEDTEST_ROUTE"
    if speedtest "$SPEEDTEST_URL"
    then
        test "$BEST_SPEED" -ge "$BIT" || {
            BEST_GATEWAY="$GATEWAY"
            BEST_ROUTE="$ROUTE"
            BEST_SPEED="$BIT"
        }
        run_ip route del "$SPEEDTEST_ROUTE"
        say "measured speed: $(bit2Human "$BIT")/s for gateway: '$GATEWAY_IP' on '$INTERFACE'"
    else
        run_ip route del "$SPEEDTEST_ROUTE"
        say "failed to measure speed from '$SPEEDTEST_HOST' using route '$SPEEDTEST_ROUTE'"
        return 1
    fi
}

evaluate_host ()
{
    say "probing host address: '$PING_HOST' using route '$PING_ROUTE'"

    run_ip route replace "$PING_ROUTE"
    check_ping -I "$INTERFACE" "$PING_IP" && {
        run_ip route del "$PING_ROUTE"
        say "reachable host address: '$PING_HOST' using route '$PING_ROUTE'"
        BEST_GATEWAY="$GATEWAY"
        BEST_ROUTE="$ROUTE"
    } || {
        run_ip route del "$PING_ROUTE"
        say "unreachable host address: '$PING_HOST' using route '$PING_ROUTE'"
        check_ping -I "$INTERFACE" "$GATEWAY_IP" &&
            say "reachable gateway address: '$GATEWAY_IP' on '$INTERFACE'" ||
            say "unreachable gateway address: '$GATEWAY_IP' on '$INTERFACE'"
    }
}

evaluate_gateway ()
{
    say "probing gateway address: '$GATEWAY_IP' on '$INTERFACE'"

    check_ping -I "$INTERFACE" "$GATEWAY_IP" && {
        say "reachable gateway address: '$GATEWAY_IP' on '$INTERFACE'"
        BEST_GATEWAY="$GATEWAY"
        BEST_ROUTE="$ROUTE"
    } || say "unreachable gateway address: '$GATEWAY_IP' on '$INTERFACE'"
}

add_route ()
{
    is_not_empty "${DEFAULT_ROUTES:-}" || return
    echo
    say "applying optimized routes to the system..."
    while read ROUTE
    do
        run_ip route replace "$ROUTE" || :
    done <<EOF
$DEFAULT_ROUTES
EOF
}

get_current_routes ()
{
    CURRENT_ROUTES=
    for INTERFACE in $IFACES
    do
        if ROUTES="$(ip route show | awk '
            $1 == "default" {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && $(i+1) == "'"$INTERFACE"'") {
                        print $0
                        found = "yes"
                        break
                    }
                }
            }
            END {
                if (found == "yes") exit 0
                exit 1
            }
        ')"
        then
            while read ROUTE
            do
                ROUTE=$(echo $ROUTE)
                CURRENT_ROUTES="${CURRENT_ROUTES:+"$CURRENT_ROUTES$LF"}$ROUTE"
            done <<EOF
$ROUTES
EOF
        fi
    done 2>/dev/null
    is_not_empty "${CURRENT_ROUTES:-}" || return
}

get_obsolete_routes ()
{
    REMOVE_ROUTES="$(printf "%s\n\n%s" "$DEFAULT_ROUTES" "$CURRENT_ROUTES" | awk '
        BEGIN {
            found_separator = "no"
        }

        $0 == "" && found_separator == "no" {
            found_separator = "yes"
            next
        }

        found_separator == "no" {
            wanted[$0] = "yes"
            next
        }

        found_separator == "yes" && !($0 in wanted) {
            print $0
        }
    ')"
    is_not_empty "${REMOVE_ROUTES:-}" || return
}

remove_obsolete_routes ()
{
    echo
    say "removing obsolete routes from the system..."
    remove_route
    return "${RETURN:-0}"
}

check_gateways ()
{
    is_not_empty "${DEFAULT_GATEWAYS:-}" || return

    ALIVE_COUNT=0
    ALIVE_GATEWAYS=""
    ALIVE_METRICS=""
    ALIVE_ROUTES=""
    DEAD_ROUTES=""

    for GATEWAY in $DEFAULT_GATEWAYS
    do
        format_route
        echo
        say "checking active route: '$ROUTE'"

        is_interface "$INTERFACE" || {
            say "interface '$INTERFACE' is not available for gateway '$GATEWAY_IP'"
            DEAD_ROUTES="${DEAD_ROUTES:+"$DEAD_ROUTES$LF"}$ROUTE"
            continue
        }

        if is_not_empty "${PING_HOST:-}"
        then
            run_ip route replace "$PING_ROUTE"
            check_ping -I "$INTERFACE" "$PING_IP" || {
                run_ip route del "$PING_ROUTE"
                say "host '$PING_HOST' is unreachable via route '$ROUTE'"
                DEAD_ROUTES="${DEAD_ROUTES:+"$DEAD_ROUTES$LF"}$ROUTE"
                continue
            }
            run_ip route del "$PING_ROUTE"
        else
            check_ping -I "$INTERFACE" "$GATEWAY_IP" || {
                say "gateway '$GATEWAY_IP' is unreachable on interface '$INTERFACE'"
                DEAD_ROUTES="${DEAD_ROUTES:+"$DEAD_ROUTES$LF"}$ROUTE"
                continue
            }
        fi
        say "alive active route: '$ROUTE'"

        ALIVE_COUNT="$((ALIVE_COUNT + 1))"
        ALIVE_GATEWAYS="${ALIVE_GATEWAYS:+"$ALIVE_GATEWAYS "}$GATEWAY"
        ALIVE_METRICS="${ALIVE_METRICS:+"$ALIVE_METRICS "}${METRIC:-0}"
        ALIVE_ROUTES="${ALIVE_ROUTES:+"$ALIVE_ROUTES$LF"}$ROUTE"
    done

    is_equal "$ALIVE_COUNT" "$TOTAL_METRICS" || {
        is_empty "${DEAD_ROUTES:-}" || {
            say "dead routes detected:"
            echo "$DEAD_ROUTES"
        }
        return 1
    }
}

refresh_routing_table ()
{
    add_route &&
    get_current_routes &&
    get_obsolete_routes &&
    remove_obsolete_routes || :
}

reconcile_gateways ()
{
    DEFAULT_GATEWAYS="${ALIVE_GATEWAYS:-}"
    DEFAULT_ROUTES="${ALIVE_ROUTES:-}"
    CURRENT_METRIC=""
    BEST_GATEWAY=""
    BEST_ROUTE=""
    BEST_SPEED=0

    while :
    do

        for GATEWAY in $GATEWAYS
        do
            format_route
            echo
            say "testing gateway: '$GATEWAY_IP' on '$INTERFACE' with metric: '${METRIC:-0}'"

            is_equal "${CURRENT_METRIC:-}" "${METRIC:-0}" || {
                is_empty "${BEST_ROUTE:-}" || {
                    collect_gateway
                    collect_route
                    BEST_SPEED=0
                }
                is_empty "${ALIVE_METRICS:-}" || is_failed_metric || {
                    say "skipping gateway: active route already found with metric '${METRIC:-0}'"
                    continue
                }
                CURRENT_METRIC="${METRIC:-0}"
            }

            is_interface "$INTERFACE" || {
                say "interface not found or down: '$INTERFACE'"
                continue
            }

            is_equal "$SPEEDTEST" yes && evaluate_speed ||
            if is_empty "${BEST_ROUTE:-}"
            then
                if is_not_empty "${PING_HOST:-}"
                then
                    evaluate_host
                else
                    evaluate_gateway
                fi
            fi
        done

        is_empty "${BEST_ROUTE:-}" || {
            collect_gateway
            collect_route
            break
        }

        is_empty "${DEFAULT_GATEWAYS:-}" || break

        echo
        say "WARNING: no alive gateways found, retrying in 1s..."

        # In 'slave' mode, if 'master's web is unreachable and 'slave-single' is active:
        # Instead of waiting indefinitely for a live route,
        # proceed to check master availability.
        is_diff "$STATE" "slave-single" || return

        sleep 1
    done

    is_equal "$STATE" "master-advisor" || refresh_routing_table
}

sync_gateways ()
{
    is_diff "${FETCHED_GATEWAYS:-}" "${DEFAULT_GATEWAYS:-}" || {
        say "local routing state is already up to date"
        refresh_routing_table
        return
    }
    say "applying new gateway configuration from master (${VIRTUAL_IPADDRESS%/*})"

    for GATEWAY in $FETCHED_GATEWAYS
    do
        format_route
        echo
        say "configuring gateway: '$GATEWAY_IP' on '$INTERFACE' with metric: '${METRIC:-0}'"
        is_interface "$INTERFACE" || {
            say "interface '$INTERFACE' is not available for gateway '$GATEWAY_IP'"
            continue
        }
        BEST_GATEWAY="$GATEWAY"
        BEST_ROUTE="$ROUTE"
        collect_gateway
        collect_route
    done

    refresh_routing_table
}

update_gateways_state ()
{
    is_dir "${GATEWAYS_STATE_FILE%/*}" ||
    ERROR="$(2>&1 mkdir -p "${GATEWAYS_STATE_FILE%/*}")" || {
        say "error: $ERROR"
        return 1
    } >&2
    echo "$DEFAULT_GATEWAYS" > "$GATEWAYS_STATE_FILE.tmp" &&
    mv "$GATEWAYS_STATE_FILE.tmp" "$GATEWAYS_STATE_FILE"  || {
        say "error: failed to update gateways state file: '$GATEWAYS_STATE_FILE'"
        return 1
    } >&2
}

is_process_alive ()
{
    is_not_empty "${1:-}" &&
    is_dir "/proc/$1"
}

serve_gateways_nc ()
{
    trap '
        trap - 0
        kill $NETCAT_PID 2>/dev/null
        exit
    ' 0 1 2 15

    while :
    do
        $NETCAT "$VIRTUAL_PORT" <<EOF >/dev/null 2>&1 &
HTTP/1.1 200 OK$CR
Content-Type: text/plain$CR
Content-Length: ${#DEFAULT_GATEWAYS}$CR
Connection: close$CR
$CR
$DEFAULT_GATEWAYS
EOF
        NETCAT_PID=$!
        wait $NETCAT_PID 2>/dev/null
    done
}

serve_gateways_uhttpd ()
{
    uhttpd -p "$VIRTUAL_PORT" -h "${GATEWAYS_STATE_FILE%/*}" -Rf
}

serve_gateways_telnetd ()
{
    telnetd -p "$VIRTUAL_PORT" -f "$GATEWAYS_STATE_FILE" -l : -KF
}

share_gateways ()
{
    is_process_alive "${GATEWAY_SERVER_PID:-}" || {
        is_port_free "$VIRTUAL_PORT" || {
            say "error: cannot start sync server, port $VIRTUAL_PORT is busy"
            return
        } >&2

        $GATEWAYS_SERVER_DISPATCHER 2>&1 &
        GATEWAY_SERVER_PID=$!
        sleep 1

        if is_process_alive "$GATEWAY_SERVER_PID"
        then
            say "gateway server successfully started on port $VIRTUAL_PORT"
        else
            GATEWAY_SERVER_PID=""
            say "error: gateway server failed to start (check system logs)"
        fi >&2
    }
}

stop_share_gateways ()
{
    if is_process_alive "${GATEWAY_SERVER_PID:-}"
    then
        kill "$GATEWAY_SERVER_PID" 2>/dev/null || :
        GATEWAY_SERVER_PID=""
        say "gateway server stopped"
    fi
}

fetch_gateways_wget ()
{
    FETCHED_GATEWAYS="$(
        2>&1 wget -O - "http://${VIRTUAL_IPADDRESS%/*}:$VIRTUAL_PORT/${GATEWAYS_STATE_FILE##*/}"
    )"
}

fetch_gateways_curl ()
{
    FETCHED_GATEWAYS="$(
        2>&1 curl -o - "http://${VIRTUAL_IPADDRESS%/*}:$VIRTUAL_PORT/${GATEWAYS_STATE_FILE##*/}"
    )"
}

fetch_gateways_nc ()
{
    FETCHED_GATEWAYS="$(
        2>&1 $TIMEOUT 1 nc "${VIRTUAL_IPADDRESS%/*}" "$VIRTUAL_PORT" <<EOF
GET /${GATEWAYS_STATE_FILE##*/} HTTP/1.0$CR
Host: ${VIRTUAL_IPADDRESS%/*}$CR
Connection: close$CR
$CR
EOF
    )" ||
    case $? in
        124)
            return 0
        ;;
        *)
            return $?
        ;;
    esac
}

fetch_gateways ()
{
    COUNT=0
    RETRIES=3
    SUCCESS=1
    echo
    say "attempting to fetch gateway state from master (${VIRTUAL_IPADDRESS%/*})..."
    while is_diff $COUNT $RETRIES
    do
        "$GATEWAYS_CLIENT_DISPATCHER" && {
            SUCCESS=0
            break
        } || COUNT=$((COUNT + 1))
    done

    is_equal $SUCCESS 0 || {
        say "error: ${FETCHED_GATEWAYS:-}"
        FETCHED_GATEWAYS=""
        return 1
    } >&2

    FETCHED_GATEWAYS="$(awk '
        /=/ {
            gsub(/\r/, "")
            print
            exit
        }
    ' <<EOF
$FETCHED_GATEWAYS
EOF
    )"

    is_not_empty "${FETCHED_GATEWAYS:-}" || {
        say "error: received empty or invalid gateway state from master (${VIRTUAL_IPADDRESS%/*})"
        return 1
    } >&2
    say "received remote state from master (${VIRTUAL_IPADDRESS%/*}): [$FETCHED_GATEWAYS]"
}

main ()
{
    say "switching to init mode"
    set_state "init"
    check_base_dependencies
    check_permissions
    setup_core_env
    say "loading configuration..."
    include_config
    set_variables
    check_functional_dependencies

    remove_test_route || die
    say "initialization complete, system ready"

    trap 'clean_and_exit' 0      # EXIT (0) : Naturally occurring script termination.
    trap 'clean_and_exit 129' 1  # HUP (1)  : Hangup detected on controlling terminal or death of controlling process.
    trap 'clean_and_exit 130' 2  # INT (2)  : Program interrupt (usually Ctrl+C). Exit code 130 (128 + 2).
    trap 'clean_and_exit 143' 15 # TERM (15): Termination signal (default for 'kill' command). Exit code 143 (128 + 15).

    ALIVE_GATEWAYS=""
    ALIVE_METRICS=""
    ALIVE_ROUTES=""
    GATEWAY_SERVER_PID=""

    if is_empty "${VIRTUAL_IPADDRESS:-}"
    then
        echo
        say "switching to single mode"
        set_state "single"
        while :
        do
            check_gateways || reconcile_gateways
            say "next check cycle in: '$HUMAN_INTERVAL'"
            sleep "$CHECK_INTERVAL"
        done
    else
        while :
        do
            if is_vrrp_master
            then
                case "$STATE" in
                    "master" | "master-advisor")
                    ;;
                    *)
                        echo
                        say "virtual IP detected on this host: '$VIRTUAL_IPADDRESS'"
                        say "switching to $ROLE mode"
                        set_state "$ROLE"
                    ;;
                esac
                check_gateways || {
                    reconcile_gateways
                    update_gateways_state
                } && share_gateways || stop_share_gateways
            else
                case "$STATE" in
                    "slave" | "master" | "master-advisor" | "init")
                        case "$STATE" in
                            "master" | "master-advisor")
                                stop_share_gateways
                            ;;
                        esac
                        is_equal "$STATE" "slave" || {
                            echo
                            say "virtual IP not found on this host: '$VIRTUAL_IPADDRESS'"
                            say "switching to slave mode"
                            set_state "slave"
                        }
                        fetch_gateways && sync_gateways || {
                            say "master unreachable, switching to slave-single mode"
                            set_state "slave-single"
                            false
                        }
                    ;;
                    "slave-single")
                        fetch_gateways && {
                            echo
                            say "master reachable, switching back to slave mode"
                            set_state "slave"
                            sync_gateways
                        }
                    ;;
                esac || {
                    check_gateways || reconcile_gateways || {
                        sleep 1
                        continue
                    }
                }
            fi
            say "next check cycle in: '$HUMAN_INTERVAL'"
            sleep "$CHECK_INTERVAL"
        done
    fi
}

main
