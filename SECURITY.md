# Security

Please report a vulnerability privately, not in a public issue: use **Report a vulnerability** in this repository's
[Security tab](https://github.com/leopierini/pomelo/security/advisories/new). Include the steps to reproduce it and
the version of Pomelo and macOS.

You'll get an answer as soon as possible, and a fix will be released before the details are made public.

Areas where a report matters most: anything that could make Pomelo modify, overwrite or delete a file it shouldn't,
the engine installer (downloads are pinned to a SHA-256 fingerprint), and the plugin manifests Pomelo loads from
`~/Library/Application Support/Pomelo/Plugins`.
