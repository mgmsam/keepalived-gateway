#!/bin/sh
# keepalived-gateway.sh. Gateway switcher.
#
# Copyright (c) 2025-2026 Semyon A Mironov
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

set -efu

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

if is_not_empty "${KSH_VERSION:-}"
then
    PUTS_TYPE="print" CAN_ESC_OCTAL="yes"
    puts ()
    {
        is_empty "${USE_ESC:-}" && print ${CONTINUE:+"$CONTINUE"} -r -- "$*" ||
                                   print ${CONTINUE:+"$CONTINUE"}    -- "$*"
    }
else
    if type printf
    then
        printf '%b' '\033[0m' && CAN_ESC_OCTAL="yes" ||
                                 CAN_ESC_OCTAL=""
        PUTS_TYPE="printf"
        puts ()
        {
            is_empty "${USE_ESC:-}"  && FORMAT="%s" ||
                                        FORMAT="${CAN_ESC_OCTAL:+%b}"
            is_empty "${CONTINUE:-}" && printf "${FORMAT:-%s}\n" "$*" ||
                                        printf "${FORMAT:-%s}"   "$*"
        }
    elif type echo
    then
        is_equal "X`echo -n`" "X-n" && {
            is_equal "X`echo '\033[0m'`" "X\033[0m" && CAN_ESC_OCTAL="" ||
                                                       CAN_ESC_OCTAL="yes"
            PUTS_TYPE="echo"
            puts ()
            {
                echo "$*${CONTINUE:+\c}"
            }
        } || {
            is_equal "X`echo -e`" "X-e" && {
                is_equal "X`echo '\033[0m'`" "X\033[0m" && CAN_ESC_OCTAL="" ||
                                                           CAN_ESC_OCTAL="yes"
                PUTS_TYPE="echo_n"
                puts ()
                {
                    echo ${CONTINUE:+"$CONTINUE"} "$*"
                }
            } || {
                PUTS_TYPE="echo_ne" CAN_ESC_OCTAL="yes"
                puts ()
                {
                    is_empty "${USE_ESC:-}" &&
                        echo    ${CONTINUE:+"$CONTINUE"} "$*" ||
                        echo -e ${CONTINUE:+"$CONTINUE"} "$*"
                }
            }
        }
    else
        exit 1
    fi >/dev/null 2>&1
fi

say ()
{
    RESULT=$?
    CONTINUE=""
    NO_PREFIX="no"
    USE_ESC="yes"

    while is_diff $# 0
    do
        case "${1:-}" in
            -r)
                USE_ESC=""
            ;;
            -n)
                CONTINUE="-n"
            ;;
            -p)
                NO_PREFIX="yes"
            ;;
            "" | *[!0123456789]*)
                break
            ;;
            *)
                RESULT="$1"
            ;;
        esac
        shift
    done

    is_equal "$RESULT" 0 &&
        EXIT_CODE="${EXIT_CODE:-0}" ||
        EXIT_CODE="$RESULT"

    is_empty "$*" || {
        case "$NO_PREFIX" in
            no)
                puts "${LOG_PREFIX:-$0: }${1:+$*}"
            ;;
            *)
                puts "${1:+$*}"
            ;;
        esac
        CONTINUE=""
    }
}

die ()
{
    say "$@" >&2
    exit "$EXIT_CODE"
}

eval 'ERROR=$(:)' 2>/dev/null ||
    die "error: POSIX command substitution \$(...) is not supported by this shell."

eval 'ERROR=$((0))' 2>/dev/null ||
    die "error: POSIX arithmetic expansion \$((...)) is not supported by this shell."

eval 'ERROR="${ERROR#*:}"' 2>/dev/null ||
    die "error: POSIX parameter expansion \${VAR#*}, \${VAR%*}, is not supported by this shell."

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

is_root_access ()
{
    test -w /dev/console
}

set_state ()
{
    say "switching to $1 mode"
    STATE="$1"
    LOG_PREFIX="kg [$1]: "
}

setup_core_env ()
{
    is_not_empty "${CAN_ESC_OCTAL:-}" || is_equal "$PUTS_TYPE" "printf" ||
        die 1 "error: shell environment does not support escape sequences"

    CONTINUE="-n"
    USE_ESC="${CAN_ESC_OCTAL:-}"
    LF="
"
    CR="$(puts "\r")"
    TAB="$(puts "\t")"
    SPACE=" "
    BLANK="$SPACE$TAB"
    POSIX_IFS="$SPACE$TAB$LF"
    IFS="$POSIX_IFS"
    is_file /proc/sys/kernel/ostype && OSTYPE="linux-gnu" || OSTYPE=""
}

setup_defaults ()
{
    DEFAULT_ROLE="single"
    DO_PING="no"
    DO_SPEEDTEST="no"
    IGNOREMETRIC="no"
}

include_config ()
{
    CONFIG_INCLUDED="no"
    CONFIG_FILE="/etc/keepalived-gateway.conf"

    if is_file "$CONFIG_FILE"
    then
        OUTPUT="$(. "$CONFIG_FILE" 2>&1)" &&
        . "$CONFIG_FILE" && CONFIG_INCLUDED="yes" || say "${OUTPUT#*:}"
    else
        say 2 "error: no such config file: '$CONFIG_FILE'"
    fi
}

is_interface ()
{
    case "${1:-}" in
        "")
            ERROR="is empty"
            return 1
        ;;
        *[!0-9a-zA-Z:._-]*)
            ERROR="contains invalid characters"
            return 2
        ;;
        *:*)
            ERROR="aliases are not supported, use physical device name"
            return 3
        ;;
        .*)
            ERROR="name cannot start with a dot"
            return 4
        ;;
        ????????????????*)
            ERROR="name too long (max 15)"
            return 5
        ;;
    esac
}

is_metric ()
{
    case "${1:-}" in
        "")
            ERROR="is empty"
            return 1
        ;;
        *[!0123456789]*)
            ERROR="is not a valid number"
            return 2
        ;;
        *)
    esac

    METRIC="${1#${1%%[!0]*}}"

    test ${#METRIC} -ge 10 || return 0
    test ${#METRIC} -le 10 && test "$METRIC" \< 4294967296 || {
        ERROR="exceeds 32-bit limit"
        return 3
    }
}

is_ipv4 ()
{
    IFS="."
    set -- $1
    IFS="$POSIX_IFS"

    is_equal $# 4 || {
        ERROR="invalid IPv4: address must consist of exactly 4 octets"
        return 1
    }

    for i
    do
        case "$i" in
            [0-9] | [0-9][0-9] | 1[0-9][0-9] | 2[0-4][0-9] | 25[0-5])
            ;;
            *)
                ERROR="invalid IPv4 octet: value must be between 0 and 255"
                return 2
            ;;
        esac
    done
}

is_ipv6 ()
{
    case "${1:-}" in
        *[!0-9a-fA-F:]* | *::*::*)
            ERROR="IPv6 contains multiple zero compressions (::)"
            return 1
        ;;
        *:*)
        ;;
        *)
            ERROR="invalid IPv6: address must contain at least one colon"
            return 2
        ;;
    esac
    case "$1" in
        :*)
            set -- "0$1"
        ;;
    esac
    case "$1" in
        *:)
            set -- "${1}0"
        ;;
    esac
    case "$1" in
        *:*:*:*:*:*:*:*:*)
            ERROR="IPv6 address has too many segments"
            return 3
        ;;
    esac

    _IPV6="$1"
    IFS=":"
    set -- $1
    IFS="$POSIX_IFS"

    for i
    do
        case "$i" in
            "")
                case "$_IPV6" in
                    *::*)
                    ;;
                    *)
                        ERROR="invalid IPv6: empty segment requires double colon (::) compression"
                        return 4
                    ;;
                esac
            ;;
            [0-9a-fA-F] | [0-9a-fA-F][0-9a-fA-F] | [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F] | [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            ;;
            *)
                ERROR="invalid IPv6 hextet: segment exceeds 4 hex digits or is malformed"
                return 5
            ;;
        esac
    done
}

parse_gateway_entry ()
{
    IFS="@#="
    set -- $GATEWAY
    IFS="$POSIX_IFS"

    case "${1:-}" in
        *[.:]*)
            INTERFACE=
            GATEWAY_IP="$1"
            METRIC="${2:-}"
        ;;
        *)
            INTERFACE="${1:-}"
            GATEWAY_IP="${2:-}"
            METRIC="${3:-}"
        ;;
    esac

    case "$GATEWAY_IP" in
        "")
            say 2 "error: variable 'GATEWAYS': gateway [$NUM]: gateway is empty"
        ;;
        *.*)
            is_ipv4 "$GATEWAY_IP" && FAMILY="-4" ||
                say 2 "error: variable 'GATEWAYS': gateway [$NUM]: $ERROR"
        ;;
        *)
            GATEWAY_IP="${GATEWAY_IP#[}"
            GATEWAY_IP="${GATEWAY_IP%]}"
            is_ipv6 "$GATEWAY_IP" && FAMILY="-6" ||
                say 2 "error: variable 'GATEWAYS': gateway [$NUM]: $ERROR"
        ;;
    esac

    is_empty "${INTERFACE:-}" && {
        is_not_empty "${DEFAULT_INTERFACE:-}" &&
        INTERFACE="$DEFAULT_INTERFACE" ||
            say 2 "error: variable 'GATEWAYS': gateway [$NUM]: missing interface for gateway"
    } || {
        is_interface "$INTERFACE" ||
            say 2 "error: variable 'GATEWAYS': gateway [$NUM]: interface $ERROR"
    }

    is_empty "${METRIC:-}" && {
        is_empty "${DEFAULT_METRIC:-}" || METRIC="$DEFAULT_METRIC"
    } || {
        is_metric "$METRIC" && METRIC="${METRIC#${METRIC%%[!0]*}}" ||
            say 2 "error: variable 'GATEWAYS': gateway [$NUM]: route metric $ERROR"
    }
}

collect_gateway_ipv4 ()
{
    GATEWAYS_IPV4="${GATEWAYS_IPV4:+$GATEWAYS_IPV4$LF}$INTERFACE=$GATEWAY_IP${METRIC:+=$METRIC}"
}

collect_gateway_ipv6 ()
{
    GATEWAYS_IPV6="${GATEWAYS_IPV6:+$GATEWAYS_IPV6$LF}$INTERFACE=$GATEWAY_IP${METRIC:+=$METRIC}"
}

collect_metrics_ipv4 ()
{
    case " ${METRICS_IPV4:-} " in
        *" ${METRIC:-0} "*)
        ;;
        *)
            METRICS_IPV4="${METRICS_IPV4:+$METRICS_IPV4 }${METRIC:-0}"
        ;;
    esac
}

collect_metrics_ipv6 ()
{
    case " ${METRICS_IPV6:-} " in
        *" ${METRIC:-0} "*)
        ;;
        *)
            METRICS_IPV6="${METRICS_IPV6:+$METRICS_IPV6 }${METRIC:-0}"
        ;;
    esac
}

