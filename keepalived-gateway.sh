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

is_file ()
{
    test -f "${1:-}"
}

check_dependencies ()
{
    RETURN=0
    for COMMAND in awk date ip ping sleep timeout wc
    do
        type "$COMMAND" >/dev/null 2>&1 || {
            echo "dependency not found: '$COMMAND'" >&2
            RETURN=1
        }
    done
    is_equal "$RETURN" 0 || return "$RETURN"

    if timeout -t 1 sleep 0 >/dev/null 2>&1
    then
        TIMEOUT="timeout -t"
    else
        TIMEOUT="timeout"
    fi
}

include_config ()
{
    CONFIG_FILE="/etc/keepalived-gateway.conf"

    is_file "$CONFIG_FILE" || {
        echo "no such config file: '$CONFIG_FILE'"
        return 1
    }

    . "$CONFIG_FILE" || return
}

is_interface ()
{
    ip link show ${1:-} >/dev/null 2>&1
}

get_family_address ()
{
    case "${1:-}" in
        "")
        ;;
        *:*:*)
            FAMILY=inet6
        ;;
        *.*)
            FAMILY=inet
        ;;
        *)
            return 1
        ;;
    esac
}

resolve_ips ()
{
    nslookup "$1" 2>/dev/null | awk '
        /^Name:/ {
            found = "yes"
        }
        found == "yes" && /^Address[ 0-9]*:/ {
            addr = $NF
            if (addr ~ /\./ && !v4) {
                v4 = addr
            }
            if (addr ~ /:/ && !v6)  {
                v6 = addr
            }
        }
        END {
            printf "%s,%s", v4, v6
        }
    '
}

parse_resource ()
{
    SCHEME="" USER_INFO="" USER="" PASS="" AUTHORITY="" MASK="" PORT="" RESOURCE="" IPV4="" IPV6=""
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
            is_not_empty "${NSLOOKUP:-}" || {
                type nslookup >/dev/null 2>&1 && NSLOOKUP="yes" || {
                    echo "dependency not found: 'nslookup'"
                    echo "Please install nslookup or use an IP address instead of a domain name."
                    return 1
                } >&2
            }
            IPV6="$(resolve_ips "$HOST")"
            IPV4="${IPV6%%,*}"
            IPV6="${IPV6#*,}"
        ;;
        *)
            IPV4="$HOST"
        ;;
    esac
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

parse_interval ()
{
    case "${2%[smhdwMy]}" in
        "" | *[!0123456789]*)
            echo "variable '$1': must be an integer [s|m|h|d|w|M|y], but got: '${2:-}'"
            return 2
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

parse_gateway_entry ()
{
    IFS="@#_=-"
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

    case "${GATEWAY:-}" in
        *[.:]*)
        ;;
        *)
            ERROR="invalid gateway: '$GATEWAY'"
            return 2
        ;;
    esac

    case "${INTERFACE:-}" in
        "")
            is_not_empty "${DEFAULT_INTERFACE:-}" || {
                ERROR="missing interface for gateway: '$GATEWAY'"
                return 2
            }
            INTERFACE="$DEFAULT_INTERFACE"
        ;;
        *)
            is_interface "$INTERFACE" || {
                ERROR="network interface not found: '$INTERFACE'"
                return 2
            }
        ;;
    esac

    case "${METRIC:-}" in
        "")
            is_empty "${DEFAULT_METRIC:-}" || METRIC="$DEFAULT_METRIC"
        ;;
        *[!0123456789]*)
            ERROR="invalid route metric for gateway '$INTERFACE=$GATEWAY': '$METRIC'"
            return 2
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
$GATEWAYS
EOF
}

count_metrics ()
{
    awk '
        {
            for (i=1; i<=NF; i++) {
                fields = split($i, gateway, "=")
                metric = (fields >= 3 && gateway[3] != "") ? gateway[3] : 0
                if (gateway[1] != "" && !seen[metric]++) count++
            }
        }
        END { print count + 0 }
    ' <<EOF
$GATEWAYS
EOF
}

