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

parse_interval ()
{
    case "${2%[smhdwMy]}" in
        "" | *[!0123456789]*)
            echo "variable '$1': invalid value: '$2'"
            echo "variable '$1': valid value: an integer indicating the number of [s]econds, [m]inutes, [h]ours, [d]ays, [w]eeks, [M]onths and [y]ears"
            return 2
        ;;
    esac
    case "$2" in
        *m) echo "$((${2%m} * 60))" ;;
        *h) echo "$((${2%h} * 3600))" ;;
        *d) echo "$((${2%d} * 86400))" ;;
        *w) echo "$((${2%w} * 604800))" ;;
        *M) echo "$((${2%M} * 2678400))" ;;
        *y) echo "$((${2%y} * 32140800))" ;;
         *) echo "${2%s}" ;;
    esac
}

check_variables ()
{
    case "${GATEWAY_IPS:-}" in
        *[![:space:],]*)
            IFS="$IFS,"
            set -- $GATEWAY_IPS
            IFS="${IFS%,}"
            GATEWAY_IPS="$@"
        ;;
        *)
            echo "variable 'GATEWAY_IPS': no valid gateway IPs found"
            return 2
        ;;
    esac

    case "${INTERFACE:-}" in
        "")
            echo "variable 'INTERFACE': is empty"
            return 2
        ;;
        *)
            ip link show "$INTERFACE" >/dev/null 2>&1 || {
                echo "variable 'INTERFACE': network interface not found: '$INTERFACE'"
                return 2
            }
        ;;
    esac

    CHECK_INTERVAL="$(parse_interval CHECK_INTERVAL "${CHECK_INTERVAL:-10}")" || return

    case "${SPEEDTEST:-}" in
        "" | 0 | [nN] | [nN][oO] | [fF][aA][lL][sS][eE])
            SPEEDTEST=no
            return
        ;;
        1 | [yY] | [yY][eE][sS] | [tT][rR][uU][eE])
            SPEEDTEST=yes
        ;;
        *)
            echo "variable 'SPEEDTEST': invalid value: '$SPEEDTEST'"
            echo "variable 'SPEEDTEST': valid values: yes or no"
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
            echo "variable 'SPEEDTEST_SCOPE': invalid value: '$SPEEDTEST_SCOPE'"
            echo "variable 'SPEEDTEST_SCOPE': valid values: 10M, 100M, 1000M, 10000M"
            return 2
        ;;
    esac

    SPEEDTEST_INTERVAL="$(parse_interval SPEEDTEST_INTERVAL "${SPEEDTEST_INTERVAL:-3600}")" || return
    test "$SPEEDTEST_INTERVAL" -ge "$CHECK_INTERVAL" ||
        echo "Note: Set SPEEDTEST_INTERVAL to $CHECK_INTERVAL, because SPEEDTEST_INTERVAL [$SPEEDTEST_INTERVAL] is less than CHECK_INTERVAL [$CHECK_INTERVAL]"
}

ip_route ()
{
    ROUTE="$2"
    EXEC="ip route $1 $ROUTE"
    $EXEC && echo "$EXEC"
}

del_tmp_route ()
{
    if TMP_ROUTE="$(ip r | grep "^\<${REMOTE_HOST:-}\> via")"
    then
        ip_route del "$TMP_ROUTE" >/dev/null 2>&1
    fi
}

cleaning_and_exit ()
{
    RETURN="${RETURN:-0}"
    is_empty "${DLFILE:-}" || rm -f "$DLFILE" || RETURN=$?
    del_tmp_route || RETURN=$?
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
    ROUTE="$(ip r | grep "\<$INTERFACE\>" | grep '\<default\>')" &&
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
    is_empty "${VIRTUAL_IPADDRESS:-}" ||
    ip -o -4 a | grep "\<$VIRTUAL_IPADDRESS\>" >/dev/null 2>&1
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
    START_TEST="$(get_time)"
    timeout 15 wget "http://$REMOTE_HOST/$SPEEDTEST_SCOPE" -O "$DLFILE" 2>/dev/null
    END_TEST="$(get_time)"
    BYTE="$(awk '{s+=$1} END {print s}' "$DLFILE")"
    BIT="$((BYTE * 16))"
    BIT="$((BIT / $((END_TEST - START_TEST))))"
    SPEED="$(bit2Human "$BIT")/s"
    rm -f "$DLFILE"
}

select_gateway ()
{
    is_equal "$SPEEDTEST" yes &&
    is_master_state_vrrp &&
    speedtest_interval_passed || return 0

    NEW_ROUTE= BEST_BIT= COUNT=1
    while test "$COUNT" -le "$GATEWAY_NUM"
    do
        COUNT="$((COUNT + 1))"
        TMP_ROUTE="$REMOTE_HOST via $CURRENT_GATEWAY dev $INTERFACE"
        echo "running speedtest every '$SPEEDTEST_INTERVAL seconds' for a temp route: '$TMP_ROUTE'"
        ip_route add "$TMP_ROUTE" >/dev/null || return 0

        if check_ping "$REMOTE_HOST"
        then
            speedtest
            echo "route speed: $SPEED"
            test "${BEST_BIT:-0}" -ge "$BIT" || {
                BEST_BIT="$BIT"
                NEW_ROUTE="default via $CURRENT_GATEWAY dev $INTERFACE"
            }
        elif check_ping "$CURRENT_GATEWAY"
        then
            echo "host is unavailable: '$REMOTE_HOST'"
        else
            echo "gateway is unavailable: '$CURRENT_GATEWAY'"
        fi

        ip_route del "$TMP_ROUTE" >/dev/null || return 0
        get_gateway
    done
    is_empty "${NEW_ROUTE:-}" || is_equal "$(get_default_route)" "$NEW_ROUTE" || {
        echo "switching to a faster route"
        ip_route del "$ROUTE"
        ip_route add "$NEW_ROUTE"
        CURRENT_ROUTE="$NEW_ROUTE"
    }
}

include_config && check_variables || exit
trap cleaning_and_exit HUP INT TERM
del_tmp_route && add_default_route || exit

while :
do
    echo "the current route: '$CURRENT_ROUTE'"

    if is_not_empty "${REMOTE_HOST:-}"
    then
        if check_ping "$REMOTE_HOST"
        then
            echo "host is available: '$REMOTE_HOST'"
            test "$GATEWAY_NUM" -eq 1 || select_gateway
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
    sleep "$CHECK_INTERVAL"
done
