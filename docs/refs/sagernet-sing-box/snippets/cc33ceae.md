---
id: cc33ceae
lib: /sagernet/sing-box
kind: code
title: New DNS rule configuration with match_response
language: json
symbols: []
source_url: https://github.com/sagernet/sing-box/blob/testing/docs/migration.md
fetched_at: 2026-09-12
---

Updated DNS rules using the evaluate action and explicit match_response.

```json
{
  "dns": {
    "rules": [
      {
        "action": "evaluate",
        "server": "remote"
      },
      {
        "match_response": true,
        "rule_set": "geoip-cn",
        "action": "route",
        "server": "local"
      },
      {
        "action": "route",
        "server": "remote"
      }
    ]
  }
}
```
