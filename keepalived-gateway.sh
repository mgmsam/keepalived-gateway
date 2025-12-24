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

is_diff () {
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
            IP="$1"
            METRIC="${2:-}"
        ;;
        *)
            INTERFACE="${1:-}"
            IP="${2:-}"
            METRIC="${3:-}"
        ;;
    esac

    case "${IP:-}" in
        *[.:]*)
        ;;
        *)
            ERROR="invalid gateway IP: '$IP'"
            return 2
        ;;
    esac

    case "${INTERFACE:-}" in
        "")
            is_not_empty "${DEFAULT_INTERFACE:-}" || {
                ERROR="missing interface for gateway: '$IP'"
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
            ERROR="invalid route metric for gateway '$INTERFACE=$IP': '$METRIC'"
            return 2
        ;;
        0*)
            METRIC="${METRIC#"${METRIC%%[!0]*}"}"
        ;;
    esac

    GATEWAY="$INTERFACE=$IP${METRIC:+"=$METRIC"}"
}

parse_gateway ()
{
    GATEWAYS=
    for GATEWAY
    do
        parse_gateway_entry || return
        GATEWAYS="${GATEWAYS:+"$GATEWAYS "}$GATEWAY"
    done
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

    case "${GATEWAY_IPS:-}" in
        *[![:space:],]*)
            IFS="$IFS,"
            set -- $GATEWAY_IPS
            IFS="$POSIX_IFS"
            parse_gateway "$@" || {
                echo "variable 'GATEWAY_IPS': $ERROR"
                return 2
            }
            is_diff "$#" 1 || SPEEDTEST=no
            GATEWAY_NUM="$#"
            GATEWAY_IPS="$GATEWAYS"
        ;;
        *)
            false
        ;;
    esac || {
        echo "variable 'GATEWAY_IPS': no valid gateways found: '$GATEWAY_IPS'"
        return 2
    }

    parse_interval CHECK_INTERVAL "${CHECK_INTERVAL:-10}" || return
    CHECK_INTERVAL="$INTERVAL"

    case "${SPEEDTEST:-}" in
        "" | 0 | [nN] | [nN][oO] | [oO][fF][fF] | [fF][aA][lL][sS][eE])
            SPEEDTEST=no
        ;;
        1 | [yY] | [yY][eE][sS] | [oO][nN] | [tT][rR][uU][eE])
            is_equal "$GATEWAY_NUM" 1 && SPEEDTEST=no || SPEEDTEST=yes
        ;;
        *)
            echo "variable 'SPEEDTEST': must be 'yes|no', but got: '$SPEEDTEST'"
            return 2
        ;;
    esac

    case "${SPEEDTEST_SCOPE:-}" in
        "")
            SPEEDTEST_SCOPE=10M
        ;;
        10 | 100 | 1000 |10000)
            SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE}M"
        ;;
        10[mM] | 100[mM] | 1000[mM] | 10000[mM])
            SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE%[mM]}M"
        ;;
        *)
            echo "variable 'SPEEDTEST_SCOPE': must be '10|100|1000|10000'[M], but got: '$SPEEDTEST_SCOPE'"
            return 2
        ;;
    esac

    parse_interval SPEEDTEST_INTERVAL "${SPEEDTEST_INTERVAL:-3600}" || return
    SPEEDTEST_INTERVAL="$INTERVAL"

    is_equal "$SPEEDTEST" "no" || {
        is_empty "${SPEEDTEST_HOST:-}" && SPEEDTEST=no || {
            test "$SPEEDTEST_INTERVAL" -ge "$CHECK_INTERVAL" ||
            echo "variable 'SPEEDTEST_INTERVAL': adjusted to '$CHECK_INTERVAL', must be '>= CHECK_INTERVAL'"
        }
    }
}

ip_route ()
{
    EXEC="ip route $1 $2"
    $EXEC && echo "$EXEC"
}

remove_test_route ()
{
    if TMP_ROUTE="$(ip route list "${REMOTE_HOST:-}")"
    then
        ip_route del "$TMP_ROUTE"
    fi 2>/dev/null
}

clean_and_exit ()
{
    RETURN="${RETURN:-0}"
    is_empty "${DLFILE:-}" || rm -f "$DLFILE" || RETURN=$?
    remove_test_route || RETURN=$?
    exit "$RETURN"
}

get_gateway ()
{
    set -- $GATEWAY_IPS
    CURRENT_GATEWAY="$1"
    shift
    set -- "$@" "$CURRENT_GATEWAY"
    GATEWAY_IPS="$@"
    GATEWAY_NUM="$#"
}

