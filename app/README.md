# DeviceBridge interface

Flutter Android/Linux presentation with Kotlin Android integrations. The shared Go core implements identity, policy, discovery and transfers. Read the repository [README](../README.md), [implementation status](../docs/IMPLEMENTATION_STATUS.md) and [architecture](../docs/ARCHITECTURE.md).

Build the Go core before either Flutter target: `bash scripts/build_apps.sh` from the repository root. Development APKs use the development signing key. Android bundles its own NDK-built Go executable; Termux/root are not app runtime dependencies.

Home / Devices / Share / Sync are the only primary destinations. Browse is inside a device detail. Share/Sync remain disabled until their real implementations and policy tests are complete.
