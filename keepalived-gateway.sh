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

if is_not_empty "${KSH_VERSION:-}"
then
    PUTS_TYPE="print" CAN_ESC_OCTAL="yes"
    puts ()
    {
        is_empty "${USE_ESC:-}" && print ${CONTINUE:+"$CONTINUE"} -r -- "$*" ||
                                   print ${CONTINUE:+"$CONTINUE"}    -- "$*"
    }
else
    if type printf >/dev/null 2>&1
    then
        printf '%b' '\033[0m' >/dev/null 2>&1 && CAN_ESC_OCTAL="yes" ||
                                                 CAN_ESC_OCTAL=""
        PUTS_TYPE="printf"
        puts ()
        {
            is_empty "${USE_ESC:-}"  && FORMAT="%s" ||
                                        FORMAT="${CAN_ESC_OCTAL:+%b}"
            is_empty "${CONTINUE:-}" && printf "${FORMAT:-%s}\n" "$*" ||
                                        printf "${FORMAT:-%s}"   "$*"
        }
    elif type echo >/dev/null 2>&1
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
    fi
fi

say ()
{
    EXIT_CODE=$?
    CONTINUE=""
    NO_PREFIX=""
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
                EXIT_CODE=$1
            ;;
        esac
        shift
    done
    is_empty "$*" || {
        case "${NO_PREFIX:-}" in
            "")
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

eval 'ERROR=${ERROR#*:}' 2>/dev/null ||
    die "error: POSIX parameter expansion \${VAR#*}, \${VAR%*}, ... is not supported by this shell."

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

set_state ()
{
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
}

include_config ()
{
    CONFIG_FILE="/etc/keepalived-gateway.conf"
    if is_file "$CONFIG_FILE"
    then
        ERROR="$(. "$CONFIG_FILE" 2>&1)" && . "$CONFIG_FILE" || {
            EXIT_CODE=$?
            say "${ERROR#*:}"
        }
    else
        EXIT_CODE=$?
        say "error: no such config file: '$CONFIG_FILE'"
    fi
    return $EXIT_CODE
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

    METRIC="${1#"${1%%[!0]*}"}"

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
            GATEWAY="$1"
            METRIC="${2:-}"
        ;;
        *)
            INTERFACE="${1:-}"
            GATEWAY="${2:-}"
            METRIC="${3:-}"
        ;;
    esac

    case "$GATEWAY" in
        "")
            say 2 "error: variable 'GATEWAYS': gateway [$NUM]: gateway is empty"
        ;;
        *.*)
            is_ipv4 "$GATEWAY" && FAMILY="inet" ||
                say 2 "error: variable 'GATEWAYS': gateway [$NUM]: $ERROR"
        ;;
        *)
            GATEWAY="${GATEWAY#[}"
            GATEWAY="${GATEWAY%]}"
            is_ipv6 "$GATEWAY" && FAMILY="inet6" ||
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
    GATEWAYS_IPV4="${GATEWAYS_IPV4:+$GATEWAYS_IPV4$LF}$INTERFACE=$GATEWAY${METRIC:+=$METRIC}"
}

collect_gateway_ipv6 ()
{
    GATEWAYS_IPV6="${GATEWAYS_IPV6:+$GATEWAYS_IPV6$LF}$INTERFACE=$GATEWAY${METRIC:+=$METRIC}"
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
            inet)
                collect_gateway_ipv4
                collect_metrics_ipv4
            ;;
            inet6)
                collect_gateway_ipv6
                collect_metrics_ipv6
            ;;
        esac
        is_empty "${INTERFACE:-}" || collect_interface
    done

    TOTAL_METRICS_IPV4="$(count_metrics "${METRICS_IPV4:-}")"
    TOTAL_METRICS_IPV6="$(count_metrics "${METRICS_IPV6:-}")"
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

