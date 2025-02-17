#!/bin/sh
# shellcheck disable=SC2039
# shellcheck disable=SC2155
# shellcheck disable=SC2034

mbim() {
  timeout -s KILL "$LTESTAT_TIMEOUT" mbimcli -p -d "/dev/$CDC_DEV" "$@"
}

mbim_get_packet_stats() {
  local STATS="$(mbim --query-packet-statistics)"
  local TXP=$(parse_modem_attr "$STATS" "Packets (out)")
  local TXB=$(parse_modem_attr "$STATS" "Octets (out)")
  local TXD=$(parse_modem_attr "$STATS" "Discards (out)")
  local TXE=$(parse_modem_attr "$STATS" "Errors (out)")
  local RXP=$(parse_modem_attr "$STATS" "Packets (in)")
  local RXB=$(parse_modem_attr "$STATS" "Octets (in)")
  local RXD=$(parse_modem_attr "$STATS" "Discards (in)")
  local RXE=$(parse_modem_attr "$STATS" "Errors (in)")
  json_struct \
    "$(json_attr tx-bytes "${TXB:-0}")" "$(json_attr tx-packets "${TXP:-0}")" "$(json_attr tx-drops "$(( TXD + TXE ))")" \
    "$(json_attr rx-bytes "${RXB:-0}")" "$(json_attr rx-packets "${RXP:-0}")" "$(json_attr rx-drops "$(( RXD + RXE ))")"
}

mbim_get_signal_info() {
  local INFO="$(mbim --query-signal-state)"
  local RSSI=$(parse_modem_attr "$INFO" "RSSI \[0-31,99\]")
  if [ "${RSSI:-99}" -eq 99 ]; then
    RSSI="$UNAVAIL_SIGNAL_METRIC"
  else
    # See table 10-58 (MBIM_SIGNAL_STATE_INFO) in MBIM_v1_0_USBIF_FINAL.pdf
    RSSI="$(( -113 + (2 * RSSI) ))"
  fi
  json_struct \
    "$(json_attr rssi "$RSSI")" \
    "$(json_attr rsrq "$UNAVAIL_SIGNAL_METRIC")" \
    "$(json_attr rsrp "$UNAVAIL_SIGNAL_METRIC")" \
    "$(json_attr snr  "$UNAVAIL_SIGNAL_METRIC")"
}

# mbim_get_op_mode returns one of: "" (aka unspecified), "online", "online-and-connected", "radio-off", "offline", "unrecognized"
mbim_get_op_mode() {
  local RF_STATE="$(mbim --query-radio-state)"
  local HW_RF_STATE="$(parse_modem_attr "$RF_STATE" "Hardware radio state")"
  local SW_RF_STATE="$(parse_modem_attr "$RF_STATE" "Software radio state")"
  if [ "$HW_RF_STATE" = "off" ] || [ "$SW_RF_STATE" = "off" ]; then
    echo "radio-off"
    return
  fi
  if mbim --query-packet-service-state | grep -q "Packet service state:\s*'attached'"; then
    echo "online-and-connected"
  else
    # FIXME XXX detect offline state
    echo "online"
  fi
}

mbim_get_imei() {
  parse_modem_attr "$(mbim --query-device-caps)" "Device ID"
}

mbim_get_modem_model() {
  parse_modem_attr "$(mbim --query-device-caps)" "Hardware info"
}

mbim_get_modem_revision() {
  parse_modem_attr "$(mbim --query-device-caps)" "Firmware info"
}

mbim_get_providers() {
  local PROVIDERS
  if ! PROVIDERS="$(mbim --query-visible-providers)"; then
    echo "[]"
    return 1
  fi
  echo "$PROVIDERS" | awk '
    BEGIN{RS="Provider [[0-9]+]:"; FS="\n"; print "["}
    $0 ~ /Provider ID: / {
      print sep_outer "{"
      sep_inner=""
      for(i=1; i<=NF; i++) {
        kv=""
        if ($i~/Provider ID:/) {
          # Put dash between MCC and MNC.
          # Note: \x27 is a single apostrophe
          kv = gensub(/.*: \x27([0-9]{3})([0-9]{2,3})\x27/, "\"plmn\": \"\\1-\\2\"", 1, $i)
        }
        if ($i~/Provider name:/) {
          kv = gensub(/.*: \x27(.*)\x27/, "\"description\": \"\\1\"", 1, $i)
        }
        if ($i~/State:/) {
          current="false"
          roaming="false"
          if ($i~/registered/) current="true"
          if ($i~/roaming/) roaming="true"
          kv="\"current-serving\":" current ",\"roaming\":" roaming
        }
        if (kv) {
          print sep_inner kv
          sep_inner=","
        }
      }
      print "}"
      sep_outer=","
    }
    END{print "]"}' | jq -c "unique"
}