collect_interface ()
{
    case " ${IFACES:-} " in
        *" $INTERFACE "*)
        ;;
        *)
            IFACES="${IFACES:+$IFACES }$INTERFACE"
        ;;
    esac
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

    IFS="$IFS,"
    set -- $GATEWAYS
    IFS="$POSIX_IFS"

    NUM=0
    for GATEWAY
    do
        NUM=$((NUM + 1))
        parse_gateway_entry
        case "$FAMILY" in
            -4)
                collect_gateway_ipv4
                collect_metrics_ipv4
            ;;
            -6)
                collect_gateway_ipv6
                collect_metrics_ipv6
            ;;
        esac
        is_empty "${INTERFACE:-}" || collect_interface
    done

    TOTAL_METRICS_IPV4=$(count_metrics "${METRICS_IPV4:-}")
    TOTAL_METRICS_IPV6=$(count_metrics "${METRICS_IPV6:-}")
}

parse_interval ()
{
    case "${1%[smhdwMy]}" in
        "" | *[!0123456789]*)
            return 1
        ;;
    esac
    case "$1" in
        *m) INTERVAL=$((${1%m} * 60)) ;;
        *h) INTERVAL=$((${1%h} * 3600)) ;;
        *d) INTERVAL=$((${1%d} * 86400)) ;;
        *w) INTERVAL=$((${1%w} * 604800)) ;;
        *M) INTERVAL=$((${1%M} * 2678400)) ;;
        *y) INTERVAL=$((${1%y} * 32140800)) ;;
         *) INTERVAL="${1%s}" ;;
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

    TIMESTRING=""
    test "$D" -gt 0 && TIMESTRING="${D}d" || :
    test "$H" -gt 0 && TIMESTRING="${TIMESTRING:+$TIMESTRING, }${H}h" || :
    test "$M" -gt 0 && TIMESTRING="${TIMESTRING:+$TIMESTRING, }${M}m" || :
    test "$S" -gt 0 ||
        is_empty "${TIMESTRING:-}" &&
        TIMESTRING="${TIMESTRING:+$TIMESTRING, }${S}s"

    puts "$TIMESTRING"
}

is_port ()
{
    case "${1:-}" in
        "" | *[!0123456789]*)
            ERROR="port is not a valid number"
            return 1
        ;;
        *)
            test "$1" -gt 0 && test "$1" -le 65535 || {
                ERROR="port must be in range 1-65535"
                return 2
            }
        ;;
    esac
}

