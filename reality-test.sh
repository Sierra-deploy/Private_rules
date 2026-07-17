#!/usr/bin/env bash

domains=(
  www.yahoo.com
  www.microsoft.com
  www.adobe.com
  www.nvidia.com
  www.cisco.com
  www.intel.com
  www.amazon.com
  www.ibm.com
  www.oracle.com
  www.dell.com
  www.cloudflare.com
  www.fastly.com
  www.akamai.com
  www.salesforce.com
  www.cloudflarestatus.com
  www.digitalocean.com
  www.linode.com
  www.vultr.com
  www.dropbox.com
  www.paypal.com
  www.ebay.com
  www.netflix.com
  www.spotify.com
  www.reddit.com
  www.twitch.tv
)

TIMEOUT=10
results=$(mktemp)
output=$(mktemp)

trap 'rm -f "$results" "$output"' EXIT

echo "正在从当前服务器测试 Reality 候选域名……"
echo

for domain in "${domains[@]}"; do
  ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 {print $1}')

  if [[ -z "$ip" ]]; then
    printf "1\t999999\t%s\tDNS失败\t-\n" "$domain" >>"$results"
    continue
  fi

  start=$(date +%s%3N)

  timeout "$TIMEOUT" openssl s_client \
    -connect "${domain}:443" \
    -servername "$domain" \
    -tls1_3 \
    -verify_hostname "$domain" \
    -verify_return_error \
    </dev/null >"$output" 2>&1

  code=$?
  end=$(date +%s%3N)
  cost=$((end - start))

  if [[ $code -eq 0 ]] && grep -q "Verify return code: 0 (ok)" "$output"; then
    printf "0\t%d\t%s\t通过\t%s\n" "$cost" "$domain" "$ip" >>"$results"
  else
    reason=$(grep -m1 -E "Verify return code|handshake failure|alert|error|unable|getaddrinfo" "$output" | sed 's/^[[:space:]]*//')
    [[ -z "$reason" ]] && reason="TLS失败"
    printf "1\t%d\t%s\t失败\t%s\n" "$cost" "$domain" "$reason" >>"$results"
  fi
done

passed=$(awk -F'\t' '$1 == 0 {print}' "$results" | sort -n -k2)

if [[ -z "$passed" ]]; then
  echo "没有检测到合格域名，请检查 DNS、网络或 OpenSSL 版本。"
  exit 1
fi

echo "结果 域名                       解析IP/原因          握手耗时"
echo "---- -------------------------- ------------------- --------"

echo "$passed" | awk -F'\t' '{
  printf "%-4s %-26s %-19s %sms\n", $4, $3, $5, $2
}'

best=$(echo "$passed" | head -n1)
best_domain=$(echo "$best" | awk -F'\t' '{print $3}')

echo
echo "推荐先测试："
echo "Handshake：${best_domain}:443"
echo "Server Name：${best_domain}"
