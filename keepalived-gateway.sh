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
    for COMMAND in awk cut date ip grep ping sed sleep sort timeout tr wc wget
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
    ip link show "$1" >/dev/null 2>&1
}

set_family_address ()
{
    case "${1:-}" in
        "")
        ;;
        *.*)
            FAMILY=inet
        ;;
        *:*)
            FAMILY=inet6
        ;;
        *)
            return 2
        ;;
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

    GATEWAY="$INTERFACE=$GATEWAY${METRIC:+"=$METRIC"}"
}

optimize_gateways ()
{
    GATEWAYS="$(echo "$GATEWAYS" | awk -F'=' '
        {
            interface = $1
            gateway = $2
            metric = ($3 == "" ? 0 : $3)
            key = interface "=" gateway

            if (!(key in best_metric) || metric < best_metric[key]) {
                best_metric[key] = metric
                pos[key] = $0
            }
        }
        END {
            for (key in pos) {
                printf "%010d|%s\n", best_metric[key], pos[key]
            }
        }
    ' | sort -n | cut -d'|' -f2- | tr '\012' ' ' | sed 's/ $//')"
}

parse_gateway ()
{
    GATEWAYS=
    for GATEWAY
    do
        parse_gateway_entry || return
        GATEWAYS="${GATEWAYS:+"$GATEWAYS$LF"}$GATEWAY"
    done
    optimize_gateways
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
        *m) INTERVAL="$((${2%m} * 60))" ;;
        *h) INTERVAL="$((${2%h} * 3600))" ;;
        *d) INTERVAL="$((${2%d} * 86400))" ;;
        *w) INTERVAL="$((${2%w} * 604800))" ;;
        *M) INTERVAL="$((${2%M} * 2678400))" ;;
        *y) INTERVAL="$((${2%y} * 32140800))" ;;
         *) INTERVAL="${2%s}" ;;
    esac
}

set_variables ()
{
    is_interface "${INTERFACE:-}" || {
        echo "variable 'INTERFACE': network interface not found: '$INTERFACE'"
        return 2
    }
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

    set_family_address "${VIRTUAL_IPADDRESS:-}" || {
        echo "variable 'VIRTUAL_IPADDRESS': invalid vrrp address: '$VIRTUAL_IPADDRESS'"
        return 2
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

    is_equal "$SPEEDTEST" "no" || {
        is_empty "${SPEEDTEST_HOST:-}" && SPEEDTEST=no || {
            SPEEDTEST_URL="$SPEEDTEST_HOST${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
            case "$SPEEDTEST_URL" in
                http://* | https://*)
                    ;;
                *)
                    SPEEDTEST_URL="http://$SPEEDTEST_URL"
                    ;;
            esac
            test "$SPEEDTEST_INTERVAL" -ge "$CHECK_INTERVAL" ||
            echo "variable 'SPEEDTEST_INTERVAL': adjusted to '$CHECK_INTERVAL', must be '>= CHECK_INTERVAL'"
        }
    }
}

ip_route ()
{
    EXEC="ip route $@"
    $EXEC && echo "$EXEC"
}

remove_test_route ()
{
    if PING_ROUTE="$(ip route list "${PING_HOST:-}")"
    then
        ip_route del "$PING_ROUTE"
    fi 2>/dev/null

    if SPEEDTEST_ROUTE="$(ip route list "${SPEEDTEST_HOST:-}")"
    then
        ip_route del "$SPEEDTEST_ROUTE"
    fi 2>/dev/null
}

clean_and_exit ()
{
    RETURN="${RETURN:-0}"
    is_empty "${DLFILE:-}" || rm -f "$DLFILE" || RETURN=$?
    remove_test_route || RETURN=$?
    exit "$RETURN"
}

check_ping ()
{
    ping -W "${TIMEOUT:=3}" -c "${COUNT_REPLIES:=3}" "$@" >/dev/null 2>&1
}

is_not_vrrp_master ()
{
    is_not_empty "${VIRTUAL_IPADDRESS:-}" && {
        ip -oneline -family "$FAMILY" address | grep "\<$VIRTUAL_IPADDRESS\>" &&
        return 1 || return 0
    } >/dev/null 2>&1
}