deprecated_parse_gateway ()
{
    case "$FAMILY" in
        inet)
            PROTO="IPv4"
            is_not_empty "${PING4:-}" && {

                is_empty "${PING_HOST:-}" || is_not_empty "${PING_IPV4:-}" || {
                    say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY': failed to resolve '$PING_HOST' ($PROTO)"
                    say "WARNING: gateway '$GATEWAY': skipping internet check (direct IP check only)"
                }

                is_equal "$SPEEDTEST" "no" || is_not_empty "${SPEEDTEST_IPV4:-}" || {
                    say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY': failed to resolve '$SPEEDTEST_HOST' ($PROTO)"
                    say "WARNING: gateway '$GATEWAY': skipping speedtest check for this gateway"
                }
            }
        ;;
        inet6)
            PROTO="IPv6"
            is_not_empty "${PING6:-}" && {

                is_empty "${PING_HOST:-}" || is_not_empty "${PING_IPV6:-}" || {
                    say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY': failed to resolve '$PING_HOST' ($PROTO)"
                    say "WARNING: gateway '$GATEWAY': skipping internet check (direct IP check only)"
                }

                is_equal "$SPEEDTEST" "no" || is_not_empty "${SPEEDTEST_IPV6:-}" || {
                    say "WARNING: variable 'GATEWAYS': gateway '$GATEWAY': failed to resolve '$SPEEDTEST_HOST' ($PROTO)"
                    say "WARNING: gateway '$GATEWAY': skipping speedtest check for this gateway"
                }
            }
        ;;
    esac || {
        say "error: variable 'GATEWAYS': gateway '$GATEWAY' requires '$PROTO', but your system ping does not support: '$PROTO'"
        RETURN=2
        continue
    }
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
            HOST="${HOST#"${HOST%%[!/]*}"}"
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
            is_not_empty "${SCHEME:-"${WWW:-}"}" ||
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
                    FAMILY="inet"
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
            FAMILY="inet6"
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

