#!/bin/sh

CONFIG_FILE="/etc/keepalived-gateway.conf"

include_config ()
{
    test -f "$CONFIG_FILE" || {
        echo "no such config file: '$CONFIG_FILE'"
        return 1
    }

    test -r "$CONFIG_FILE" || {
        echo "no read permission: '$CONFIG_FILE'"
        return 1
    }

    . "$CONFIG_FILE" || return

    test "${GATEWAY:-}" || {
        echo "variable is empty: 'GATEWAY'"
        return 1
    }

    test "${INTERFACE:-}" || {
        echo "variable is empty: 'INTERFACE'"
        return 1
    }

    test "${SPEEDTEST_SCOPE:-}" && {
        case "$SPEEDTEST_SCOPE" in
            10|100|1000|10000)
                SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE}M"
                ;;
            10[mM]|100[mM]|1000[mM]|10000[mM])
                SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE%[mM]}M"
                ;;
            *)  echo "invalid value in the 'SPEEDTEST_SCOPE' variable: '$SPEEDTEST_SCOPE'"
                echo "acceptable values for the 'SPEEDTEST_SCOPE' variable: 10M, 100M, 1000M, 10000M"
                return 1
        esac
    } || SPEEDTEST_SCOPE=10M

    test "${SPEEDTEST_INTERVAL:-}" && {
        case "${SPEEDTEST_INTERVAL%[smhdwMy]}" in
            *[!0123456789]*)
                echo "invalid value in the 'SPEEDTEST_INTERVAL' variable: '$SPEEDTEST_INTERVAL'"
                echo "acceptable values for the 'SPEEDTEST_INTERVAL' variable are an integer indicating the number of [s]econds, [m]inutes, [h]ours, [d]ays, [w]eeks, [M]onths and [y]ears"
                return 1
        esac
        case "$SPEEDTEST_INTERVAL" in
            *s) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%s}" ;;
            *m) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%m}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 60))" ;;
            *h) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%h}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 3600))" ;;
            *d) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%d}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 86400))" ;;
            *w) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%w}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 604800))" ;;
            *M) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%M}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 2678400))" ;;
            *y) SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL%y}"
                SPEEDTEST_INTERVAL="$((SPEEDTEST_INTERVAL * 32140800))" ;;
        esac
    } || SPEEDTEST_INTERVAL=3600
}

check_ping ()
{
    ping -W "${TIMEOUT:=3}" -c "${COUNT_REPLIES:=3}" "$1" >/dev/null 2>&1
}

get_gataway ()
{
    set -- $GATEWAY
    CURRENT_GATEWAY="$1"
    shift
    set -- "$@" "$CURRENT_GATEWAY"
    GATEWAY="$@"
    GATEWAY_NUM="$#"
}

get_default_route ()
{
    ROUTE="$(ip r | grep "\<$INTERFACE\>" | grep '\<default\>')" &&
    echo "${ROUTE%"${ROUTE##*[![:blank:]]}"}"
}

ip_route ()
{
    ROUTE="$2"
    EXEC="ip route $1 $ROUTE"
    $EXEC && echo "$EXEC"
}

add_default_route ()
{
    get_gataway
    NEW_ROUTE="default via $CURRENT_GATEWAY dev $INTERFACE"
    CURRENT_ROUTE="$(get_default_route)" && {
        test "$CURRENT_ROUTE" = "$NEW_ROUTE" || {
            ip_route del "$CURRENT_ROUTE"
            false
        }
    } || {
        CURRENT_ROUTE="$NEW_ROUTE"
        ip_route add "$NEW_ROUTE"
    }
}

is_master_state_vrrp ()
{
    if test "${VIRTUAL_IPADDRESS:-}"
    then
        ip -o -4 a | grep "$VIRTUAL_IPADDRESS" >/dev/null 2>&1
    fi
}

get_time ()
{
    date "+%s"
}

speedtest_interval_passed ()
{
    test "${END_TEST:-}" || return 0
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
    is_master_state_vrrp && speedtest_interval_passed || return 0
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

        ip_route del "$TMP_ROUTE" >/dev/null 2>&1
        get_gataway
    done
    test -z "${NEW_ROUTE:-}" || {
        test "$(get_default_route)" = "$NEW_ROUTE" || {
            ip_route del "$ROUTE"
            ip_route add "$NEW_ROUTE"
            CURRENT_ROUTE="$NEW_ROUTE"
        }
    }
}

del_tmp_rout ()
{
    if  test "${REMOTE_HOST:-}" &&
        TMP_ROUTE="$(ip r | grep "^\<$REMOTE_HOST\> via")"
    then
        ip_route del "$TMP_ROUTE"
    fi
}

cleaning_and_exit ()
{
    RETURN="${RETURN:-0}"
    rm -f "$DLFILE" || RETURN=$?
    del_tmp_rout    || RETURN=$?
    exit "$RETURN"
}

trap cleaning_and_exit HUP INT TERM
include_config && del_tmp_rout && add_default_route || exit

while :
do
    echo "the current route: '$CURRENT_ROUTE'"
    if test "${REMOTE_HOST:-}"
    then
        if check_ping "$REMOTE_HOST"
        then
            echo "host is available: '$REMOTE_HOST'"
            test "$GATEWAY_NUM" -eq 1 || select_gateway
        else
            if check_ping  "$CURRENT_GATEWAY"
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
    sleep 10
done