get_time ()
{
    date "+%s"
}

wait_for_speedtest ()
{
    is_not_empty "${END_TEST:-}" &&
    test "$(($(get_time) - END_TEST))" -lt "$SPEEDTEST_INTERVAL"
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
    START_TEST="$(get_time)"
    BYTE="$($TIMEOUT wget -q -O - "$SPEEDTEST_URL" | wc -c)"
    END_TEST="$(get_time)"
    BYTE="$(( ${BYTE:-0} + 0 ))"
    DURATION=$((END_TEST - START_TEST))
    test "$DURATION" -gt 0 || DURATION=1
    test "$BYTE" -gt 1024 && {
        BIT=$(( (BYTE * 8) / DURATION ))
        echo "route speed: $(bit2Human "$BIT")/s"
    }
}

format_route ()
{
    IFS="="
    read INTERFACE GATEWAY METRIC <<EOF
$GATEWAY
EOF
    IFS="$POSIX_IFS"

    is_interface "$INTERFACE" || return

    ROUTE="default via $GATEWAY dev $INTERFACE${METRIC:+" metric $METRIC"}"
    SPEEDTEST_ROUTE="${SPEEDTEST_HOST:-} via $GATEWAY dev $INTERFACE"
    PING_ROUTE="${PING_HOST:-} via $GATEWAY dev $INTERFACE"
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
        if ROUTE="$(ip route show default dev "$INTERFACE" 2>/dev/null)"
        then
            CURRENT_ROUTES="${CURRENT_ROUTES:+"$CURRENT_ROUTES$LF"}$ROUTE"
        fi
    done
}

get_obsolete_routes ()
{
    is_not_empty "${CURRENT_ROUTES:-}" || return
    REMOVE_ROUTES="$(printf "%s\n\n%s" "$DEFAULT_ROUTES" "$CURRENT_ROUTES" | awk '
        BEGIN {
            found_separator = 0
        }

        $0 == "" && found_separator == 0 {
            found_separator = 1;
            next
        }

        !found_separator {
            wanted[$0] = 1
            next
        }

        found_separator && !($0 in wanted) {
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

maintain_route ()
{
    DEFAULT_ROUTES=""
    PREV_METRIC=""
    NEW_ROUTE=""
    BEST_BIT=0
    IFACES=""

    for GATEWAY in $GATEWAYS
    do
        format_route || continue
        collect_interface

        is_equal "${METRIC:-0}" "${PREV_METRIC:-0}" || {
            DEFAULT_ROUTES="$NEW_ROUTE"
            PREV_METRIC="$METRIC"
            NEW_ROUTE=""
            BEST_BIT=0
        }

        is_equal "$SPEEDTEST" no || wait_for_speedtest || is_not_vrrp_master || {
            ip_route replace "$SPEEDTEST_ROUTE"

            if speedtest "$SPEEDTEST_URL"
            then
                test "$BEST_BIT" -ge "$BIT" || {
                    NEW_ROUTE="$ROUTE"
                    BEST_BIT="$BIT"
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

            check_ping -I "$INTERFACE" "$PING_HOST" && NEW_ROUTE="$ROUTE" || {
                echo "host '$PING_HOST' is unreachable via route '$PING_ROUTE'"
                check_ping -I "$INTERFACE" "$GATEWAY" &&
                echo "gateway '$GATEWAY' is reachable on interface '$INTERFACE'" ||
                echo "gateway '$GATEWAY' is unreachable on interface '$INTERFACE'"
            }

            ip_route del "$PING_ROUTE"
        else
            check_ping -I "$INTERFACE" "$GATEWAY" && NEW_ROUTE="$ROUTE" ||
            echo "gateway '$GATEWAY' is unreachable on interface '$INTERFACE'"
        fi
    done

    add_route &&
    get_current_routes &&
    get_obsolete_routes &&
    remove_obsolete_routes || :
}

LF="$(printf '\n')"
POSIX_IFS="$(printf ' \t\n')"
IFS="$POSIX_IFS"

check_dependencies && include_config && set_variables || exit
trap clean_and_exit HUP INT TERM
remove_test_route || exit

while :
do
    maintain_route
    sleep "$CHECK_INTERVAL"
done