set_variables ()
{
    case "${ROLE:=single}" in
        cluster | master | master-advisor | single)
            DO_PING="yes"
            DO_SPEEDTEST="yes"
        ;;
        slave)
            DO_PING="no"
            DO_SPEEDTEST="no"
        ;;
        *)
            ROLE="unknown"
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
        is_equal "$ROLE" "slave" || is_equal "$ROLE" "unknown" ||
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

    parse_interval CHECK_INTERVAL "${CHECK_INTERVAL:=30}" && {
        CHECK_INTERVAL="$INTERVAL"
        HUMAN_INTERVAL="$(format_duration "$CHECK_INTERVAL")"
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
            DO_SPEEDTEST="yes"
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
            SPEEDTEST_FQDN="${FQDN:-}"
            SPEEDTEST_IPV4="${IPV4:-}"
            SPEEDTEST_IPV6="${IPV6:-}"
            RESOURCE="${RESOURCE:+"/$RESOURCE"}${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
            SPEEDTEST_SCHEME="${SCHEME:-http}"
            SPEEDTEST_URL_PREFIX="$SPEEDTEST_SCHEME://${USER_INFO:+$USER_INFO@}"
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

        is_not_empty "${IPV4:-"${IPV6:-}"}" ||
            say 2 "error: variable 'VIRTUAL_IPADDRESS': invalid virtual IP address"

        VIRTUAL_IPADDRESS_FAMILY="${FAMILY:-}"
        VIRTUAL_IPADDRESS="${IPV4:-${IPV6:-}}"
    }

    is_empty "${VIRTUAL_PORT:-}" && {
        is_equal "$ROLE" "single" || is_equal "$ROLE" "unknown" ||
            say 2 "error: variable 'VIRTUAL_PORT': is empty: required for roles 'cluster, master, master-advisor, slave'"
    } || is_port "$VIRTUAL_PORT" || {
        VIRTUAL_PORT=""
        say 2 "error: variable 'VIRTUAL_PORT': $ERROR"
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
    AWK_NATURAL_SORT='
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
        END {
            if (count == 0) exit 0
            for (i = 1; i <= count; i++) keys[i] = get_nat_key(list[i])
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
            for (i = 1; i <= count; i++) print list[i]
        }
    '
    AWK_ADDRESS_PARSER='
        /inet6?/ {
            if ($0 ~ /addr:/) {
                split($0, line, "addr:")
                split(line[2], ip_mask_zone, " ")
                address = ip_mask_zone[1]
            } else {
                address = $2
            }
            if (address) {
                split(address, ip, "[/%]")
                value = ip[1]
                '"$AWK_UNIQUE_COLLECT"'
            }
        }
        '"$AWK_NATURAL_SORT"'
    '

    if type ip >/dev/null 2>&1
    then
        NET_TOOL="ip"
        show_addresses ()
        {
            ip address show 2>/dev/null | awk "$AWK_ADDRESS_PARSER"
        }

        show_interfaces ()
        {
            ip link show 2>/dev/null | awk '
                /^[0-9]+:/ {
                    value = $2
                    sub(/:$/, "", value)
                    sub(/@.*/, "", value)
                    '"$AWK_UNIQUE_COLLECT"'
                }
                '"$AWK_NATURAL_SORT"'
            '
        }

        show_routes ()
        {
            ip route show
        }

        control_route ()
        {
            ip route "$1" $2
        }

    elif type ifconfig >/dev/null 2>&1
    then
        NET_TOOL="ifconfig"
        show_addresses ()
        {
            ifconfig -a 2>/dev/null | awk "$AWK_ADDRESS_PARSER"
        }

        show_interfaces ()
        {
            ifconfig -a 2>/dev/null | awk '
                /^[a-zA-Z0-9]/ {
                    value = $1
                    sub(/:$/, "", value)
                    '"$AWK_UNIQUE_COLLECT"'
                }
                '"$AWK_NATURAL_SORT"'
            '
        }
    else
        say 127 "error: environment: network check is impossible: 'ip' or 'ifconfig' not found"
    fi

    show_ports ()
    {
        netstat -an 2>/dev/null | awk '
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
            '"$AWK_NATURAL_SORT"'
        '
    }

    if is_equal "${NET_TOOL:-}" "ip"
    then
        case "$ROLE" in
            single | slave | unknown)
            ;;
            *)
                false
        esac ||
        if type ss >/dev/null 2>&1
        then
            show_ports ()
            {
                ss -Hnuta 2>/dev/null | awk '
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
                    '"$AWK_NATURAL_SORT"'
                '
            }
        elif type netstat >/dev/null 2>&1
        then
            :
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
                    {
                        value = $1
                        '"$AWK_UNIQUE_COLLECT"'
                    }
                    '"$AWK_NATURAL_SORT"'
                '
            }
        else
            say 127 "error: variable 'VIRTUAL_PORT': port check is impossible: 'ss' or 'netstat' not found"
        fi
    elif is_equal "${NET_TOOL:-}" "ifconfig"
    then
        if type netstat >/dev/null 2>&1
        then
            show_routes ()
            {
                netstat -rn
            }
        else
            say 127 "error: environment: routing table check impossible: 'netstat' not found"
        fi

        if type route >/dev/null 2>&1
        then
            control_route ()
            {
                case "$1" in
                    replace)
                        route del $2 >/dev/null 2>&1
                        route add $2
                    ;;
                    *)
                        route "$1" $2
                    ;;
                esac
            }
        else
            say 127 "error: environment: route management impossible: 'route' not found"
        fi
    fi

    is_equal "$DO_SPEEDTEST" "no" || {
        MISSING_DEPS=""
        for COMMAND in date wc
        do
            type "$COMMAND" >/dev/null 2>&1 ||
                MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        done
        is_empty "${MISSING_DEPS:-}" ||
            say 127 "error: environment: speedtest is impossible: '$MISSING_DEPS' not found"
    }

    type awk >/dev/null 2>&1 ||
        say 127 "error: environment: parsing impossible: 'awk' not found"

    type sleep >/dev/null 2>&1 && SLEEP="sleep" || {
        SLEEP="return"
        SAVED_EXIT_CODE="$EXIT_CODE"
        say "error: environment: continuous monitoring impossible: 'sleep' not found"
        EXIT_CODE="$SAVED_EXIT_CODE"
    }

    type timeout >/dev/null 2>&1 && {
        timeout -t 1 sh -c : >/dev/null 2>&1 &&
            TIMEOUT="timeout -t" ||
            TIMEOUT="timeout"
    } || say 127 "error: environment: process hang protection impossible: 'timeout' not found"

    PING_NEEDED="no"
    is_equal "$ROUTE" "slave" || is_equal "$ROUTE" "unknown" || {
        is_equal "$DO_PING" "no" &&
        is_equal "$DO_SPEEDTEST" "yes" &&
        is_not_empty "${SPEEDTEST_IPV4:-${SPEEDTEST_IPV6:-}}" || {
            PING_NEEDED="yes"
            type ping >/dev/null 2>&1 ||
                say 127 "error: environment: gateway check impossible: 'ping' not found"
        }
    }

    is_equal $EXIT_CODE 0
}