parse_resource ()
{
    ERROR=""

    SCHEME=""

    USER_INFO=""
    USER=""
    PASS=""

    AUTHORITY=""
    WWW=""
    FQDN=""
    IPV4=""
    IPV6=""
    MASK=""
    PORT=""

    RESOURCE=""
    FAMILY=""

    HOST="$1"
    HOST="${HOST#${HOST%%[!$BLANK]*}}"
    HOST="${HOST%${HOST##*[!$BLANK]}}"
    case "$HOST" in
        *://*)
            SCHEME="${HOST%%://*}"
            is_not_empty "${SCHEME:-}" || {
                ERROR="protocol scheme is empty"
                return 1
            }
            HOST="${HOST#*://}"
            HOST="${HOST#${HOST%%[!/]*}}"
        ;;
    esac
    case "$HOST" in
        www.*)
            WWW=1
        ;;
    esac
    case "$HOST" in
        */*)
            AUTHORITY="${HOST%%/*}"
            RESOURCE="${HOST#*/}"
            is_not_empty "${SCHEME:-${WWW:-}}" ||
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
            case "${USER:-}" in
                "")
                ;;
                *[:@#/?]*)
                    ERROR="user: contains illegal delimiters, use URL encoding"
                    return 2
                ;;
                *[\'\"\;\|\<\>\`\$]*)
                    ERROR="user contains illegal shell characters, use URL encoding"
                    return 3
                ;;
                *[$BLANK]*)
                    ERROR="user: spaces are not allowed, use URL encoding"
                    return 4
                ;;
            esac
            case "${PASS:-}" in
                "")
                ;;
                *[\`\"\$]*)
                    ERROR="password contains illegal shell characters, use URL encoding"
                    return 5
                ;;
                *[@#/?]*)
                    ERROR="password contains illegal URL delimiters, use URL encoding"
                    return 6
                ;;
                *[$BLANK]*)
                    ERROR="password: spaces are not allowed, use URL encoding"
                    return 7
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

    is_empty "${PORT:-}" || is_port "$PORT" ||
        case $? in
            1) return 8 ;;
            *) return 9 ;;
        esac

    case "${HOST:-}" in
        "" | *[!0-9a-zA-Z.:_-]*)
            ERROR="host contains illegal characters or is empty"
            return 10
        ;;
        *[!0-9a-fA-F:]*)
            case "$HOST" in
                *[a-zA-Z]*)
                    case "$HOST" in
                        -*)
                            ERROR="domain name cannot start with a hyphen"
                            return 11
                        ;;
                        *..*)
                            ERROR="domain name contains empty labels (double dots)"
                            return 12
                        ;;
                    esac
                    FQDN="$HOST"
                ;;
                *.*.*.*)
                    is_ipv4 "$HOST" || return 13
                    IPV4="$HOST"
                    FAMILY="-4"
                ;;
                *)
                    ERROR="unrecognized host format (missing letters or invalid IPv4)"
                    return 14
                ;;
            esac
        ;;
        *:*:*)
            is_ipv6 "$HOST" ||
                case $? in
                    1) return 15 ;;
                    2) return 16 ;;
                    3) return 17 ;;
                    4) return 18 ;;
                    *) return 19 ;;
                esac
            IPV6="$HOST"
            FAMILY="-6"
        ;;
        *:*)
            ERROR="invalid port separator or malformed IPv6"
            return 20
        ;;
        *[!0-9]*)
            FQDN="$HOST"
        ;;
        *)
            ERROR="numeric-only hostnames are not allowed to avoid IP collision"
            return 21
        ;;
    esac
}

verify_config_syntax ()
{
    is_equal "$CONFIG_INCLUDED" "yes" || {
        ROLE="unknown"
        return 0
    }

    case "${ROLE:=$DEFAULT_ROLE}" in
        cluster | master | master-advisor | slave | single)
            DO_PING="yes"
            DO_SPEEDTEST="yes"
        ;;
        slave-passive)
            DO_PING="no"
            DO_SPEEDTEST="no"
        ;;
        *)
            DO_PING="no"
            DO_SPEEDTEST="no"
            say 2 "error: variable 'ROLE': must be 'cluster, master, master-advisor, single, slave'"
        ;;
    esac

    is_empty "${INTERFACE:-}" || {
        DEFAULT_INTERFACE="$INTERFACE"
        is_interface "$INTERFACE" ||
            say 2 "error: variable 'INTERFACE': $ERROR"
    }

    is_metric "${METRIC:-0}" && DEFAULT_METRIC="${METRIC:-}" ||
        say 2 "error: variable 'METRIC': route metric $ERROR"

    is_empty "${GATEWAYS:-}" && {
        is_equal "$ROLE" "slave-passive" || is_equal "$ROLE" "unknown" ||
            say 2 "error: variable 'GATEWAYS': is empty: at least one gateway is required"
    } ||
    case "${GATEWAYS:-}" in
        *[!][a-zA-Z0-9$BLANK.:_=,-]*)
            say 2 "error: variable 'GATEWAYS': contains forbidden characters"
        ;;
        *[!$BLANK,]*)
            parse_gateway
        ;;
        *)
            say 2 "error: variable 'GATEWAYS': no valid gateways found"
        ;;
    esac

    case "${METRIC_FLAG:-}" in
        "" | metric | -metric | -priority | -weight)
        ;;
        *)
            say 2 "error: variable 'METRIC_FLAG': unsupported flag"
        ;;
    esac

    parse_interval "${CHECK_INTERVAL:=30}" && {
        CHECK_INTERVAL="$INTERVAL"
        HUMAN_INTERVAL=$(format_duration "$CHECK_INTERVAL")
    } || say 2 "error: variable 'CHECK_INTERVAL': must be an integer [s|m|h|d|w|M|y]"

    is_empty "${PING_HOST:-}" && DO_PING="no" || {
        parse_resource "$PING_HOST" && {
            PING_FQDN="${FQDN:-}"
            PING_IPV4="${IPV4:-}"
            PING_IPV6="${IPV6:-}"
        } || say 2 "error: variable 'PING_HOST': $ERROR"
    }

    case "${SPEEDTEST:-}" in
        "" | 0 | [nN] | [nN][oO] | [oO][fF][fF] | [fF][aA][lL][sS][eE])
            DO_SPEEDTEST="no"
        ;;
        1 | [yY] | [yY][eE][sS] | [oO][nN] | [tT][rR][uU][eE])
            DO_SPEEDTEST="$DO_SPEEDTEST"
        ;;
        *)
            DO_SPEEDTEST="no"
            say 2 "error: variable 'SPEEDTEST': must be 'yes' or 'no'"
        ;;
    esac
    case "${SPEEDTEST_SCOPE:-}" in
        "")
        ;;
        *[\'\"\;\|\<\>\`\$]*)
            say 2 "error: variable 'SPEEDTEST_SCOPE': contains illegal shell characters"
        ;;
        /*)
            SPEEDTEST_SCOPE="${SPEEDTEST_SCOPE#/}"
        ;;
    esac

    is_empty "${SPEEDTEST_HOST:-}" && {
        is_equal "$DO_SPEEDTEST" "no" ||
            say 2 "error: variable 'SPEEDTEST_HOST': is required when 'SPEEDTEST' is enabled"
    } || {
        parse_resource "$SPEEDTEST_HOST" && {
            SPEEDTEST_SCHEME="${SCHEME:=http}"
            SPEEDTEST_HOSTNAME="${FQDN:-${IPV4:-${IPV6:-}}}"
            SPEEDTEST_FQDN="${FQDN:-}"
            SPEEDTEST_IPV4="${IPV4:-}"
            SPEEDTEST_IPV6="${IPV6:-}"
            SPEEDTEST_PORT="${PORT:-}"
            SPEEDTEST_RESOURCE="${RESOURCE:-}${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
            SPEEDTEST_RESOURCE="/${SPEEDTEST_RESOURCE#${SPEEDTEST_RESOURCE%%[!/]*}}"
            SPEEDTEST_URL="$SCHEME://$SPEEDTEST_HOSTNAME${PORT:+:$PORT}${SPEEDTEST_RESOURCE:-}"
            SPEEDTEST_NETCAT_ARGS="$SPEEDTEST_HOSTNAME ${SPEEDTEST_PORT:-80} ${SPEEDTEST_RESOURCE:-}"
        } || say 2 "error: variable 'SPEEDTEST_HOST': $ERROR"
    }

    is_empty "${VIRTUAL_IPADDRESS:-}" && {
        is_equal "$ROLE" "single" || is_equal "$ROLE" "unknown" ||
            say 2 "error: variable 'VIRTUAL_IPADDRESS' is empty: required for roles 'cluster, master, master-advisor, slave'"
    } || {
        parse_resource "$VIRTUAL_IPADDRESS" ||
            say 2 "error: variable 'VIRTUAL_IPADDRESS': $ERROR"

        is_empty "${SCHEME:-}${USER_INFO:-}${FQDN:-}${PORT:-}${RESOURCE:-}" ||
            say 2 "error: variable 'VIRTUAL_IPADDRESS': only plain IPv4/IPv6 [with CIDR] allowed"

        is_not_empty "${IPV4:-${IPV6:-}}" ||
            say 2 "error: variable 'VIRTUAL_IPADDRESS': invalid virtual IP address"

        VIP_FAMILY="${FAMILY:-}"
        VIP="${IPV4:-${IPV6:-}}"
    }

    is_empty "${VIRTUAL_PORT:-}" && {
        is_equal "$ROLE" "single" || is_equal "$ROLE" "unknown" ||
            say 2 "error: variable 'VIRTUAL_PORT': is empty: required for roles 'cluster, master, master-advisor, slave'"
    } || {
        is_port "$VIRTUAL_PORT" && VIP_PORT="$VIRTUAL_PORT" ||
            say 2 "error: variable 'VIRTUAL_PORT': $ERROR"
    }

    is_empty "${VIP:+${VIP_PORT:-}}" || {
        : "${GATEWAYS_STATE_FILE:=/tmp/keepalived-gateway/gateways.state}"
        VIP_URL="http://${VIP%/*}:$VIP_PORT/${GATEWAYS_STATE_FILE##*/}"
        VIP_NETCAT_ARGS="${VIP%/*} $VIP_PORT /${GATEWAYS_STATE_FILE##*/}"
    }
}

resolve_dependencies ()
{
    NET_TOOL=""
    AWK_UNIQUE_COLLECT='
        if (!seen[value]) {
            seen[value] = 1
            list[++count] = value
        }
    '
    AWK_NATURAL_SORT_FUNC='
        function get_nat_key(s, res, i, c, n) {
            res = ""
            i = 1
            while (i <= length(s)) {
                c = substr(s, i, 1)
                if (c ~ /[0-9]/) {
                    n = ""
                    while (i <= length(s) && substr(s, i, 1) ~ /[0-9]/) {
                        n = n substr(s, i, 1)
                        i++
                    }
                    res = res sprintf("%010d", n)
                }
                else {
                    res = res c
                    i++
                }
            }
            return res
        }
    '
    AWK_NATURAL_SORT='
        if (count == 0)
            exit 0
        for (i = 1; i <= count; i++)
            keys[i] = get_nat_key(list[i])
        for (i = 2; i <= count; i++) {
            for (j = i; j > 1 && keys[j-1] > keys[j]; j--) {
                tmp = list[j]
                list[j] = list[j-1]
                list[j-1] = tmp
                tk = keys[j]
                keys[j] = keys[j-1]
                keys[j-1] = tk
            }
        }
        for (i = 1; i <= count; i++)
            print list[i]
        for (i in list)
            delete list[i]
        for (i in keys)
            delete keys[i]
    '
    AWK_NATURAL_SORT_END='
        END {
            '"$AWK_NATURAL_SORT"'
        }
    '
    AWK_ADDRESS_PARSER='
        '"$AWK_NATURAL_SORT_FUNC"'
        /inet6?/ {
            current_family = ($0 ~ /inet6/) ? 6 : 4

            if (family == 4 && current_family == 6)
                next

            if (family == 6 && current_family == 4)
                next

            if ($0 ~ /addr:/) {
                split($0, line, "addr:")
                split(line[2], ip_mask_zone, " ")
                address = ip_mask_zone[1]
            }
            else {
                address = $2
            }

            if (address) {
                split(address, ip, "[/%]")
                value = ip[1]
                if (current_family == 4) {
                    if (!seen4[value]) {
                        seen4[value] = 1
                        list4[++count4] = value
                    }
                } else {
                    if (!seen6[value]) {
                        seen6[value] = 1
                        list6[++count6] = value
                    }
                }
            }
        }
        END {
            if (substr(family, 1, 1) == "6") {
                if (count6 > 0) {
                    count = count6
                    for (i in list6)
                        list[i] = list6[i]
                        '"$AWK_NATURAL_SORT"'
                }
                if (count4 > 0) {
                    count = count4
                    for (i in list4)
                        list[i] = list4[i]
                        '"$AWK_NATURAL_SORT"'
                }
            } else {
                if (count4 > 0) {
                    count = count4
                    for (i in list4)
                        list[i] = list4[i]
                        '"$AWK_NATURAL_SORT"'
                }
                if (count6 > 0) {
                    count = count6
                    for (i in list6)
                        list[i] = list6[i]
                        '"$AWK_NATURAL_SORT"'
                }
            }
        }
    '

    net_parser ()
    {
        FAMILY=""
        OBJECT=""
        COMMAND=""
        NET_DEVICE=""
        DESTINATION=""
        SHIFT="0"

        while is_diff $# 0
        do
            case "${1:-}" in
                -[46] | -46 | -64)
                    FAMILY="$1"
                ;;
                -d)
                    DESTINATION="$2"
                    SHIFT=$((SHIFT + 1))
                    shift
                ;;
                -i)
                    NET_DEVICE="$2"
                    SHIFT=$((SHIFT + 1))
                    shift
                ;;
                address | link | route)
                    OBJECT="$1"
                ;;
                add | del | delete | replace | show | list)
                    COMMAND="$1"
                ;;
                *)
                    DESTINATION="$1"
                    SHIFT=$((SHIFT + 1))
                    break
                ;;
            esac
            SHIFT=$((SHIFT + 1))
            shift
        done

        case "${DESTINATION:-}" in
            *:*:*)
                case "${FAMILY:-}" in
                    "" | *6*)
                        FAMILY="-6"
                    ;;
                    -4)
                        return 1
                    ;;
                esac
            ;;
            *.*.*.*)
                case "${FAMILY:-}" in
                    "" | *4*)
                        FAMILY="-4"
                    ;;
                    -6)
                        return 1
                    ;;
                esac
            ;;
        esac
    }

    if type ip >/dev/null 2>&1
    then
        NET_TOOL="ip"

        IP4="ip"
        IP6=""

        for i in -4 --inet "-f inet"
        do
            if ip $i route show
            then
                IP4="ip $i"
                break
            fi
        done >/dev/null 2>&1

        for i in -6 --inet6 "-f inet6"
        do
            if ip $i route show
            then
                IP6="ip $i"
                break
            fi
        done >/dev/null 2>&1

        run_ip ()
        {
            case "${FAMILY:-}" in
                -4)
                    $IP4 "$@"
                ;;
                -6)
                    ${IP6:-$IP4} "$@"
                ;;
                -64)
                    is_empty "${IP6:-}" || $IP6 "$@"
                    $IP4 "$@"
                ;;
                -46 | "")
                    $IP4 "$@"
                    is_empty "${IP6:-}" || $IP6 "$@"
                ;;
            esac
        }

        control_route ()
        {
            set -- "route" "$@"
            net_parser "$@" || return 0
            shift $SHIFT
            ERROR=$(run_ip "route" "$COMMAND" "$DESTINATION" "$@" 2>&1) || {
                say "$ERROR"
                return "$RESULT"
            }
        }

        show_routes ()
        {
            set -- "route" "show" "$@"
            net_parser "$@" || return 0
            shift $SHIFT
            run_ip "route" "show" ${DESTINATION:-} "$@" | awk '
                BEGIN {
                    interface = "'"${NET_DEVICE:-}"'"
                }
                {
                    if (interface == "") {
                        print $0
                        next
                    }
                    for (i = 1; i < NF; i++) {
                        if ($i == "dev") {
                            dev_value = $(i+1)
                            if (dev_value == interface) {
                                print $0
                            }
                            next
                        }
                    }
                }
            '
        }

        show_addresses ()
        {
            set -- "address" "show" "$@"
            net_parser "$@" || return 0
            shift $SHIFT
            run_ip "address" "show" ${NET_DEVICE:-${DESTINATION:-}} "$@" | awk '
                BEGIN {
                    family = "'"${FAMILY#-}"'"
                }
                '"$AWK_ADDRESS_PARSER"'
            '
        }

        show_interfaces ()
        {
            set -- "link" "show" "$@"
            net_parser "$@" || return 0
            shift $SHIFT
            run_ip "link" "show" ${NET_DEVICE:-${DESTINATION:-}} "$@" | awk '
                '"$AWK_NATURAL_SORT_FUNC"'
                /^[0-9]+:/ {
                    value = $2
                    sub(/:$/, "", value)
                    '"$AWK_UNIQUE_COLLECT"'
                }
                '"$AWK_NATURAL_SORT_END"'
            '
        }
    elif type ifconfig >/dev/null 2>&1
    then
        NET_TOOL="ifconfig"
        show_addresses ()
        {
            net_parser "$@" || return 0
            shift $SHIFT
            ifconfig -a ${NET_DEVICE:-${DESTINATION:-}} 2>/dev/null | awk '
                BEGIN {
                    family = "'"${FAMILY#-}"'"
                }
                '"$AWK_ADDRESS_PARSER"'
            '
        }

        show_interfaces ()
        {
            net_parser "$@" || return 0
            shift $SHIFT
            ifconfig -a ${NET_DEVICE:-${DESTINATION:-}} 2>/dev/null | awk '
                '"$AWK_NATURAL_SORT_FUNC"'
                /^[^ ]+ / {
                    value = $1
                    sub(/:$/, "", value)
                    '"$AWK_UNIQUE_COLLECT"'
                }
                '"$AWK_NATURAL_SORT_END"'
            '
        }
    else
        say 127 "error: environment: network check is impossible: 'ip' or 'ifconfig' not found"
    fi

    show_ports ()
    {
        netstat -an 2>/dev/null | awk '
            '"$AWK_NATURAL_SORT_FUNC"'
            $1 !~ /^tcp|^udp/ {
                next
            }
            $1 ~ /^tcp/ && $6 !~ /LISTEN/ {
                next
            }
            {
                value = $4
                while (sub(/.*[:.]/, "", value))

                if (value ~ /^[0-9]+$/) {
                    '"$AWK_UNIQUE_COLLECT"'
                }
            }
            '"$AWK_NATURAL_SORT_END"'
        '
    }

    if is_equal "${NET_TOOL:-}" "ip"
    then
        case "$ROLE" in
            single | slave | slave-passive | unknown)
            ;;
            *)
                false
        esac ||
        if type netstat >/dev/null 2>&1
        then
            :
        elif type ss >/dev/null 2>&1
        then
            show_ports ()
            {
                ss -Hnutl 2>/dev/null | awk '
                    '"$AWK_NATURAL_SORT_FUNC"'
                    $1 !~ /^tcp|^udp/ {
                        next
                    }
                    {
                        value = $5
                        sub(/.*:/, "", value)
                        if (value ~ /^[0-9]+$/) {
                            '"$AWK_UNIQUE_COLLECT"'
                        }
                    }
                    '"$AWK_NATURAL_SORT_END"'
                '
            }
        elif
            PROC_NET_TCP=""
            for i in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6
            do
                is_file $i &&
                    PROC_NET_TCP="${PROC_NET_TCP:+$PROC_NET_TCP }$i" || :
            done
            is_not_empty "${PROC_NET_TCP:-}"
        then
            show_ports ()
            {
                for i in $PROC_NET_TCP
                do
                    case "$i" in
                        *tcp*)
                            STATE_FILTER="0A"
                        ;;
                        *udp*)
                            STATE_FILTER="[0-9A-F]+"
                        ;;
                    esac
                    awk '
                        function hex2dec(h, i, x, d) {
                            h = tolower(h)
                            sub(/^0x/, "", h)
                            d = 0
                            for (i = 1; i <= length(h); i++) {
                                x = index("0123456789abcdef", substr(h, i, 1)) - 1
                                d = d * 16 + x
                            }
                            return d
                        }
                        $4 ~ /^'"$STATE_FILTER"'$/ && $2 ~ /:[0-9A-F]+$/ {
                            sub(/^[^:]+:/, "", $2)
                            $1 = hex2dec($2)
                            if ($1 ~ /^[0-9]+$/) print $1
                        }
                    ' "$i"
                done | awk '
                    '"$AWK_NATURAL_SORT_FUNC"'
                    {
                        value = $1
                        '"$AWK_UNIQUE_COLLECT"'
                    }
                    '"$AWK_NATURAL_SORT_END"'
                '
            }
        else
            say 127 "error: variable 'VIRTUAL_PORT': port check is impossible: 'ss' or 'netstat' not found"
        fi
    elif is_equal "${NET_TOOL:-}" "ifconfig"
    then
        if type netstat >/dev/null 2>&1
        then
            NETSTAT4="netstat"
            NETSTAT6=""

            for i in -4 --inet "-f inet"
            do
                if netstat $i -rn
                then
                    NETSTAT4="netstat $i"
                    break
                fi
            done >/dev/null 2>&1

            for i in -6 --inet6 "-f inet6"
            do
                if netstat $i -rn
                then
                    NETSTAT6="netstat $i"
                    break
                fi
            done >/dev/null 2>&1

            run_netstat ()
            {
                case "${FAMILY:-}" in
                    -4)
                        $NETSTAT4 "$@"
                    ;;
                    -6)
                        ${NETSTAT6:-$NETSTAT4} "$@"
                    ;;
                    -64)
                        is_empty ${NETSTAT6:-} "$@" || $NETSTAT6 "$@"
                        $NETSTAT4 "$@"
                    ;;
                    -46 | "")
                        $NETSTAT4 "$@"
                        is_empty ${NETSTAT6:-} "$@" || $NETSTAT6 "$@"
                    ;;
                esac
            }

            show_routes ()
            {
                net_parser "$@" || return 0
                shift $SHIFT
                run_netstat -rn | awk '
                    BEGIN {
                        interface = "'"${NET_DEVICE:-}"'"
                        destination = "'"${DESTINATION:-}"'"
                    }
                    $1 ~ /^([0-9a-fA-F:]+(\/[0-9]+)?|[0-9.]+(\/[0-9]+)?|default)$/ {
                        if (interface != "" && $NF != interface) {
                            next
                        }
                        if (destination != "") {
                            match_found = "no"
                            if (destination == $1) {
                                match_found = "yes"
                            } else if (
                                (
                                    destination == "0.0.0.0" ||
                                    destination == "::/0"
                                ) && (
                                    $1 == "default"
                                )
                            ) {
                                match_found = "yes"
                            } else if (
                                (
                                    destination == "default"
                                ) && (
                                    $1 == "0.0.0.0" || $1 == "::/0"
                                )
                            ) {
                                match_found = "yes"
                            }
                            if (match_found != "yes")
                                next
                        }
                        print $1, $2, $NF
                    }
                '
            }
        else
            say 127 "error: environment: routing table check impossible: 'netstat' not found"
        fi

        type route >/dev/null 2>&1 ||
            say 127 "error: environment: route management impossible: 'route' not found"
    fi

    is_equal "$DO_SPEEDTEST" "no" || {
        MISSING_DEPS=""
        for COMMAND in date wc
        do
            type "$COMMAND" ||
                MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        done >/dev/null 2>&1
        is_empty "${MISSING_DEPS:-}" ||
            say 127 "error: environment: speedtest is impossible: '$MISSING_DEPS' not found"
    }

    type awk >/dev/null 2>&1 ||
        say 127 "error: environment: parsing impossible: 'awk' not found"

    type sleep >/dev/null 2>&1 && SLEEP="sleep" || {
        SLEEP="return"
        say "WARNING: environment: continuous monitoring impossible: 'sleep' not found"
    }

    type timeout >/dev/null 2>&1 && {
        timeout -t 1 sh -c : >/dev/null 2>&1 &&
            TIMEOUT="timeout -t" ||
            TIMEOUT="timeout"
    } || say 127 "error: environment: process hang protection impossible: 'timeout' not found"

    is_equal "$ROLE" "slave-passive" || is_equal "$ROLE" "unknown" ||
        type ping >/dev/null 2>&1 ||
            say 127 "error: environment: gateway check impossible: 'ping' not found"

    return "$EXIT_CODE"
}

resolve_route ()
{
    # (RFC 5737 / RFC 3849)
    TEST_IP4="192.0.2.255"
    TEST_IP6="2001:db8::255"

    LOCAL_IP4="127.0.0.1"
    LOCAL_IP6="::1"

    ROUTE=""
    ROUTE4="route"
    ROUTE6=""

    is_not_empty "${METRIC_FLAG:-}" || {

        if is_equal "$HAS_IPV4_STACK" "yes"
        then
            for i in -4 "-f inet4" "-inet4" "-A inet4"
            do
                if route $i add "$TEST_IP4" "$LOCAL_IP4"
                then
                    route $i delete "$TEST_IP4" "$LOCAL_IP4"
                    ROUTE4="route $i"
                    break
                fi
            done
        fi

        if is_equal "$HAS_IPV6_STACK" "yes"
        then
            for i in -6 "-f inet6" "-inet6" "-A inet6"
            do
                if route $i add "$TEST_IP6" "$LOCAL_IP6"
                then
                    route $i delete "$TEST_IP6" "$LOCAL_IP6"
                    ROUTE6="route $i"
                    break
                fi
            done
        fi

        is_equal "$HAS_IPV4_STACK" "yes" && {
            ROUTE="$ROUTE4"
            DESTINATION="$TEST_IP4"
            LOCAL_IP="$LOCAL_IP4"
        } || {
            is_equal "$HAS_IPV6_STACK" "yes" && {
                ROUTE="$ROUTE6"
                DESTINATION="$TEST_IP6"
                LOCAL_IP="$LOCAL_IP6"
            } || return
        }

        for METRIC_FLAG in metric -metric -priority -weight
        do
            $ROUTE add "$DESTINATION" "$LOCAL_IP" "$METRIC_FLAG" 15 &&
                break || METRIC_FLAG=""
        done

        is_not_empty "${METRIC_FLAG:-}" || {
            $ROUTE add "$DESTINATION" "$LOCAL_IP" 15 || {
                $ROUTE add "$DESTINATION" "$LOCAL_IP" || return
                IGNOREMETRIC="yes"
            }
        }

        $ROUTE delete "$DESTINATION" "$LOCAL_IP"

    } >/dev/null 2>&1

    case "${METRIC_FLAG:-}" in
        "" | -metric | -priority | -weight)
            run_route ()
            {
                case "${FAMILY:-}" in
                    -4)
                        $ROUTE4 "$1" "$2" ${3:-} ${4:+${METRIC_FLAG:-} "$4"}
                    ;;
                    -6)
                        $ROUTE6 "$1" "$2" ${3:-} ${4:+${METRIC_FLAG:-} "$4"}
                    ;;
                esac
            }
        ;;
        metric)
            run_route ()
            {
                case "${FAMILY:-}" in
                    -4)
                        $ROUTE4 "$1" "$2" ${3:+gw $3} ${4:+dev $4} ${5:+metric $5}
                    ;;
                    -6)
                        $ROUTE6 "$1" "$2" ${3:+gw $3} ${4:+dev $4} ${5:+metric $5}
                    ;;
                esac
            }
        ;;
    esac

    control_route ()
    {
        net_parser "$@" || return 0
        shift "$SHIFT"
        ERROR=$(
            case "$COMMAND" in
                replace)
                    run_route del "$DESTINATION" 2>/dev/null || :
                    run_route add "$DESTINATION" "$@"
                ;;
                *)
                    run_route "$COMMAND" "$DESTINATION" "$@"
                ;;
            esac 2>&1
        ) || {
            say "$ERROR"
            return "$RESULT"
        }
    }
}

resolve_ping ()
{
    PING4=""
    PING6=""

    if is_equal "$HAS_IPV4_STACK" yes
    then
        ping -4 -c 1 -w 1 127.0.0.1 &&
            PING4="ping -4" ||
            PING4="ping"
    fi >/dev/null 2>&1

    if is_equal "$HAS_IPV6_STACK" yes
    then
        if ping -6 -c 1 -w 1 ::1
        then
            PING6="ping -6"
        elif type ping6 && ping6 -c 1 -w 1 ::1
        then
            PING6="ping6"
        else
            PING6=""
        fi >/dev/null 2>&1
    fi

    is_not_empty "${PING4:-${PING6:-}}"
}

resolve_fqdn ()
{
    is_empty "${PING4:-}" ||
        IPV4=$($TIMEOUT 5 $PING4 -c 1 "$1" 2>/dev/null | awk '
            /PING/ {
                gsub(/[][)(:]/, " ", $0)
                for (ip=1; ip<=NF; ip++) {
                    if ($ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                        print $ip
                        exit
                    }
                }
            }
        ') || :

    is_empty "${PING6:-}" ||
        IPV6=$($TIMEOUT 5 $PING6 -c 1 "$1" 2>/dev/null | awk '
            /PING/ {
                gsub(/[][)(]/, " ")
                for (ip=1; ip<=NF; ip++) {
                    sub(/:$/, "", $ip)
                    if ($ip ~ /^[0-9a-fA-F:]+$/ && $ip ~ /:/) {
                        print $ip
                        exit
                    }
                }
            }
        ') || :

    if is_empty "${IPV4:+${IPV6:-}}" && is_file "/etc/hosts"
    then
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
    fi

    is_not_empty "${IPV4:-${IPV6:-}}" || {
        ERROR="failed to resolve FQDN to IP address: $1"
        return 1
    }
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

is_local_ip ()
{
    is_not_empty "${1:-}" || return 1
    for IP in ${LOCAL_IP:-$(show_addresses ${2:-})}
    do
        is_diff "$IP" "$1" || return 0
    done
    return 1
}

verify_gateway_remote ()
{
    IFS="="
    set -- $GATEWAY
    IFS="$POSIX_IFS"

    case "${1:-}" in
        *[.:]*)
            GATEWAY_IP="$1"
        ;;
        *)
            GATEWAY_IP="$2"
        ;;
    esac

    if is_local_ip "$GATEWAY_IP"
    then
        ERROR="address is assigned to this host (loopback risk): $GATEWAY_IP"
        return 2
    fi
}

verify_network_state ()
{
    HAS_IPV4_STACK="no"
    HAS_IPV6_STACK="no"
    LOCAL_IP=$(show_addresses)

    for IP in ${LOCAL_IP:-}
    do
        case "$IP" in
            127.0.0.1)
                HAS_IPV4_STACK="yes"
            ;;
            ::1)
                HAS_IPV6_STACK="yes"
            ;;
        esac
        is_equal "$HAS_IPV4_STACK" "no" ||
        is_equal "$HAS_IPV6_STACK" "no" || break
    done
    is_equal "$HAS_IPV4_STACK" "yes" || is_equal "$HAS_IPV6_STACK" "yes" ||
        say "error: environment: failed to determine network stack: '127.0.0.1' and '::1' not found"

    is_equal "$NET_TOOL" ip || resolve_route ||
        say "error: environment: 'route' is unusable: network stack support check failed"

    is_equal "$ROLE" "slave-passive" || {
        if resolve_ping
        then
            is_empty "${PING_FQDN:-}" || {
                resolve_fqdn "$PING_FQDN" && {
                    PING_IPV4="${IPV4:-}"
                    PING_IPV6="${IPV6:-}"
                }
            } || say "error: variable 'PING_HOST': $ERROR"

            is_equal "$DO_SPEEDTEST" "no" || is_empty "${SPEEDTEST_FQDN:-}" || {
                resolve_fqdn "$SPEEDTEST_FQDN" && {
                    SPEEDTEST_IPV4="${IPV4:-}"
                    SPEEDTEST_IPV6="${IPV6:-}"
                }
            } || say "error: variable 'SPEEDTEST_HOST': $ERROR"
        else
            say "error: environment: 'ping' is unusable: network stack support check failed"
            DO_PING="no"
            DO_SPEEDTEST="no"
        fi

        is_empty "${GATEWAYS_IPV4:-}" || {
            GATEWAYS_IPV4=$(optimize_gateways "$GATEWAYS_IPV4")
            for GATEWAY in $GATEWAYS_IPV4
            do
                verify_gateway_remote ||
                    say "error: variable 'GATEWAYS': IPv4 $ERROR"
            done

            if is_equal "$HAS_IPV4_STACK" "yes"
            then
                is_equal "$DO_PING" "no" || is_not_empty "${PING_IPV4:-}" ||
                    say 2 "error: variable 'GATEWAYS': IPv4 monitoring is impossible: 'PING_HOST' IPv4 address is unknown"
                is_equal "$DO_SPEEDTEST" "no" || is_not_empty "${SPEEDTEST_IPV4:-}" ||
                    say 2 "error: variable 'GATEWAYS': IPv4 speedtest is impossible: 'SPEEDTEST_HOST' IPv4 address is unknown"
            else
                say "error: environment: IPv4 gateways are defined, but IPv4 stack is unavailable"
            fi
        }

        is_empty "${GATEWAYS_IPV6:-}" || {
            GATEWAYS_IPV6=$(optimize_gateways "$GATEWAYS_IPV6")
            for GATEWAY in $GATEWAYS_IPV6
            do
                verify_gateway_remote ||
                    say "error: variable 'GATEWAYS': IPv6 $ERROR"
            done

            if is_equal "$HAS_IPV6_STACK" "yes"
            then
                is_equal "$DO_PING" "no" || is_not_empty "${PING_IPV6:-}" ||
                    say 2 "error: variable 'GATEWAYS': IPv6 monitoring is impossible: 'PING_HOST' IPv6 address is unknown"
                is_equal "$DO_SPEEDTEST" "no" || is_not_empty "${SPEEDTEST_IPV6:-}" ||
                    say 2 "error: variable 'GATEWAYS': IPv6 speedtest is impossible: 'SPEEDTEST_HOST' IPv6 address is unknown"
            else
                say "error: environment: IPv6 gateways are defined, but IPv6 stack is unavailable"
            fi
        }
    }

    is_equal "$ROLE" "single" ||
    case "${VIP_FAMILY:-}" in
        -4)
            ERROR="IPv4 stack or 127.0.0.1 not found"
            is_equal "$HAS_IPV4_STACK" "yes"
        ;;
        -6)
            ERROR="IPv6 stack or ::1 not found"
            is_equal "$HAS_IPV6_STACK" "yes"
        ;;
    esac || say "error: variable 'VIRTUAL_IPADDRESS': $ERROR"

    LOCAL_IP=""
    return "$EXIT_CODE"
}

is_port_free ()
{
    show_ports | awk '
        $1 ~ /^'"$1"'$/ {
            found = "yes"
            exit
        }
        END {
            if (found == "yes") exit 1
            exit 0
        }
    '
}

resolve_server ()
{
    ERROR="sync server determination impossible"

    is_equal "$SLEEP" "sleep" ||
        say 127 "error: environment: $ERROR: 'sleep' not found"

    is_port_free "$VIP_PORT" ||
        say 1 "error: variable 'VIRTUAL_PORT': $ERROR: port $VIP_PORT is already in use"

    is_equal "$EXIT_CODE" 0 || return 0

    check_daemon ()
    {
        $@ >&2 &
        COMMAND_PID=$!
        sleep 1
        if kill -0 "$COMMAND_PID"
        then
            kill "$COMMAND_PID"
            wait "$COMMAND_PID"
            return 0
        fi 2>/dev/null
        return 1
    }

    detect_netcat_server ()
    {
        # Debian
        if check_daemon nc -l -s $LOCAL_IP -p $VIP_PORT
        then
            SERVER="nc -l -s $VIP -p $VIP_PORT"
            return 0
        fi
        # FreeBSD
        if check_daemon nc -l $LOCAL_IP $VIP_PORT
        then
            SERVER="nc -l $VIP $VIP_PORT"
            return 0
        fi
        return 1
    }

    check_gateways_state_file ()
    {
        is_dir "${GATEWAYS_STATE_FILE%/*}" ||
            OUTPUT=$(2>&1 mkdir -p "${GATEWAYS_STATE_FILE%/*}") &&
            OUTPUT=$(2>&1 > "$GATEWAYS_STATE_FILE") ||
                say "error: $OUTPUT"
    }

    case "${VIP_FAMILY:-}" in
        -4)
            LOCAL_IP="127.0.0.1"
            BIND_IP="$LOCAL_IP"
        ;;
        -6)
            LOCAL_IP="::1"
            BIND_IP="[$LOCAL_IP]"
        ;;
    esac

    SERVE_GATEWAYS=""
    MISSING_DEPS=""
    SYNC_SERVER_LIST="nc uhttpd httpd telnetd"
    for COMMAND in $SYNC_SERVER_LIST
    do
        say -n "environment: role '$ROLE': server '$COMMAND':"
        if type "$COMMAND" >/dev/null 2>&1
        then
            say -n -p " probing server IPv${VIP_FAMILY#-} capability..."
            case "$COMMAND" in
                nc)
                    detect_netcat_server &&
                        SERVE_GATEWAYS="serve_netcat"
                ;;
                uhttpd | httpd)
                    check_daemon $COMMAND -f -p $BIND_IP:$VIP_PORT && {
                        SERVE_GATEWAYS="serve_httpd"
                        is_equal "$VIP_FAMILY" IPv4 &&
                            SERVER="$COMMAND -f -p $VIP:$VIP_PORT" ||
                            SERVER="$COMMAND -f -p [$VIP]:$VIP_PORT"
                    }
                ;;
                telnetd)
                    check_daemon $COMMAND -F -p $VIP_PORT -b $LOCAL_IP && {
                        SERVE_GATEWAYS="serve_telnetd"
                        SERVER="$COMMAND -F -p $VIP_PORT -b $VIP -l : -K"
                    }
                ;;
            esac >/dev/null 2>&1 && {
                say -p " [ OK ]"
                break
            } || say 0 -p " [ FAILED ]"
        else
            say 0 -p " not found"
            MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        fi
    done
    case "${SERVE_GATEWAYS:-}" in
        "")
            say 127 "error: environment: $ERROR: '$MISSING_DEPS' not found"
        ;;
        serve_httpd | serve_telnetd )
            check_gateways_state_file
        ;;
    esac
    LOCAL_IP=""
}

is_supported_scheme ()
{
    case " $1 " in
        *" $SPEEDTEST_SCHEME "*)
            return 0
        ;;
    esac
    return 1
}

detect_curl_client ()
{
    OUTPUT=$(2>&1 curl $1://$2:1 || :)
    case "${OUTPUT:-}" in
        *[Cc]onnect*)
            return 0
        ;;
        *[Pp]rotocol*)
            STATUS=" [unsupported scheme ‘$1’]"
            return 1
        ;;
        *URL* | *resolve*)
            STATUS=" [$3 unsupported]"
            return 2
        ;;
        *)
            STATUS=" [undefined error]"
            return 3
    esac
}

detect_fetch_client ()
{
    OUTPUT=$(2>&1 fetch $1://$2:1 || :)
    case "${OUTPUT:-}" in
        *[Cc]onnection*)
            return 0
        ;;
        *URL*)
            STATUS=" [unsupported scheme ‘$1’]"
            return 1
        ;;
        *address*)
            STATUS=" [$3 unsupported]"
            return 2
        ;;
        *)
            STATUS=" [undefined error]"
            return 3
    esac
}

detect_netcat_client ()
{
    OUTPUT=$(2>&1 nc $2 1 || :)
    case "${OUTPUT:-}" in
        "" | *[Cc]onnection*)
            return 0
        ;;
        *family* | *resolve*)
            STATUS=" [$3 unsupported]"
            return 1
        ;;
        *)
            STATUS=" [undefined error]"
            return 3
    esac
}

detect_wget_client ()
{
    OUTPUT=$(2>&1 wget $1://$2:1 || :)
    case "${OUTPUT:-}" in
        *[Cc]onnection*)
            return 0
        ;;
        *family* | *socket*)
            STATUS=" [$3 unsupported]"
            return 1
        ;;
        *support* | *http* | *ftp*)
            STATUS=" [unsupported scheme ‘$1’]"
            return 2
        ;;
        *)
            STATUS=" [undefined error]"
            return 3
    esac
}

probe_speedtest_fetcher ()
{
    is_not_empty "${FETCH_SPEEDTEST_IPV4:-}" || {
        is_empty "${SPEEDTEST_IPV4:-}" || {
            say 0 -n "$PREFIX: probing speedtest IPv4 capability..."
            $1 "$SPEEDTEST_SCHEME" 127.0.0.1 IPv4 && {
                FETCH_SPEEDTEST_IPV4="$2 ${SPEEDTEST_TARGET:-}"
                say -p " [ OK ]"
            } || say -p "$STATUS"
        }
    }
    is_not_empty "${FETCH_SPEEDTEST_IPV6:-}" || {
        is_empty "${SPEEDTEST_IPV6:-}" || {
            say 0 -n "$PREFIX: probing speedtest IPv6 capability..."
            $1 "$SPEEDTEST_SCHEME" [::1] IPv6 && {
                FETCH_SPEEDTEST_IPV6="$2 ${SPEEDTEST_TARGET:-}"
                say -p " [ OK ]"
            } || say -p "$STATUS"
        }
    }
}

probe_gateway_fetcher ()
{
    case "$ROLE" in
        cluster | slave | slave-passive)
            is_not_empty "${FETCH_GATEWAYS:-}" || {
                if is_equal "$VIP_FAMILY" "-4"
                then
                    say 0 -n "$PREFIX: probing gateway sync IPv4 capability..."
                    is_equal "${SPEEDTEST_SCHEME:-}" http &&
                    is_not_empty "${FETCH_SPEEDTEST_IPV4:-}" ||
                        $1 http 127.0.0.1 IPv4
                else
                    say 0 -n "$PREFIX: probing gateway sync IPv6 capability..."
                    is_equal "${SPEEDTEST_SCHEME:-}" http &&
                    is_not_empty "${FETCH_SPEEDTEST_IPV6:-}" ||
                        $1 http [::1] IPv6
                fi && {
                    FETCH_GATEWAYS="$2 $VIP_TARGET"
                    say -p " [ OK ]"
                } || say -p "$STATUS"
            }
        ;;
    esac
}

probe_client_capabilities ()
{
    is_equal "$DO_SPEEDTEST" "no" ||
    is_not_empty "${FETCH_SPEEDTEST_IPV4:+${FETCH_SPEEDTEST_IPV6:-}}" ||
    if is_supported_scheme "$3"
    then
        probe_speedtest_fetcher $1 $2
    else
        say "$PREFIX: speedtest: [unsupported scheme ‘$SPEEDTEST_SCHEME’]"
    fi

    probe_gateway_fetcher $1 $2
    return "$EXIT_CODE"
}

resolve_client ()
{
    MISSING_DEPS=""
    FETCH_GATEWAYS=""
    FETCH_SPEEDTEST_IPV4=""
    FETCH_SPEEDTEST_IPV6=""
    CLIENT_LIST="curl fetch wget nc"
    for COMMAND in $CLIENT_LIST
    do
        PREFIX="environment: role '$ROLE': client '$COMMAND'"
        say -n "$PREFIX:"
        if type "$COMMAND" >/dev/null 2>&1
        then
            say 0 -p " found"
            case "$COMMAND" in
                curl)
                    SPEEDTEST_TARGET="${SPEEDTEST_URL:-}"
                    VIP_TARGET="${VIP_URL:-}"
                    probe_client_capabilities detect_curl_client fetch_curl "http https ftp sftp ftps tftp file scp"
                ;;
                fetch)
                    SPEEDTEST_TARGET="${SPEEDTEST_URL:-}"
                    VIP_TARGET="${VIP_URL:-}"
                    probe_client_capabilities detect_fetch_client fetch_fetch "http https ftp"
                ;;
                nc)
                    SPEEDTEST_TARGET="${SPEEDTEST_NETCAT_ARGS:-}"
                    VIP_TARGET="${VIP_NETCAT_ARGS:-}"
                    probe_client_capabilities detect_netcat_client fetch_netcat http
                ;;
                wget)
                    SPEEDTEST_TARGET="${SPEEDTEST_URL:-}"
                    VIP_TARGET="${VIP_URL:-}"
                    probe_client_capabilities detect_wget_client fetch_wget "http https ftp ftps"
                ;;
            esac && {
                EXIT_CODE="0"
                return
            } || continue
        else
            say 0 -p " not found"
            MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        fi
    done
}

resolve_transfer_tools ()
{
    case "$ROLE" in
        cluster)
            resolve_server
            resolve_client
        ;;
        master | master-advisor)
            resolve_server
            is_equal "$DO_SPEEDTEST" "no" || resolve_client
        ;;
        single)
            is_equal "$DO_SPEEDTEST" "no" || resolve_client
        ;;
        slave | slave-passive)
            resolve_client
        ;;
        *)
            EXIT_CODE="1"
        ;;
    esac
    return "$EXIT_CODE"
}

remove_routes ()
{
    while read ROUTE
    do
        say -n "removing IPv${1#-} route '$ROUTE' ..."
        control_route ${1:-} del $ROUTE >/dev/null 2>&1 &&
            say -p " [ OK ]" ||
            say -p " [ FAILED ]"
    done <<EOF
$REMOVE_ROUTES
EOF
}

remove_test_route ()
{
    REMOVE_ROUTES=""

    for IP in ${PING_IPV4:-} ${SPEEDTEST_IPV4:-}
    do
        ROUTE=$(show_routes -4 "$IP")
        is_empty "${ROUTE:-}" ||
            REMOVE_ROUTES="${REMOVE_ROUTES:+$REMOVE_ROUTES$LF}$ROUTE"
    done

    is_empty "${REMOVE_ROUTES:-}" || {
        remove_routes -4
        REMOVE_ROUTES=""
    }

    for IP in ${PING_IPV6:-} ${SPEEDTEST_IPV6:-}
    do
        ROUTE=$(show_routes -6 "$IP")
        is_empty "${ROUTE:-}" ||
            REMOVE_ROUTES="${REMOVE_ROUTES:+$REMOVE_ROUTES$LF}$ROUTE"
    done

    is_empty "${REMOVE_ROUTES:-}" || {
        remove_routes -6
        REMOVE_ROUTES=""
    }

    return "$EXIT_CODE"
}

clean_and_exit ()
{
    EXIT_CODE="${1:-$?}"
    puts
    trap - 0
    remove_test_route || :
    is_empty "${GATEWAY_SERVER_PID:-}" || kill "$GATEWAY_SERVER_PID" 2>/dev/null
    exit "$EXIT_CODE"
}

loop ()
{
    :
}

split_gateway ()
{
    IFS="="
    read INTERFACE GATEWAY_IP METRIC <<EOF
$1
EOF
    IFS="$POSIX_IFS"
}

format_route ()
{
    split_gateway "$GATEWAY"

    case "$GATEWAY_IP" in
        *:*)
            FAMILY="-6"
            PING="${PING6:-}"
            PING_IP="${PING_IPV6:-}"
            SPEEDTEST_IP="${SPEEDTEST_IPV6:-}"
            FETCH_SPEEDTEST="${FETCH_SPEEDTEST_IPV6:-}"
        ;;
        *)
            FAMILY="-4"
            PING="${PING4:-}"
            PING_IP="${PING_IPV4:-}"
            SPEEDTEST_IP="${SPEEDTEST_IPV4:-}"
            FETCH_SPEEDTEST="${FETCH_SPEEDTEST_IPV4:-}"
        ;;
    esac

    is_equal "$NET_TOOL" "ip" && {
        ROUTE="default via $GATEWAY_IP dev $INTERFACE${METRIC:+ metric $METRIC}"
        SPEEDTEST_ROUTE="${SPEEDTEST_IP:-} via $GATEWAY_IP dev $INTERFACE"
        PING_ROUTE="${PING_IP:-} via $GATEWAY_IP dev $INTERFACE"
    } || {
        ROUTE="default $GATEWAY_IP $INTERFACE ${METRIC:-}"
        SPEEDTEST_ROUTE="${SPEEDTEST_IP:-} $GATEWAY_IP $INTERFACE"
        PING_ROUTE="${PING_IP:-} $GATEWAY_IP $INTERFACE"
    }
}

collect_dead_route ()
{
    case "$FAMILY" in
        -4)
            DEAD_ROUTES_IPV4="${DEAD_ROUTES_IPV4:+$DEAD_ROUTES_IPV4$LF}$ROUTE"
        ;;
        -6)
            DEAD_ROUTES_IPV6="${DEAD_ROUTES_IPV6:+$DEAD_ROUTES_IPV6$LF}$ROUTE"
        ;;
    esac
}

check_ping ()
{
    $TIMEOUT "${PING_TIMEOUT:=3}" $PING -c "${PING_COUNT:=3}" "$@" >/dev/null 2>&1
}

collect_alive_route ()
{
    case "$FAMILY" in
        -4)
            ALIVE_COUNT_IPV4=$((ALIVE_COUNT_IPV4 + 1))
            ALIVE_GATEWAYS_IPV4="${ALIVE_GATEWAYS_IPV4:+$ALIVE_GATEWAYS_IPV4 }$GATEWAY"
            ALIVE_METRICS_IPV4="${ALIVE_METRICS_IPV4:+$ALIVE_METRICS_IPV4 }${METRIC:-0}"
            ALIVE_ROUTES_IPV4="${ALIVE_ROUTES_IPV4:+$ALIVE_ROUTES_IPV4$LF}$ROUTE"
        ;;
        -6)
            ALIVE_COUNT_IPV6=$((ALIVE_COUNT_IPV6 + 1))
            ALIVE_GATEWAYS_IPV6="${ALIVE_GATEWAYS_IPV6:+$ALIVE_GATEWAYS_IPV6 }$GATEWAY"
            ALIVE_METRICS_IPV6="${ALIVE_METRICS_IPV6:+$ALIVE_METRICS_IPV6 }${METRIC:-0}"
            ALIVE_ROUTES_IPV6="${ALIVE_ROUTES_IPV6:+$ALIVE_ROUTES_IPV6$LF}$ROUTE"
        ;;
    esac
}

check_gateways ()
{
    is_not_empty "${DEFAULT_GATEWAYS_IPV4:-}${DEFAULT_GATEWAYS_IPV6:-}" ||
        return

    RESULT="0"

    ALIVE_COUNT_IPV4="0"
    ALIVE_GATEWAYS_IPV4=""
    ALIVE_METRICS_IPV4=""
    ALIVE_ROUTES_IPV4=""
    DEAD_ROUTES_IPV4=""

    ALIVE_COUNT_IPV6="0"
    ALIVE_GATEWAYS_IPV6=""
    ALIVE_METRICS_IPV6=""
    ALIVE_ROUTES_IPV6=""
    DEAD_ROUTES_IPV6=""

    for GATEWAY in ${DEFAULT_GATEWAYS_IPV4:-} ${DEFAULT_GATEWAYS_IPV6:-}
    do
        format_route
        puts
        say "checking active IPv${FAMILY#-} route: '$ROUTE'"
        is_interface "$INTERFACE" || {
            say "interface '$INTERFACE' is not available for gateway '$GATEWAY_IP'"
            collect_dead_route
            continue
        }
        if is_equal "$DO_PING" "yes"
        then
            control_route "$FAMILY" replace $PING_ROUTE || return
            check_ping -I "$INTERFACE" "$PING_IP" || {
                control_route "$FAMILY" del $PING_ROUTE || return
                say "host '$PING_HOST' is unreachable via route '$ROUTE'"
                collect_dead_route
                continue
            }
            control_route "$FAMILY" del $PING_ROUTE || return
        else
            check_ping -I "$INTERFACE" "$GATEWAY_IP" || {
                say "gateway '$GATEWAY_IP' is unreachable on interface '$INTERFACE'"
                collect_dead_route
                continue
            }
        fi
        say "alive active route: '$ROUTE'"
        collect_alive_route
    done

    is_equal "$ALIVE_COUNT_IPV4" "$TOTAL_METRICS_IPV4" || {
        is_empty "${DEAD_ROUTES_IPV4:-}" ||
            say "dead IPv4 routes detected:\n  $DEAD_ROUTES_IPV4"
    }
    is_equal "$ALIVE_COUNT_IPV6" "$TOTAL_METRICS_IPV6" || {
        is_empty "${DEAD_ROUTES_IPV6:-}" ||
            say "dead IPv6 routes detected:\n  $DEAD_ROUTES_IPV6"
    }

    return "$RESULT"
}

collect_gateway ()
{
    case "$FAMILY" in
        -4)
            DEFAULT_GATEWAYS_IPV4="${DEFAULT_GATEWAYS_IPV4:+$DEFAULT_GATEWAYS_IPV4 }$BEST_GATEWAY"
        ;;
        -6)
            DEFAULT_GATEWAYS_IPV6="${DEFAULT_GATEWAYS_IPV6:+$DEFAULT_GATEWAYS_IPV6 }$BEST_GATEWAY"
        ;;
    esac
    BEST_GATEWAY=""
}

collect_route ()
{
    case "$FAMILY" in
        -4)
            DEFAULT_ROUTES_IPV4="${DEFAULT_ROUTES_IPV4:+$DEFAULT_ROUTES_IPV4$LF}$BEST_ROUTE"
        ;;
        -6)
            DEFAULT_ROUTES_IPV6="${DEFAULT_ROUTES_IPV6:+$DEFAULT_ROUTES_IPV6$LF}$BEST_ROUTE"
        ;;
    esac
    BEST_ROUTE=""
}

is_empty_alive_metrics ()
{
    case "$FAMILY" in
        -4)
            is_empty "${ALIVE_METRICS_IPV4:-}" || return
        ;;
        -6)
            is_empty "${ALIVE_METRICS_IPV6:-}" || return
        ;;
    esac
}

is_metric_alive ()
{
    case "$FAMILY" in
        -4)
            case " $ALIVE_METRICS_IPV4 " in
                *" ${METRIC:-0} "*)
                    return 0
                ;;
            esac
        ;;
        -6)
            case " $ALIVE_METRICS_IPV6 " in
                *" ${METRIC:-0} "*)
                    return 0
                ;;
            esac
        ;;
    esac
    return 1
}

is_failed_metric ()
{
    is_metric_alive && return 1 || return 0
}

get_time ()
{
    date "+%s"
}

speedtest ()
{
    FETCH_TIMEOUT="${SPEEDTEST_TIMEOUT:=15}"
    START_SPEEDTEST=$(get_time)
    BYTE=$(2>/dev/null $FETCH_SPEEDTEST | wc -c)
    END_SPEEDTEST=$(get_time)
    BYTE=$(( ${BYTE:-0} + 0 ))
    DURATION=$((END_SPEEDTEST - START_SPEEDTEST))
    test "$DURATION" -gt 0 || DURATION=1
    test "$BYTE" -gt 1024 && BIT=$(( (BYTE * 8) / DURATION ))
}

bit2Human ()
{
    BIT="${1:-0}" REMAINS="" SIZE=1
    while test "$BIT" -ge 1000
    do
        REMAINS=$(( (BIT % 1000) / 10 ))
        if test "$REMAINS" -lt 10
        then
            REMAINS=".0$REMAINS"
        else
            REMAINS=".$REMAINS"
        fi
        BIT=$((BIT / 1000))
        SIZE=$((SIZE + 1))
    done
    set -- bit Kbit Mbit Gbit Tbit Ebit Pbit Zbit Ybit
    shift $((SIZE - 1))
    UNIT="$1"
    puts "$BIT${REMAINS:-} $UNIT"
}

evaluate_speed ()
{
    say "measuring speed to host: '$SPEEDTEST_HOST' using route '$SPEEDTEST_ROUTE'"

    control_route "$FAMILY" replace $SPEEDTEST_ROUTE || return
    if speedtest
    then
        test "$BEST_SPEED" -ge "$BIT" || {
            BEST_GATEWAY="$GATEWAY"
            BEST_ROUTE="$ROUTE"
            BEST_SPEED="$BIT"
        }
        control_route "$FAMILY" del $SPEEDTEST_ROUTE || return
        say "measured speed: $(bit2Human "$BIT")/s for gateway: '$GATEWAY_IP' on '$INTERFACE'"
    else
        control_route "$FAMILY" del $SPEEDTEST_ROUTE || return
        say "failed to measure speed from '$SPEEDTEST_HOST' using route '$SPEEDTEST_ROUTE'"
        return 1
    fi
}

evaluate_host ()
{
    say "probing host address: '$PING_HOST' using route '$PING_ROUTE'"
    control_route "$FAMILY" replace $PING_ROUTE || return
    check_ping -I "$INTERFACE" "$PING_IP" && {
        control_route "$FAMILY" del $PING_ROUTE || return
        say "reachable host address: '$PING_HOST' using route '$PING_ROUTE'"
        BEST_GATEWAY="$GATEWAY"
        BEST_ROUTE="$ROUTE"
    } || {
        control_route "$FAMILY" del $PING_ROUTE || return
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

add_routes ()
{
    puts
    while read ROUTE
    do
        say -n "applying IPv${1#-} route '$ROUTE'..."
        control_route "$1" replace $ROUTE >/dev/null 2>&1 &&
            say -p " [ OK ]" ||
            say -p " [ FAILED ]"
    done <<EOF
$2
EOF
}

get_current_routes ()
{
    CURRENT_ROUTES=""
    for INTERFACE in $IFACES
    do
        if ROUTES=$(show_routes "$1" -i "$INTERFACE" "default")
        then
            while read ROUTE
            do
                ROUTE=$(puts $ROUTE)
                CURRENT_ROUTES="${CURRENT_ROUTES:+$CURRENT_ROUTES$LF}$ROUTE"
            done <<EOF
$ROUTES
EOF
        fi
    done 2>/dev/null
    is_not_empty "${CURRENT_ROUTES:-}" || return
}

get_obsolete_routes ()
{
    OBSOLETE_FILTER='
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
    '
    REMOVE_ROUTES=$(awk "$OBSOLETE_FILTER" <<EOF
$1

$CURRENT_ROUTES
EOF
    )
    is_not_empty "${REMOVE_ROUTES:-}" || return
}

remove_obsolete_routes ()
{
    puts
    remove_routes "$1"
}

refresh_routing_table ()
{
    EXIT_CODE="0"
    is_empty "${DEFAULT_GATEWAYS_IPV4:-}" || {
        add_routes -4 "$DEFAULT_ROUTES_IPV4" &&
        get_current_routes -4 &&
        get_obsolete_routes "$DEFAULT_ROUTES_IPV4" &&
        remove_obsolete_routes -4 || :
    }
    is_empty "${DEFAULT_GATEWAYS_IPV6:-}" || {
        add_routes -6 "$DEFAULT_ROUTES_IPV6" &&
        get_current_routes -6 &&
        get_obsolete_routes "$DEFAULT_ROUTES_IPV6" &&
        remove_obsolete_routes -6 || :
    }
}

update_gateways_state ()
{
    DEFAULT_GATEWAYS="${DEFAULT_GATEWAYS_IPV4:--}$LF${DEFAULT_GATEWAYS_IPV6:--}"
}

reconcile_gateways ()
{
    DEFAULT_GATEWAYS_IPV4="${ALIVE_GATEWAYS_IPV4:-}"
    DEFAULT_GATEWAYS_IPV6="${ALIVE_GATEWAYS_IPV6:-}"
    DEFAULT_ROUTES_IPV4="${ALIVE_ROUTES_IPV4:-}"
    DEFAULT_ROUTES_IPV6="${ALIVE_ROUTES_IPV6:-}"
    CURRENT_FAMILY=""
    CURRENT_METRIC=""
    BEST_GATEWAY=""
    BEST_ROUTE=""
    BEST_SPEED=0

    while loop
    do
        for GATEWAY in ${GATEWAYS_IPV4:-} ${GATEWAYS_IPV6:-}
        do
            format_route
            puts
            say "testing IPv${FAMILY#-} gateway '$GATEWAY_IP' dev '$INTERFACE'${METRIC:+ with metric $METRIC}"

            is_equal "${CURRENT_FAMILY:-}" "$FAMILY" &&
            is_equal "${CURRENT_METRIC:-}" "${METRIC:-0}" || {
                is_empty "${BEST_ROUTE:-}" || {
                    collect_gateway
                    collect_route
                    BEST_SPEED=0
                }
                is_empty_alive_metrics || is_failed_metric || {
                    say "skipping gateway: active route already found with metric '${METRIC:-0}'"
                    continue
                }
                CURRENT_FAMILY="$FAMILY"
                CURRENT_METRIC="${METRIC:-0}"
            }

            is_interface "$INTERFACE" || {
                say "interface not found or down: '$INTERFACE'"
                continue
            }

            is_equal "$DO_SPEEDTEST" "yes" && evaluate_speed ||
            if is_empty "${BEST_ROUTE:-}"
            then
                if is_equal "$DO_PING" "yes"
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

        is_empty "${DEFAULT_GATEWAYS_IPV4:-}${DEFAULT_GATEWAYS_IPV6:-}" || break

        puts
        say "WARNING: no alive gateways found, retrying in 1s..."
        is_diff "$STATE" "slave" || return

        sleep 1
    done

    is_equal "$ROLE" "master-advisor" || refresh_routing_table
    update_gateways_state
}

say_gateways_state ()
{
    puts
    say "optimized gateway state:"
    say "  IPv4 [${DEFAULT_GATEWAYS_IPV4:-no alive gateways provided}]"
    say "  IPv6 [${DEFAULT_GATEWAYS_IPV6:-no alive gateways provided}]"
}

save_gateways_state ()
{
    case "${SERVE_GATEWAYS:-}" in
        "" | serve_netcat)
            return
        ;;
    esac
    is_dir "${GATEWAYS_STATE_FILE%/*}" ||
    OUTPUT=$(2>&1 mkdir -p "${GATEWAYS_STATE_FILE%/*}") || {
        say "error: $OUTPUT"
        return 1
    } >&2
    puts "$DEFAULT_GATEWAYS" > "$GATEWAYS_STATE_FILE.tmp" &&
    mv "$GATEWAYS_STATE_FILE.tmp" "$GATEWAYS_STATE_FILE"  || {
        say "error: failed to update gateways state file: '$GATEWAYS_STATE_FILE'"
        return 1
    } >&2
}

is_vrrp_master ()
{
    is_local_ip "$VIP" "$VIP_FAMILY" >/dev/null 2>&1
}

is_process_alive ()
{
    is_not_empty "${1:-}" &&
    is_dir "/proc/$1"
}

serve_netcat ()
{
    trap '
        trap - 0
        kill $NETCAT_PID 2>/dev/null
        exit
    ' 0 1 2 15

    while loop
    do
        $SERVER <<EOF &
HTTP/1.1 200 OK$CR
Content-Type: text/plain$CR
Content-Length: ${#DEFAULT_GATEWAYS}$CR
Connection: close$CR
$CR
$DEFAULT_GATEWAYS
EOF
        NETCAT_PID=$!
        wait $NETCAT_PID
    done >/dev/null 2>&1
}

serve_httpd ()
{
    $SERVER -h "${GATEWAYS_STATE_FILE%/*}"
}

serve_telnetd ()
{
    $SERVER -f "$GATEWAYS_STATE_FILE"
}

stop_serve_gateways ()
{
    if is_process_alive "${GATEWAY_SERVER_PID:-}"
    then
        kill "$GATEWAY_SERVER_PID" 2>/dev/null || :
        GATEWAY_SERVER_PID=""
        say "gateway server stopped"
    fi
}

serve_gateways ()
{
    is_vrrp_master || {
        say "virtual IP not found on this host: '$VIP'"
        return 1
    }

    is_process_alive "${GATEWAY_SERVER_PID:-}" || {
        is_port_free "$VIP_PORT" || {
            say "error: cannot start sync server, port $VIP_PORT is busy"
            return
        } >&2

        $SERVE_GATEWAYS 2>&1 &
        GATEWAY_SERVER_PID=$!
        sleep 1

        if is_process_alive "$GATEWAY_SERVER_PID"
        then
            say "gateway server successfully started on port $VIP_PORT"
        else
            GATEWAY_SERVER_PID=""
            say "error: gateway server failed to start (check system logs)"
        fi >&2
    }
}

fetch_curl ()
{
    $TIMEOUT $FETCH_TIMEOUT curl -o - "$@"
}

fetch_fetch ()
{
    $TIMEOUT $FETCH_TIMEOUT fetch -o - "$@"
}

strip_headers ()
{
    awk '
        BEGIN {
            body = 0
        }
        {
            gsub(/\r/, "")
            if (!body && $0 ~ /^[[:space:]]*$/) {
                body = 1
                next
            }
            if (body) {
                if ($0 ~ /^\377/)
                    next
                if ($0 !~ /^[[:space:]]*$/) {
                    if (first_line_done)
                        printf "\n"
                        printf "%s", $0
                        first_line_done = 1
                }
            }
        }
    '
}

fetch_netcat ()
{
    {
        $TIMEOUT $FETCH_TIMEOUT nc "$1" "$2" <<EOF | strip_headers
GET ${3:-/} HTTP/1.0$CR
Host: ${1}$CR
Connection: close$CR
$CR
EOF
    } ||
    case $? in
        124)
            return 0
        ;;
        *)
            return $?
        ;;
    esac
}

fetch_wget ()
{
    $TIMEOUT $FETCH_TIMEOUT wget -O - "$@"
}

fetch_gateways ()
{
    COUNT=0
    RETRIES=3
    SUCCESS=1

    puts
    say -n "attempting to fetch gateway state from master ($VIP)..."
    FETCH_TIMEOUT=1
    while is_diff $COUNT $RETRIES
    do
        FETCHED_GATEWAYS=$($FETCH_GATEWAYS) && {
            SUCCESS=0
            break
        } || COUNT=$((COUNT + 1))
    done 2>/dev/null

    is_equal $SUCCESS 0 && say -p " [ OK ]" || {
        say -p " [ ERROR ]"
        say "error: ${FETCHED_GATEWAYS:-failed to fetch alive gateways list}"
        FETCHED_GATEWAYS=""
        return 1
    } >&2

    is_not_empty "${FETCHED_GATEWAYS:-}" || {
        say "error: received empty or invalid gateway state from master ($VIP)"
        return 1
    } >&2

    FETCHED_GATEWAYS_IPV4="${FETCHED_GATEWAYS%$LF*}"
    FETCHED_GATEWAYS_IPV6="${FETCHED_GATEWAYS#*$LF}"
    FETCHED_GATEWAYS_IPV4="${FETCHED_GATEWAYS_IPV4#-}"
    FETCHED_GATEWAYS_IPV6="${FETCHED_GATEWAYS_IPV6#-}"

    say "received remote state from master ($VIP):"
    say "  IPv4 [${FETCHED_GATEWAYS_IPV4:-no alive gateways provided}]"
    say "  IPv6 [${FETCHED_GATEWAYS_IPV6:-no alive gateways provided}]"

    is_equal "$IGNOREMETRIC" no || {
        FETCHED_GATEWAYS_IPV4="${FETCHED_GATEWAYS_IPV4%%$SPACE*}"
        FETCHED_GATEWAYS_IPV6="${FETCHED_GATEWAYS_IPV6%%$SPACE*}"

        split_gateway "$FETCHED_GATEWAYS_IPV4"
        FETCHED_GATEWAYS_IPV4="${GATEWAY_IP:+$INTERFACE=$GATEWAY_IP}"

        split_gateway "$FETCHED_GATEWAYS_IPV6"
        FETCHED_GATEWAYS_IPV6="${GATEWAY_IP:+$INTERFACE=$GATEWAY_IP}"

        FETCHED_GATEWAYS="${FETCHED_GATEWAYS_IPV4:--}$LF${FETCHED_GATEWAYS_IPV6:--}"
    }

    is_not_empty "${FETCHED_GATEWAYS_IPV4:-}${FETCHED_GATEWAYS_IPV6:-}" ||
        FETCHED_GATEWAYS=""
}

sync_gateways ()
{
    is_not_empty "${FETCHED_GATEWAYS:-}" || return 0

    is_diff "$FETCHED_GATEWAYS" "${DEFAULT_GATEWAYS:-}" || {
        say "local routing state is already up to date"
        refresh_routing_table
        return
    }
    say "applying new gateway configuration from master ($VIP)\n"

    DEFAULT_GATEWAYS_IPV4=""
    DEFAULT_GATEWAYS_IPV6=""
    DEFAULT_ROUTES_IPV4=""
    DEFAULT_ROUTES_IPV6=""

    for GATEWAY in ${FETCHED_GATEWAYS_IPV4:-} ${FETCHED_GATEWAYS_IPV6:-}
    do
        format_route
        say "configuring IPv${FAMILY#-} gateway '$GATEWAY_IP' dev '$INTERFACE'${METRIC:+ with metric $METRIC}"
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
    update_gateways_state
}

run_single_mode ()
{
    puts
    set_state "$ROLE"
    while loop
    do
        check_gateways || reconcile_gateways
        say_gateways_state
        say "next check cycle in: '$HUMAN_INTERVAL'"
        sleep "$CHECK_INTERVAL"
    done
}

run_master_mode ()
{
    GATEWAY_SERVER_PID=""
    puts
    set_state "$ROLE"
    while loop
    do
        check_gateways || {
            reconcile_gateways
            save_gateways_state
        } && serve_gateways || stop_serve_gateways
        say_gateways_state
        say "next check cycle in: '$HUMAN_INTERVAL'"
        sleep "$CHECK_INTERVAL"
    done
}

run_slave_mode ()
{
    puts
    set_state "$ROLE"
    while loop
    do
        case "$STATE" in
            slave-passive)
                fetch_gateways && sync_gateways || {
                    say "master unreachable"
                    sleep 1
                    continue
                }
            ;;
            slave)
                fetch_gateways && sync_gateways || {
                    say "master unreachable"
                    set_state "slave-single"
                    false
                }
            ;;
            slave-single)
                fetch_gateways || {
                    say "master unreachable"
                    false
                } && {
                    puts
                    say "master reachable"
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
        say "next check cycle in: '$HUMAN_INTERVAL'"
        sleep "$CHECK_INTERVAL"
    done
}

run_cluster_mode ()
{
    GATEWAY_SERVER_PID=""
    while loop
    do
        if is_vrrp_master
        then
            is_equal "$STATE" "$ROLE-master" || {
                puts
                say "virtual IP detected on this host: '$VIP'"
                set_state "$ROLE-master"
            }
            check_gateways || {
                reconcile_gateways
                save_gateways_state
            } && serve_gateways || stop_serve_gateways
            say_gateways_state
        else
            case "$STATE" in
                cluster-slave | cluster-master | init)
                    is_equal "$STATE" cluster-slave || {
                        is_diff "$STATE" cluster-master || stop_serve_gateways
                        puts
                        say "virtual IP not found on this host: '$VIP'"
                        set_state cluster-slave
                    }
                    fetch_gateways && sync_gateways || {
                        say "master unreachable"
                        set_state cluster-slave-single
                        false
                    }
                ;;
                cluster-slave-single)
                    fetch_gateways && {
                        puts
                        say "master reachable"
                        set_state cluster-slave
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
}

main ()
{
    is_root_access ||
        die "error: root privileges are required to manage routing tables."

    set_state "init"
    setup_core_env
    setup_defaults

    say "loading configuration..."
    include_config
    verify_config_syntax
    resolve_dependencies &&
    verify_network_state &&
    resolve_transfer_tools || exit
    remove_test_route || exit
    say "initialization complete, system ready"

    trap 'clean_and_exit' 0      # EXIT (0) : Naturally occurring script termination.
    trap 'clean_and_exit 129' 1  # HUP (1)  : Hangup detected on controlling terminal or death of controlling process.
    trap 'clean_and_exit 130' 2  # INT (2)  : Program interrupt (usually Ctrl+C). Exit code 130 (128 + 2).
    trap 'clean_and_exit 143' 15 # TERM (15): Termination signal (default for 'kill' command). Exit code 143 (128 + 15).

    case "$ROLE" in
        single)
            run_single_mode
        ;;
        master | master-advisor)
            run_master_mode
        ;;
        slave | slave-passive)
            run_slave_mode
        ;;
        cluster)
            run_cluster_mode
        ;;
    esac
}

main