parse_gateway ()
{
    IFACES=""
    GATEWAYS=""
    RETURN=0
    for GATEWAY
    do
        parse_gateway_entry || return

        is_valid_ip "$GATEWAY" || {
            echo "Error: Gateway is not a valid IP address: '$GATEWAY'"
            RETURN=2
            continue
        }

        if is_local_ip "$GATEWAY" "$FAMILY"
        then
            echo "Error: Gateway is a local address on this host: '$GATEWAY'"
            RETURN=2
            continue
        fi

        is_empty "${PING_HOST:-}" || {
            case "$FAMILY" in
                inet)
                    is_not_empty "${PING_IPV4:-}"
                ;;
                inet6)
                    is_not_empty "${PING_IPV6:-}"
                ;;
            esac || {
                echo "Error: Gateway '$GATEWAY' is '$FAMILY', but PING_HOST has no '$FAMILY' address."
                RETURN=2
                continue
            }
        }

        is_empty "${SPEEDTEST_HOST:-}" || {
            case "$FAMILY" in
                inet)
                    is_not_empty "${SPEEDTEST_IPV4:-}"
                ;;
                inet6)
                    is_not_empty "${SPEEDTEST_IPV6:-}"
                ;;
            esac || {
                echo "Error: Gateway '$GATEWAY' is '$FAMILY', but SPEEDTEST_HOST has no '$FAMILY' address."
                RETURN=2
                continue
            }
        }

        GATEWAYS="${GATEWAYS:+"$GATEWAYS$LF"}$INTERFACE=$GATEWAY${METRIC:+"=$METRIC"}"
        collect_interface
    done
    is_equal "$RETURN" 0 || return "$RETURN"
    GATEWAYS="$(optimize_gateways)"
    TOTAL_METRICS="$(count_metrics)"
}

