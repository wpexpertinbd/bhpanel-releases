# BHPanel releases

Signed releases of [BHPanel](https://bhpanel.net), the hosting control panel for AlmaLinux.
Servers install them through the panel's own updater (Server → Update); nothing here
needs to be downloaded by hand.

- `v<version>` releases hold the release files.
- `channel-beta` / `channel-stable` hold each channel's `manifest.json`, signed
  (`manifest.json.sig`, ed25519). Every BHPanel server has the public key built in and
  refuses a manifest, or a file, that does not match it.
- A release is signed only after the owner approves it (`publish.yml`, environment `sign`).

`tool/` is the small signing and checking tool; `tools/make-release-key.sh` made the key.

— BiswasHost · <https://www.biswashost.com>
