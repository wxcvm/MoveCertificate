# Project scope

This repository maintains the MoveCertificate Android CA module and its WebUI.
GPU drivers and experiments belong to their separate project. Do not add driver
code, binaries, build jobs, diagnostics or packages to this repository.

Preserve user CA inputs and saved per-certificate choices. A successful mount
requires checking certificate contents in init and the zygote namespaces. Keep
the configured mode; never hide a failed check by reporting installation success.
Keep device acceptance separate from fixture tests and hosted build results.

Builds produce only a MoveCertificate module ZIP under dist/. Use explicit
runtime file lists, and never package device logs, private certificates, test
fixtures or local diagnostic files. Do not rewrite published Git history as
part of routine cleanup.
