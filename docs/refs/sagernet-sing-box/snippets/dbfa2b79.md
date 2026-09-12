---
id: dbfa2b79
lib: /sagernet/sing-box
kind: info
title: ip_version and query_type behavior changes in DNS rules
language: https://github.com/sagernet/sing-box/blob/testing/docs/migration.md
symbols: []
source_url: 248
fetched_at: 2026-09-12
---

In sing-box 1.14.0, the behavior of ip_version and query_type in DNS rules, together with query_type in referenced rule-sets, changes in two ways. First, these fields now take effect on every DNS rule evaluation. In earlier versions they were evaluated only for DNS queries received from a client (for example, from a DNS inbound or intercepted by tun), and were silently ignored when a DNS rule was matched from an internal domain resolution that did not target a specific DNS server. Such internal resolutions include:

- The resolve route rule action without a server set.
- ICMP traffic routed to a domain destination through a direct outbound.
- A WireGuard or Tailscale endpoint used as an outbound, when resolving its own destination address.
- A SOCKS4 outbound, which must resolve the destination locally because the protocol has no in-protocol domain support.
- The DERP bootstrap-dns endpoint and the resolved service (when resolving a hostname or an SRV target).

Resolutions that target a specific DNS server — via domain_resolver on a dial field, default_domain_resolver in route options, or an explicit server on a DNS rule action or the resolve route rule action — do not go through DNS rule matching and are unaffected.