resolve_ping ()
{
    PING4=""
    PING6=""

    if is_equal "$HAS_IPV4_STACK" yes
    then
        ping -4 -c 1 -w 1 127.0.0.1 >/dev/null 2>&1 &&
            PING4="ping -4" ||
            PING4="ping"
    fi

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
        IPV4="$($TIMEOUT 5 $PING4 -c 1 "$1" 2>/dev/null | awk '
            /PING/ {
                gsub(/[][)(:]/, " ", $0)
                for (ip=1; ip<=NF; ip++) {
                    if ($ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                        print $ip
                        exit
                    }
                }
            }
        ')" || :

    is_empty "${PING6:-}" ||
        IPV6="$($TIMEOUT 5 $PING6 -c 1 "$1" 2>/dev/null | awk '
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
        ')" || :

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
    for IP in ${LOCAL_IP:-$(show_addresses)}
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
            GATEWAY="$1"
        ;;
        *)
            GATEWAY="$2"
        ;;
    esac

    if is_local_ip "$GATEWAY"
    then
        ERROR="address is assigned to this host (loopback risk): $GATEWAY"
        return 2
    fi
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

verify_network_state ()
{
    HAS_IPV4_STACK="no"
    HAS_IPV6_STACK="no"
    LOCAL_IP="$(show_addresses)"

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

    is_equal "$PING_NEEDED" "no" || resolve_ping || {
        say "error: environment: 'ping' is unusable: network stack support check failed"
        return $EXIT_CODE
    }

    is_equal "$DO_PING" "no" || is_empty "${PING_FQDN:-}" || {
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

    is_equal "$ROLE" "slave" || {
        is_empty "${GATEWAYS_IPV4:-}" || {
            GATEWAYS_IPV4="$(optimize_gateways "$GATEWAYS_IPV4")"
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
            GATEWAYS_IPV6="$(optimize_gateways "$GATEWAYS_IPV6")"
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
    case "${VIRTUAL_IPADDRESS_FAMILY:-}" in
        inet)
            ERROR="IPv4 stack or 127.0.0.1 not found"
            is_equal "$HAS_IPV4_STACK" "yes"
        ;;
        inet6)
            ERROR="IPv6 stack or ::1 not found"
            is_equal "$HAS_IPV6_STACK" "yes"
        ;;
    esac || say "error: variable 'VIRTUAL_IPADDRESS': $ERROR"

    LOCAL_IP=""
    is_equal $EXIT_CODE 0
}

resolve_server ()
{
    RETURN=0
    ERROR="sync server determination impossible"

    is_equal "$SLEEP" "sleep" || {
        RETURN=1
        say 127 "error: environment: $ERROR: 'sleep' not found"
    }

    is_port_free "$VIRTUAL_PORT" || {
        RETURN=1
        say 1 "error: variable 'VIRTUAL_PORT': $ERROR: port $VIRTUAL_PORT is already in use"
    }

    is_equal "$RETURN" 0 || return 0

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
        if check_daemon nc -l -p $VIRTUAL_PORT $LOCAL_IP
        then
            SERVER="nc -l -p $VIRTUAL_PORT $VIRTUAL_IPADDRESS"
            return 0
        fi

        # Ubuntu
        if check_daemon nc -l -s $LOCAL_IP -p $VIRTUAL_PORT
        then
            SERVER="nc -l -s $VIRTUAL_IPADDRESS -p $VIRTUAL_PORT"
            return 0
        fi

        # FreeBSD
        if check_daemon nc -l $LOCAL_IP $VIRTUAL_PORT
        then
            SERVER="nc -l $VIRTUAL_IPADDRESS $VIRTUAL_PORT"
            return 0
        fi

        return 1
    }

    case "${VIRTUAL_IPADDRESS_FAMILY:-}" in
        inet)
            LOCAL_IP="127.0.0.1"
            BIND_IP="$LOCAL_IP"
        ;;
        inet6)
            LOCAL_IP="127.0.0.1"
            BIND_IP="$LOCAL_IP"
        ;;
    esac

    SERVE_GATEWAYS=""
    MISSING_DEPS=""
    SYNC_SERVER_LIST="nc uhttpd httpd telnetd"
    for COMMAND in $SYNC_SERVER_LIST
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            say -n "environment: role '$ROLE': found '$COMMAND': probing server capability..."
            case "$COMMAND" in
                nc)
                    detect_netcat_server &&
                        SERVE_GATEWAYS="serve_gateways_netcat"
                ;;
                uhttpd | httpd)
                    check_daemon $COMMAND -f -p $BIND_IP:$VIRTUAL_PORT && {
                        SERVE_GATEWAYS="serve_gateways_httpd"
                        is_equal "$VIRTUAL_IPADDRESS_FAMILY" inet &&
                            SERVER="$COMMAND -f -p $VIRTUAL_IPADDRESS:$VIRTUAL_PORT" ||
                            SERVER="$COMMAND -f -p [$VIRTUAL_IPADDRESS]:$VIRTUAL_PORT"
                    }
                ;;
                telnetd)
                    check_daemon $COMMAND -F -p $VIRTUAL_PORT -b $LOCAL_IP && {
                        SERVE_GATEWAYS="serve_gateways_telnetd"
                        SERVER="$COMMAND -F -p $VIRTUAL_PORT -b $VIRTUAL_IPADDRESS -l : -K"
                    }
                ;;
            esac >/dev/null 2>&1 && {
                say -p " [ OK ]"
                break
            }
        else
            MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        fi || say 0 -p " [ FAILED ]"
    done
    is_not_empty "${SERVE_GATEWAYS:-}" ||
        say 127 "error: environment: $ERROR: '$MISSING_DEPS' not found"
}