set_variables ()
{
    is_interface ${INTERFACE:-} ||
    echo "Warning: variable 'INTERFACE': network interface not found: '$INTERFACE'"
    DEFAULT_INTERFACE="${INTERFACE:-}"

    case "${METRIC:=0}" in
        *[!0123456789]*)
            echo "variable 'METRIC': invalid route metric: '$METRIC'"
            return 2
        ;;
        0*)
            METRIC="${METRIC#"${METRIC%%[!0]*}"}"
        ;;
    esac
    DEFAULT_METRIC="${METRIC:-}"

    is_empty "${VIRTUAL_IPADDRESS:-}" || {
        parse_resource "$VIRTUAL_IPADDRESS" && {
            is_valid_ip "${IPV4:-"$IPV6"}" && {
                VIRTUAL_IPADDRESS="${IPV4:-"$IPV6"}${MASK:+"/$MASK"}"
                VIRTUAL_IPADDRESS_FAMILY="$FAMILY"
            }
        }
    } || {
        echo "variable 'VIRTUAL_IPADDRESS': invalid vrrp address: '$VIRTUAL_IPADDRESS'"
        return 2
    }

    parse_interval CHECK_INTERVAL "${CHECK_INTERVAL:-10}" || return
    CHECK_INTERVAL="$INTERVAL"

    case "${SPEEDTEST:-}" in
        "" | 0 | [nN] | [nN][oO] | [oO][fF][fF] | [fF][aA][lL][sS][eE])
            SPEEDTEST=no
        ;;
        1 | [yY] | [yY][eE][sS] | [oO][nN] | [tT][rR][uU][eE])
            SPEEDTEST=yes
        ;;
        *)
            echo "variable 'SPEEDTEST': must be 'yes|no', but got: '$SPEEDTEST'"
            return 2
        ;;
    esac

    parse_interval SPEEDTEST_INTERVAL "${SPEEDTEST_INTERVAL:-3600}" || return
    SPEEDTEST_INTERVAL="$INTERVAL"

    is_empty "${PING_HOST:-}" || {
        parse_resource "$PING_HOST" && is_not_empty "${IPV4:-"${IPV6:-}"}" || {
            echo "Error: Failed to resolve PING_HOST IP."
            return 2
        }
        PING_IPV4="${IPV4:-}"
        PING_IPV6="${IPV6:-}"
    }

    is_equal "$SPEEDTEST" "no" || {
        is_empty "${SPEEDTEST_HOST:-}" && SPEEDTEST=no || {
            parse_resource "$SPEEDTEST_HOST" && is_not_empty "${IPV4:-"${IPV6:-}"}" || {
                echo "Error: Failed to resolve SPEEDTEST_HOST IP."
                return 2
            }

            for DOWNLOAD_CMD in wget curl
            do
                type "$DOWNLOAD_CMD" >/dev/null 2>&1 && break || DOWNLOAD_CMD=""
            done

            case "${DOWNLOAD_CMD:-}" in
                "")
                    echo "Error: Speedtest requires 'wget' or 'curl', but neither was found." >&2
                    return 2
                ;;
                wget)
                    DOWNLOAD_OPTIONS="-q -O -"
                    case "${SCHEME:-}" in
                        https)
                            case "$(wget --help 2>&1)" in
                                *"--no-check-certificate"*)
                                    DOWNLOAD_OPTIONS="--no-check-certificate $DOWNLOAD_OPTIONS"
                                ;;
                                *)
                                    echo "Warning: HTTPS speedtest requested, but wget lacks SSL support. Switching to HTTP."
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
                    DOWNLOAD_OPTIONS="-s -L -o -"
                    case "${SCHEME:-}" in
                        https)
                            case "$(curl --help all 2>&1 || curl --help 2>&1)" in
                                *"-k"* | *"--insecure"*)
                                    DOWNLOAD_OPTIONS="-k $DOWNLOAD_OPTIONS"
                                ;;
                                *)
                                    echo "Warning: HTTPS speedtest requested, but curl lacks SSL support. Switching to HTTP."
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

            case "${PORT:-}" in
                "")
                    SPEEDTEST_AUTHORITY_IPV4="${IPV4:+"$HOST"}"
                    SPEEDTEST_AUTHORITY_IPV6="${IPV6:+"$HOST"}"
                ;;
                *[!0-9]*)
                    echo "Error: variable 'SPEEDTEST_HOST': invalid port in authority '$AUTHORITY'"
                    return 2
                ;;
                *)
                    SPEEDTEST_HOST_IPV4="${IPV4:+"$HOST:$PORT"}"
                    is_equal "$HOST" "${IPV6:-}" &&
                    SPEEDTEST_HOST_IPV6="${IPV6:+"[$HOST]:$PORT"}" ||
                    SPEEDTEST_HOST_IPV4="${IPV6:+"$HOST:$PORT"}"
                ;;
            esac

            RESOURCE="${RESOURCE:+"/$RESOURCE"}${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
            SPEEDTEST_URL_IPV4="${IPV4:+${SCHEME:-http}://${USER_INFO:+$USER_INFO@}$SPEEDTEST_AUTHORITY_IPV4${RESOURCE:-}}"
            SPEEDTEST_URL_IPV6="${IPV6:+${SCHEME:-http}://${USER_INFO:+$USER_INFO@}$SPEEDTEST_AUTHORITY_IPV6${RESOURCE:-}}"
            SPEEDTEST_IPV4="${IPV4:-}"
            SPEEDTEST_IPV6="${IPV6:-}"

            test "$SPEEDTEST_INTERVAL" -ge "$CHECK_INTERVAL" ||
            echo "variable 'SPEEDTEST_INTERVAL': adjusted to '$CHECK_INTERVAL', must be '>= CHECK_INTERVAL'"
        }
    }

    case "${GATEWAYS:-}" in
        *[![:space:],]*)
            IFS="$IFS,"
            set -- $GATEWAYS
            IFS="$POSIX_IFS"
            parse_gateway "$@" || {
                echo "variable 'GATEWAYS': $ERROR"
                return 2
            }
        ;;
        *)
            false
        ;;
    esac || {
        echo "variable 'GATEWAYS': no valid gateways found: '$GATEWAYS'"
        return 2
    }
}

ip_route ()
{
    EXEC="$IP_ROUTE route $@"
    $EXEC && echo "$EXEC"
}

remove_test_route ()
{
    for IP in ${PING_IPV4:-} ${SPEEDTEST_IPV4:-}
    do
        IP_ROUTE="ip -4"
        while ip_route del "$IP"
        do
            :
        done 2>/dev/null
    done

    for IP in ${PING_IPV6:-} ${SPEEDTEST_IPV6:-}
    do
        IP_ROUTE="ip -6"
        while ip_route del "$IP"
        do
            :
        done 2>/dev/null
    done

    return "${RETURN:-0}"
}

