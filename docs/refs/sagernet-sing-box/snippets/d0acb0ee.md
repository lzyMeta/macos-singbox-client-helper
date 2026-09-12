---
id: d0acb0ee
lib: /sagernet/sing-box
kind: info
title: ip_version and query_type behavior changes in DNS rules
language: https://github.com/sagernet/sing-box/blob/testing/docs/migration.md
symbols: []
source_url: 102
fetched_at: 2026-09-12
---

Second, setting ip_version or query_type in a DNS rule, or referencing a rule-set containing query_type, is no longer compatible in the same DNS configuration with Legacy Address Filter Fields in DNS rules, the Legacy strategy DNS rule action option, or the Legacy rule_set_ip_cidr_accept_empty DNS rule item. Such a configuration will be rejected at startup. To combine these fields with address-based filtering, migrate to response matching via the evaluate action and match_response, see Migrate address filter fields to response matching.