detect_curl_client ()
{
    STATE="$(2>&1 curl $1://$2:1 || :)"
    case "${STATE:-}" in
        *connect*)
            return 0
        ;;
        *Protocol*)
            say -p " [unsupported scheme ‘$1’]"
            return 1
        ;;
        *URL* | *resolve*)
            say -p " [$3 unsupported]"
            return 2
        ;;
        *)
            say -p " [undefined error]"
            return 3
    esac
}

detect_wget_client ()
{
    STATE="$(2>&1 wget $1://$2:1 || :)"
    case "${STATE:-}" in
        *Connection*)
            return 0
        ;;
        *family* | *socket*)
            say -p " [$3 unsupported]"
            return 1
        ;;
        *support* | *http* | *ftp*)
            say -p " [unsupported scheme ‘$1’]"
            return 2
        ;;
        *)
            say -p " [undefined error]"
            return 3
    esac
}

detect_netcat_client ()
{
    STATE="$(2>&1 nc $2 1 || :)"
    case "${STATE:-}" in
        "" | *Connection*)
            return 0
        ;;
        *family* | *resolve*)
            say -p " [$3 unsupported]"
            return 1
        ;;
        *)
            say -p " [undefined error]"
            return 3
    esac
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

probe_speedtest_fetcher ()
{
    is_not_empty "${FETCH_SPEEDTEST_IPV4:-}" || {
        is_empty "${SPEEDTEST_IPV4:-}" || {
            say -n "$PREFIX: probing IPv4 speedtest client capability..."
            $1 "$SPEEDTEST_SCHEME" 127.0.0.1 IPv4 && {
                FETCH_SPEEDTEST_IPV4="$2"
                say -p " [ OK ]"
            } || RETURN=1
        }
    }
    is_not_empty "${FETCH_SPEEDTEST_IPV6:-}" || {
        is_empty "${SPEEDTEST_IPV6:-}" || {
            say -n "$PREFIX: probing IPv6 speedtest client capability..."
            $1 "$SPEEDTEST_SCHEME" [::1] IPv6 && {
                FETCH_SPEEDTEST_IPV6="$2"
                say -p " [ OK ]"
            } || RETURN=1
        }
    }
}