get_default_route ()
{
    ROUTE="$(ip route list default dev "$INTERFACE" 2>/dev/null)" &&
    echo "${ROUTE%"${ROUTE##*[![:blank:]]}"}"
}

add_default_route ()
{
    get_gateway
    NEW_ROUTE="default via $CURRENT_GATEWAY dev $INTERFACE"
    CURRENT_ROUTE="$(get_default_route)" && {
        is_equal "$CURRENT_ROUTE" "$NEW_ROUTE" || {
            ip_route del "$CURRENT_ROUTE"
            false
        }
    } || {
        CURRENT_ROUTE="$NEW_ROUTE"
        ip_route add  "$NEW_ROUTE"
    }
}

check_ping ()
{
    ping -W "${TIMEOUT:=3}" -c "${COUNT_REPLIES:=3}" "$1" >/dev/null 2>&1
}

is_master_state_vrrp ()
{
    is_empty "${VIRTUAL_IPADDRESS:-}" || {
        ip -oneline -family "$FAMILY" address | grep "\<$VIRTUAL_IPADDRESS\>"
    } >/dev/null 2>&1
}

get_time ()
{
    date "+%s"
}

speedtest_interval_passed ()
{
    is_empty "${END_TEST:-}" ||
    test "$(($(get_time) - END_TEST))" -ge "$SPEEDTEST_INTERVAL"
}

bit2Human ()
{
    BIT="${1:-0}" REMAINS='' SIZE=1
    while test "$BIT" -gt 1000
    do
        REMAINS="$(printf ".%02d" $((BIT % 1000 * 100 / 1000)))"
        BIT=$((BIT / 1000))
        SIZE=$((SIZE + 1))
    done
    set -- bit Kbit Mbit Gbit Tbit Ebit Pbit Zbit Ybit
    eval SIZE=\$$SIZE
    echo "$BIT${REMAINS:-} $SIZE"
}

speedtest ()
{
    DLFILE=$(mktemp /tmp/download.XXXXXX)
    {
        START_TEST="$(get_time)"
        timeout 15 wget "http://$SPEEDTEST_HOST/$SPEEDTEST_SCOPE" -O "$DLFILE" || :
        END_TEST="$(get_time)"
        BYTE="$(awk '{s+=$1} END {print s}' "$DLFILE")" || :
        rm -f "$DLFILE" || :
    } 2>/dev/null
    is_not_empty "${BYTE:-}" && {
        BIT="$((BYTE * 16))"
        BIT="$((BIT / $((END_TEST - START_TEST))))"
        echo "route speed: $(bit2Human "$BIT")/s"
    }
}

select_gateway ()
{
    NEW_ROUTE= BEST_BIT= COUNT=1
    while test "$COUNT" -le "$GATEWAY_NUM"
    do
        COUNT="$((COUNT + 1))"
        TMP_ROUTE="$SPEEDTEST_HOST via $CURRENT_GATEWAY dev $INTERFACE"
        echo "running speedtest every '$SPEEDTEST_INTERVAL seconds' for a temp route: '$TMP_ROUTE'"
        ip_route add "$TMP_ROUTE" >/dev/null || return 0

        if speedtest
        then
            test "${BEST_BIT:-0}" -ge "$BIT" || {
                BEST_BIT="$BIT"
                NEW_ROUTE="default via $CURRENT_GATEWAY dev $INTERFACE"
            }
        elif check_ping "$CURRENT_GATEWAY"
        then
            echo "host is unavailable: '$SPEEDTEST_HOST'"
        else
            echo "gateway is unavailable: '$CURRENT_GATEWAY'"
        fi

        ip_route del "$TMP_ROUTE" >/dev/null || return 0
        get_gateway
    done
    is_empty "${NEW_ROUTE:-}" ||
    if CURRENT_ROUTE="$(get_default_route)"
    then
        is_equal "$CURRENT_ROUTE" "$NEW_ROUTE" || {
            echo "switching to a faster route"
            ip_route del "$ROUTE"
            ip_route add "$NEW_ROUTE"
            CURRENT_ROUTE="$NEW_ROUTE"
        }
    fi
}

maintain_route ()
{
    echo "the current route: '$CURRENT_ROUTE'"

    if is_not_empty "${PING_HOST:-}"
    then
        if check_ping "$PING_HOST"
        then
            echo "host is available: '$PING_HOST'"
            is_equal "$SPEEDTEST" no || {
                is_master_state_vrrp  &&
                speedtest_interval_passed && select_gateway || :
            }
        else
            if check_ping "$CURRENT_GATEWAY"
            then
                echo "host is unavailable: '$REMOTE_HOST'"
                false
            else
                echo "gateway is unavailable: '$CURRENT_GATEWAY'"
                false
            fi
        fi
    elif check_ping "$CURRENT_GATEWAY"
    then
        echo "gateway is available: '$CURRENT_GATEWAY'"
    else
        echo "gateway is unavailable: '$CURRENT_GATEWAY'"
        false
    fi || test "$GATEWAY_NUM" -eq 1 || add_default_route
}

POSIX_IFS="$(printf ' \t\n')"
IFS="$POSIX_IFS"

include_config && set_variables || exit
trap clean_and_exit HUP INT TERM
remove_test_route || add_default_route || exit

while :
do
    maintain_route
    sleep "$CHECK_INTERVAL"
done
