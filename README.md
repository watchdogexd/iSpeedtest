# iSpeedtest

A Flutter-based CDN speed test app with Material 3 UI, DoH-based node
resolution, selectable test IPs, and download/upload throughput measurement.

## Upload Measurement

Upload uses the same Dart `HttpClient` path on Android and other platforms. The
client writes request-body bytes for the configured 8 second upload window, then
waits only a short response grace period. Apple CDN response timeouts are treated
as an expected transfer stop, so throughput is calculated from bytes consumed by
the request stream rather than from a server `acceptedBytes` response field.

## macOS Upload Probe

Run the standalone probe with the same user agent and upload-window semantics as the app:

```sh
../flutter/bin/dart tool/upload_probe.dart --ip <test-ip> --mode single --duration 8 --response-timeout 2
```
