---
id: bb589bcf
lib: /sagernet/sing-box
version: 1.14.0
kind: code
title: Remote rule-set structure
language: json
symbols: []
source_url: https://github.com/sagernet/sing-box/blob/testing/docs/configuration/rule-set/index.md
fetched_at: 2026-10-16
---

Defines a remote rule-set that downloads from a URL. Remote rule-sets are cached if experimental.cache_file.enabled. Includes deprecated download_detour field.

```json
{
  "type": "remote",
  "tag": "", // or []
  "format": "source", // or binary
  "url": "",
  "initial_path": "",
  "http_client": "", // or {}
  "update_interval": "",

  // Deprecated

  "download_detour": ""
}
```