mbim_get_sim_cards() {
  # FIXME XXX Limited to a single SIM card
  local SUBSCRIBER
  if ! SUBSCRIBER="$(mbim --query-subscriber-ready-status)"; then
    echo "[]"
    return 1
  fi
  local ICCID=$(parse_modem_attr "$SUBSCRIBER" "SIM ICCID")
  # Remove trailing Fs that modem may add as a padding.
  ICCID="$(echo "$ICCID" | tr -d "F")"
  local IMSI=$(parse_modem_attr "$SUBSCRIBER" "Subscriber ID")
  SIM="$(json_struct "$(json_str_attr "iccid" "$ICCID")" "$(json_str_attr "imsi" "$IMSI")")\n"
  printf "%b" "$SIM" | json_array
}

mbim_get_ip_settings() {
  if ! SETTINGS="$(mbim --query-ip-configuration)"; then
    return 1
  fi
  IP="$(echo "$SETTINGS" | jq -r .ipv4.ip)"
  SUBNET="$(echo "$SETTINGS" | jq -r .ipv4.subnet)"
  GW="$(echo "$SETTINGS" | jq -r .ipv4.gateway)"
  DNS1="$(echo "$SETTINGS" | jq -r .ipv4.dns0)"
  DNS2="$(echo "$SETTINGS" | jq -r .ipv4.dns1)"
  MTU="$(echo "$SETTINGS" | jq -r .mtu)"
}

mbim_start_network() {
  echo "[$CDC_DEV] Starting network for APN ${APN}"
  # NOTE that after --attach-packet-service we may end in a state
  # where packet service is attached but WDS hasn't come up online
  # just yet. We're blocking on WDS in wait_for_wds(). However, it
  # may be useful to check --query-packet-service-state just in case.
  mbim --attach-packet-service
  sleep 10
  mbim --connect="apn='${APN}'"
}

mbim_wait_for_sim() {
  echo "[$CDC_DEV] Waiting for SIM card to initialize"
  local CMD="mbim --query-subscriber-ready-status | grep -q 'Ready state: .initialized.' && echo initialized"

  if ! wait_for initialized "$CMD"; then
    echo "Timeout waiting for SIM initialization" >&2
    return 1
  fi
}

mbim_wait_for_wds() {
  echo "[$CDC_DEV] Waiting for DATA services to connect"
  # FIXME XXX there seems to be cases where this looks like connected
  local CMD="mbim --query-connection-state | grep -q 'Activation state: .activated.' && echo connected"

  if ! wait_for connected "$CMD"; then
    echo "Timeout waiting for DATA services to connect" >&2
    return 1
  fi
}

mbim_wait_for_register() {
  # Make sure we are registering with the right APN.
  # Some LTE networks require explicit (and correct) APN for the registration/attach
  # procedure (for the initial EPS bearer activation).
  # Note that qmicli is able to apply this change even in the mbim mode.
  # On the other hand, mbimcli does not yet provide command to manipulate with profiles.
  local PROFILE="$(qmi --wds-get-default-profile-num=3gpp)"
  local PROFILE_NUM="$(parse_modem_attr "$PROFILE" "Default profile number")"
  qmi --wds-modify-profile="3gpp,${PROFILE_NUM},apn=${APN}"

  echo "[$CDC_DEV] Waiting for the device to register on the network"
  local CMD="mbim --query-registration-state | grep -qE 'Register state:.*(home|roaming|partner)' && echo registered"

  if ! wait_for registered "$CMD"; then
    echo "Timeout waiting for the device to register on the network" >&2
    return 1
  fi
}

mbim_get_ip_address() {
  mbim --query-ip-configuration | jq -r .ipv4.ip
}

mbim_wait_for_settings() {
  echo "[$CDC_DEV] Waiting for IP configuration for the $IFACE interface"
  local CMD="mbim_get_ip_address | grep -q \"$IPV4_REGEXP\" && echo connected"

  if ! wait_for connected "$CMD"; then
    echo "Timeout waiting for IP configuration for the $IFACE interface" >&2
    return 1
  fi
}

mbim_stop_network() {
  mbim --disconnect || true
  mbim --detach-packet-service || true
}

mbim_toggle_rf() {
  if [ "$1" = "off" ]; then
    echo "[$CDC_DEV] Disabling RF"
    mbim --set-radio-state "off"
  else
    echo "[$CDC_DEV] Enabling RF"
    mbim --set-radio-state "on"
  fi
}
