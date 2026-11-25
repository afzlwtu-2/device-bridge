# Remote actions and guest access

## Agent actions

Open a paired device's Commands area and choose **Agent actions**. A requested diagnostic appears in that peer's **Requests from…** list. The owner can allow one run or decline it. The requester can check approval and retrieve the bounded result. Approval is tied to the requester, action and request ID, with a short expiry. The agent audits each execution and offers agent status, storage space and the requesting peer's recent activity.

The CLI exposes the same workflow through `agent-actions PEER`, `action PEER PRESET [REQUEST_ID]`, `action-inbox PEER_ID`, `action-approve PEER_ID PRESET REQUEST_ID [TTL]` and `action-revoke PEER_ID PRESET REQUEST_ID`. Repeating the same completed request returns its original result. The agent flag `--no-remote-actions` disables the module.

## Guest files and terminal

From **Devices**, choose **Guest files**. Enter the SSH host, account, credential and fingerprint confirmed by the server owner. Select a starting directory or use the account's home. A guest session lasts ten minutes and uses the host's SFTP subsystem. The app stores the temporary authorization and fingerprint in private state. Passwords and private keys are supplied to the core in memory for each operation.

The directory browser accepts regular files and real directories inside the scoped root. Pull one file up to 1 GiB into the app's downloads. The core compares XXH64 of the received stream with a read-back of the staged local file, then publishes it without overwriting another file. Android can export that verified copy through the system document picker. Closing the guest session revokes further browsing and publication. The host's own SSH account permissions also apply. [SFTP library](https://github.com/pkg/sftp)

An SSH terminal needs its own explicit one-use approval. It uses the SSH account's normal permissions, supports keyboard input and terminal resizing, and closes on revocation or expiry. Android also closes it when the app leaves the foreground. Clipboard copy and paste remain user actions. Guests use these features without a DeviceBridge agent on the SSH host. [Terminal renderer](https://pub.dev/packages/xterm3)