clean_and_exit ()
{
    EXIT="${1:-$?}"
    trap - EXIT
    remove_test_route || RETURN=$?
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
            IP_ROUTE="ip -6"
            SPEEDTEST_URL="${SPEEDTEST_URL_IPV6:-}"
            SPEEDTEST_IP="${SPEEDTEST_IPV6:-}"
            PING_IP="${PING_IPV6:-}"
            DOWNLOAD_INET="-6"
        ;;
        *)
            IP_ROUTE="ip -4"
            SPEEDTEST_URL="${SPEEDTEST_URL_IPV4:-}"
            SPEEDTEST_IP="${SPEEDTEST_IPV4:-}"
            PING_IP="${PING_IPV4:-}"
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
            return 1
        ;;
    esac
}

is_failed_metric ()
{
    is_metric_alive && return 1 || return 0
}

collect_gateway ()
{
    DEFAULT_GATEWAYS="${DEFAULT_GATEWAYS:+"$DEFAULT_GATEWAYS "}$BEST_GATEWAY"
}

collect_route ()
{
    DEFAULT_ROUTES="${DEFAULT_ROUTES:+"$DEFAULT_ROUTES$LF"}$BEST_ROUTE"
}

get_time ()
{
    date "+%s"
}

wait_for_speedtest ()
{
    is_not_empty "${LAST_SPEEDTEST:-}" &&
    test $(( $(get_time) - LAST_SPEEDTEST )) -lt "$SPEEDTEST_INTERVAL"
}

is_not_vrrp_master ()
{
    is_not_empty "${VIRTUAL_IPADDRESS:-}" && {
        is_local_ip "$VIRTUAL_IPADDRESS" "$VIRTUAL_IPADDRESS_FAMILY" &&
        return 1 || return 0
    } >/dev/null 2>&1
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
        $TIMEOUT "${SPEEDTEST_TIMEOUT:=15}" \
        $DOWNLOAD_CMD $DOWNLOAD_INET $DOWNLOAD_OPTIONS "$SPEEDTEST_URL" | wc -c
    )"
    END_SPEEDTEST="$(get_time)"
    BYTE=$(( ${BYTE:-0} + 0 ))
    DURATION=$((END_SPEEDTEST - START_SPEEDTEST))
    test "$DURATION" -gt 0 || DURATION=1
    test "$BYTE" -gt 1024 && {
        BIT=$(( (BYTE * 8) / DURATION ))
        echo "route speed: $(bit2Human "$BIT")/s"
    }
}

check_ping ()
{
    ping -W "${PING_TIMEOUT:=3}" -c "${PING_COUNT:=3}" "$@" >/dev/null 2>&1
}

add_route ()
{
    is_not_empty "${DEFAULT_ROUTES:-}" || return
    while read ROUTE
    do
        ip_route replace "$ROUTE" || :
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
            while read -r ROUTE
            do
                ROUTE=$(echo $ROUTE)
                CURRENT_ROUTES="${CURRENT_ROUTES:+"$CURRENT_ROUTES$LF"}$ROUTE"
            done <<EOF
$ROUTES
EOF
        fi
    done 2>/dev/null
}

get_obsolete_routes ()
{
    is_not_empty "${CURRENT_ROUTES:-}" || return
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
}

remove_obsolete_routes ()
{
    is_not_empty "${REMOVE_ROUTES:-}" || return
    while read ROUTE
    do
        ip_route del "$ROUTE"
    done <<EOF
$REMOVE_ROUTES
EOF
}

check_gateways ()
{
    is_not_empty "${DEFAULT_GATEWAYS:-}" || return

    ALIVE_COUNT=0
    ALIVE_GATEWAYS=""
    ALIVE_METRICS=""
    ALIVE_ROUTES=""

    for GATEWAY in $DEFAULT_GATEWAYS
    do
        format_route

        is_interface "$INTERFACE" || {
            echo "interface not found or down: '$INTERFACE'"
            continue
        }

        if is_not_empty "${PING_HOST:-}"
        then
            ip_route replace "$PING_ROUTE"
            check_ping -I "$INTERFACE" "$PING_IP" || {
                ip_route del "$PING_ROUTE"
                echo "host '$PING_HOST' is unreachable via route '$ROUTE'"
                continue
            }
            ip_route del "$PING_ROUTE"
        else
            check_ping -I "$INTERFACE" "$GATEWAY_IP" || {
                echo "gateway '$GATEWAY_IP' is unreachable on interface '$INTERFACE'"
                continue
            }
        fi

        ALIVE_COUNT="$((ALIVE_COUNT + 1))"
        ALIVE_GATEWAYS="${ALIVE_GATEWAYS:+"$ALIVE_GATEWAYS "}$GATEWAY"
        ALIVE_METRICS="${ALIVE_METRICS:+"$ALIVE_METRICS "}${METRIC:-0}"
        ALIVE_ROUTES="${ALIVE_ROUTES:+"$ALIVE_ROUTES$LF"}$ROUTE"
    done
    is_equal "$ALIVE_COUNT" "$TOTAL_METRICS"
}