probe_gateway_fetcher ()
{
    case "$ROLE" in
        cluster | slave)
            is_not_empty "${FETCH_GATEWAYS:-}" || {
                if is_equal "$VIRTUAL_IPADDRESS_FAMILY" "inet"
                then
                    say -n "$PREFIX: probing IPv4 gateway client capability..."
                    is_equal "${SPEEDTEST_SCHEME:-}" http &&
                    is_not_empty "${FETCH_SPEEDTEST_IPV4:-}" ||
                        $1 http 127.0.0.1 IPV4
                else
                    say -n "$PREFIX: probing IPv6 gateway client capability..."
                    is_equal "${SPEEDTEST_SCHEME:-}" http &&
                    is_not_empty "${FETCH_SPEEDTEST_IPV6:-}" ||
                        $1 http [::1] IPV6
                fi && {
                    FETCH_GATEWAYS="$2"
                    say -p " [ OK ]"
                } || RETURN=1
            }
        ;;
    esac
}

probe_client_capabilities ()
{
    RETURN=0
    PREFIX="environment: role '$ROLE': found '$COMMAND'"
    is_equal "$DO_SPEEDTEST" "no" ||
    is_not_empty "${FETCH_SPEEDTEST_IPV4:+${FETCH_SPEEDTEST_IPV4:-}}" ||
        if is_supported_scheme "$3"
        then
            probe_speedtest_fetcher $1 $2
        else
            say "$PREFIX: probing speedtest client capability... [unsupported scheme ‘$SPEEDTEST_SCHEME’]"
        fi

    probe_gateway_fetcher $1 $2
    return $RETURN
}

resolve_client ()
{
    MISSING_DEPS=""
    FETCH_GATEWAYS=""
    FETCH_SPEEDTEST_IPV4=""
    FETCH_SPEEDTEST_IPV6=""
    CLIENT_LIST="curl wget nc"
    for COMMAND in $CLIENT_LIST
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            case "$COMMAND" in
                curl)
                    probe_client_capabilities detect_curl_client fetch_curl "http https ftp sftp ftps tftp file scp"
                ;;
                wget)
                    probe_client_capabilities detect_wget_client fetch_wget "http https ftp ftps"
                ;;
                nc)
                    probe_client_capabilities detect_netcat_client fetch_netcat http
                ;;
            esac && break || continue
        else
            MISSING_DEPS="${MISSING_DEPS:+$MISSING_DEPS, }$COMMAND"
        fi
    done
    is_equal $RETURN 0
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
        slave)
            resolve_client
        ;;
    esac
}

