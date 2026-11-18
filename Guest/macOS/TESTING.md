# Validate a macOS runner template

Prepare the guest scripts, console login, Xcode, simulator runtime, and pinned SSH credentials as described in the [template guide](../../Docs/macos-template.md). Shut down the template before testing it.

Build the signed app and check the disposable clone through the normal networking backend.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-local-app.sh
.build/yieldd.app/Contents/MacOS/yieldd machine-test --template /absolute/path/VM.bundle
```

This checks GUI readiness, simulator boot, and screenshot capture over pinned SSH through the relay. To verify GitHub job pickup on this Mac, run the [reserved single-job test](../../README.md#reserved-single-job-tests) with a fresh routing label. Confirm the workflow conclusion in GitHub and check the host cleanup result. An interrupted run can be recovered with `yieldd recover`, including old probe clones on the configured volume.