maintain_route ()
{
    DEFAULT_GATEWAYS="${ALIVE_GATEWAYS:-}"
    DEFAULT_ROUTES="${ALIVE_ROUTES:-}"
    CURRENT_METRIC=""
    BEST_GATEWAY=""
    BEST_ROUTE=""
    BEST_SPEED=0

    for GATEWAY in $GATEWAYS
    do
        format_route

        is_equal "${CURRENT_METRIC:-}" "${METRIC:-0}" || {

            is_empty "${ALIVE_METRICS:-}" || is_failed_metric || continue

            CURRENT_METRIC="$METRIC"
            BEST_SPEED=0
            is_empty "${BEST_ROUTE:-}" || {
                collect_gateway
                collect_route
                BEST_ROUTE=""
            }
        }

        is_interface "$INTERFACE" || continue

        is_equal "$SPEEDTEST" no || wait_for_speedtest || is_not_vrrp_master || {
            ip_route replace "$SPEEDTEST_ROUTE"

            if speedtest "$SPEEDTEST_URL"
            then
                test "$BEST_SPEED" -ge "$BIT" || {
                    BEST_GATEWAY="$GATEWAY"
                    BEST_ROUTE="$ROUTE"
                    BEST_SPEED="$BIT"
                }
                ip_route del "$SPEEDTEST_ROUTE"
                continue
            fi

            ip_route del "$SPEEDTEST_ROUTE"
            echo "failed to measure speed from '$SPEEDTEST_HOST' via route '$SPEEDTEST_ROUTE'"
        }

        if is_not_empty "${PING_HOST:-}"
        then
            ip_route replace "$PING_ROUTE"
            check_ping -I "$INTERFACE" "$PING_IP" && {
                BEST_GATEWAY="$GATEWAY"
                BEST_ROUTE="$ROUTE"
            } || {
                echo "host '$PING_HOST' is unreachable via route '$PING_ROUTE'"
                check_ping -I "$INTERFACE" "$GATEWAY_IP" &&
                echo "gateway '$GATEWAY_IP' is reachable on interface '$INTERFACE'" ||
                echo "gateway '$GATEWAY_IP' is unreachable on interface '$INTERFACE'"
            }
            ip_route del "$PING_ROUTE"
        else
            check_ping -I "$INTERFACE" "$GATEWAY_IP" && {
                BEST_GATEWAY="$GATEWAY"
                BEST_ROUTE="$ROUTE"
            } ||
            echo "gateway '$GATEWAY_IP' is unreachable on interface '$INTERFACE'"
        fi
    done

    LAST_SPEEDTEST="${END_SPEEDTEST:-}"
    is_empty "${BEST_ROUTE:-}" || {
        collect_gateway
        collect_route
    }

    add_route &&
    get_current_routes &&
    get_obsolete_routes &&
    remove_obsolete_routes || :
}

main ()
{
    LF="
"
    POSIX_IFS="$(printf " \t")$LF"
    IFS="$POSIX_IFS"

    check_dependencies &&
    include_config &&
    set_variables &&
    remove_test_route || return

    trap 'clean_and_exit' 0       # EXIT (0) : Naturally occurring script termination.
    trap 'clean_and_exit 129' 1   # HUP (1)  : Hangup detected on controlling terminal or death of controlling process.
    trap 'clean_and_exit 130' 2   # INT (2)  : Program interrupt (usually Ctrl+C). Exit code 130 (128 + 2).
    trap 'clean_and_exit 143' 15  # TERM (15): Termination signal (default for 'kill' command). Exit code 143 (128 + 15).

    ALIVE_GATEWAYS=""
    ALIVE_METRICS=""
    ALIVE_ROUTES=""

    while :
    do
        check_gateways || maintain_route
        sleep "$CHECK_INTERVAL"
    done
}

main