echo_conf_vars ()
{
    echo "Function [${1:-}]"
    echo " =========== Config
               INTERFACE [$INTERFACE]
       DEFAULT_INTERFACE [$DEFAULT_INTERFACE]
                  METRIC [$METRIC]
          DEFAULT_METRIC [$DEFAULT_METRIC]
                GATEWAYS [$GATEWAYS]
          CHECK_INTERVAL [$CHECK_INTERVAL]
               PING_HOST [$PING_HOST]
               SPEEDTEST [$SPEEDTEST]
          SPEEDTEST_HOST [$SPEEDTEST_HOST]
         SPEEDTEST_SCOPE [$SPEEDTEST_SCOPE]
                    ROLE [$ROLE]
       VIRTUAL_IPADDRESS [$VIRTUAL_IPADDRESS]
            VIRTUAL_PORT [$VIRTUAL_PORT]
 =========== VARS
                NET_TOOL [$NET_TOOL]
          HAS_IPV4_STACK [$HAS_IPV4_STACK]
          HAS_IPV6_STACK [$HAS_IPV6_STACK]
                   SLEEP [$SLEEP]
                 TIMEOUT [$TIMEOUT]
            PROC_NET_TCP [$PROC_NET_TCP]
                LOCAL_IP [$LOCAL_IP]

            DO_SPEEDTEST [$DO_SPEEDTEST]
        SPEEDTEST_SCHEME [$SPEEDTEST_SCHEME]
          SPEEDTEST_FQDN [$SPEEDTEST_FQDN]
          SPEEDTEST_IPV4 [$SPEEDTEST_IPV4]
          SPEEDTEST_IPV6 [$SPEEDTEST_IPV6]
                RESOURCE [$RESOURCE]
    SPEEDTEST_URL_PREFIX [$SPEEDTEST_URL_PREFIX]
          SPEEDTEST_FQDN [$SPEEDTEST_FQDN]

                 DO_PING [$DO_PING]
               PING_FQDN [$PING_FQDN]
               PING_IPV4 [$PING_IPV4]
               PING_IPV6 [$PING_IPV6]
             PING_NEEDED [$PING_NEEDED]
                   PING4 [$PING4]
                   PING6 [$PING6]

VIRTUAL_IPADDRESS_FAMILY [$VIRTUAL_IPADDRESS_FAMILY]
 =========== IP
           GATEWAYS_IPV4 [$GATEWAYS_IPV4]
           GATEWAYS_IPV6 [$GATEWAYS_IPV6]
            METRICS_IPV4 [$METRICS_IPV4]
            METRICS_IPV6 [$METRICS_IPV6]
                  IFACES [$IFACES]

 =========== Server
          SERVE_GATEWAYS [$SERVE_GATEWAYS]
                  SERVER [$SERVER]
 =========== Client
          FETCH_GATEWAYS [$FETCH_GATEWAYS]
    FETCH_SPEEDTEST_IPV4 [$FETCH_SPEEDTEST_IPV4]
    FETCH_SPEEDTEST_IPV6 [$FETCH_SPEEDTEST_IPV6]
 ---------------------------------------------------"
}

deprecated_check_base_dependencies ()
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
        say "error: must be run as root to manage routes and interfaces."
}

deprecated_set_variables ()
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
            die 2 "error: failed to resolve 'PING_HOST' IP: '$PING_HOST'"

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

    is_equal "$SPEEDTEST" "no" || {

        is_not_empty "${SPEEDTEST_HOST:-}" ||
            die 2 "error: variable 'SPEEDTEST_HOST': is required when 'SPEEDTEST' is enabled"

        parse_resource "$SPEEDTEST_HOST" ||
            die "error: failed to resolve 'SPEEDTEST_HOST' IP: '$SPEEDTEST_HOST'"

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

        RESOURCE="${RESOURCE:+"/$RESOURCE"}${SPEEDTEST_SCOPE:+"/$SPEEDTEST_SCOPE"}"
        SPEEDTEST_URL="${SCHEME:-http}://${USER_INFO:+$USER_INFO@}$HOST${RESOURCE:-}"
        SPEEDTEST_IPV4="${IPV4:-}"
        SPEEDTEST_IPV6="${IPV6:-}"
    }

    case "${ROLE:=single}" in
        cluster | master | master-advisor | single | slave)
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
            die 2 "error: variable 'VIRTUAL_IPADDRESS' is empty: required for roles 'cluster|master|master-advisor|slave'"
    else
        parse_resource "$VIRTUAL_IPADDRESS" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': invalid virtual IP address: '$VIRTUAL_IPADDRESS'"

        is_equal "$HOST" "${IPV4:-}" || is_equal "$HOST" "${IPV6:-}" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': must be an IP address, but got: '$HOST'"

        is_valid_ip "${IPV4:-"$IPV6"}" ||
            die 2 "error: variable 'VIRTUAL_IPADDRESS': resolved to invalid IP address: '${IPV4:-"$IPV6"}'"

        is_not_empty "${VIRTUAL_PORT:-}" ||
            die 2 "error: variable 'VIRTUAL_PORT': is required when 'VIRTUAL_IPADDRESS' is defined"

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

