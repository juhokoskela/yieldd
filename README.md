# yieldd

`yieldd` will turn spare Mac resources into ephemeral GitHub Actions runners. This first package only provides host diagnostics, Apple container machine management, and a temporary Docker-in-machine integration test.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer
- Swift 6.2 or newer
- Apple `container` with container machine support
- A running container system

Start the container system outside `yieldd` if needed:

```sh
container system start
```

`yieldd doctor` never starts or changes the container system.

## Build and test

```sh
swift build
swift test
swift run yieldd doctor
```

## Guest image

Build the Ubuntu 24.04 guest image from the repository root:

```sh
container build -t local/yieldd-guest:dev Guest
```

The image boots systemd as PID 1 and runs Docker from Ubuntu's `docker.io` package. Guest commands run as the unprivileged `runner` user, which belongs to the `docker` group.

## Machine integration test

After building the guest image, run:

```sh
swift run yieldd machine-test
```

The command creates a uniquely named machine with no host home mount, runs `docker info`, runs `docker run --rm hello-world`, and destroys the machine. It attempts cleanup after every creation attempt, including failed ones.