is_local_interface ()
{
    ip link show ${1:-} >/dev/null 2>&1
}

detect_sync_transport ()
{
    RETURN=0

    SERVE_GATEWAYS=""
    FETCH_GATEWAYS=""

    for COMMAND in uhttpd telnetd nc
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            is_diff "$COMMAND" "nc" || detect_netcat_server || break
            SERVE_GATEWAYS="serve_gateways_$COMMAND"
            break
        fi
    done

    is_not_empty "${SERVE_GATEWAYS:-}" ||
        die "error: no supported sync server found (uhttpd/telnetd/nc required)"

    for COMMAND in wget curl nc
    do
        if type "$COMMAND" >/dev/null 2>&1
        then
            FETCH_GATEWAYS="fetch_gateways_$COMMAND"
            break
        fi
    done

    is_not_empty "${FETCH_GATEWAYS:-}" ||
        die "error: no supported sync client found (wget/curl/nc required)"
}

deprecated_set_variables ()
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

serve_gateways_netcat ()
{
    trap '
        trap - 0
        kill $NETCAT_PID 2>/dev/null
        exit
    ' 0 1 2 15

    while :
    do
        $SERVER <<EOF >/dev/null 2>&1 &
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

serve_gateways_httpd ()
{
    $SERVER -h "${GATEWAYS_STATE_FILE%/*}"
}

serve_gateways_telnetd ()
{
    $SERVER -f "$GATEWAYS_STATE_FILE"
}

serve_gateways ()
{
    is_process_alive "${GATEWAY_SERVER_PID:-}" || {
        is_port_free "$VIRTUAL_PORT" || {
            say "error: cannot start sync server, port $VIRTUAL_PORT is busy"
            return
        } >&2

        $SERVE_GATEWAYS 2>&1 &
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

stop_serve_gateways ()
{
    if is_process_alive "${GATEWAY_SERVER_PID:-}"
    then
        kill "$GATEWAY_SERVER_PID" 2>/dev/null || :
        GATEWAY_SERVER_PID=""
        say "gateway server stopped"
    fi
}

fetch_wget ()
{
    FETCHED_GATEWAYS="$(
        2>&1 wget -O - "http://${VIRTUAL_IPADDRESS%/*}:$VIRTUAL_PORT/${GATEWAYS_STATE_FILE##*/}"
    )"
}

fetch_curl ()
{
    FETCHED_GATEWAYS="$(
        2>&1 curl -o - "http://${VIRTUAL_IPADDRESS%/*}:$VIRTUAL_PORT/${GATEWAYS_STATE_FILE##*/}"
    )"
}

fetch_nc ()
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
        "$FETCH_GATEWAYS" && {
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
        {
            gsub(/\r/, "")
            if ($0 ~ /^\377/) next
            if ($0 ~ /^(GET|Host|User-Agent|Accept|Connection|HTTP\/)/) next
            if ($0 ~ /^[[:space:]]*$/) next
            print $0
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
    EXIT_CODE=0
    say "switching to init mode"
    set_state "init"
    setup_core_env
    say "loading configuration..."
    include_config && set_variables
    echo_conf_vars set_variables
    resolve_dependencies || {
        echo_conf_vars resolve_dependencies
        die
    }
    verify_network_state || {
        echo_conf_vars verify_network_state
        die
    }
    resolve_transfer_tools
    echo_conf_vars resolve_transfer_tools
    exit
    check_permissions
    is_equal $EXIT_CODE 0 || die

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
                } && serve_gateways || stop_serve_gateways
            else
                case "$STATE" in
                    "slave" | "master" | "master-advisor" | "init")
                        case "$STATE" in
                            "master" | "master-advisor")
                                stop_serve_gateways
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
