# Developing Ghostty

To start development on Ghostty, you need to build Ghostty from a Git checkout,
which is very similar in process to [building Ghostty from a source tarball](http://ghostty.org/docs/install/build). One key difference is that obviously
you need to clone the Git repository instead of unpacking the source tarball:

```shell
git clone https://github.com/ghostty-org/ghostty
cd ghostty
```

> [!NOTE]
>
> Ghostty may require [extra dependencies](#extra-dependencies)
> when building from a Git checkout compared to a source tarball.
> Tip versions may also require a different version of Zig or other toolchains
> (e.g. the Xcode SDK on macOS) compared to stable versions — make sure to
> follow the steps closely!

When you're developing Ghostty, it's very likely that you will want to build a
_debug_ build to diagnose issues more easily. This is already the default for
Zig builds, so simply run `zig build` **without any `-Doptimize` flags**.

There are many more build steps than just `zig build`, some of which are listed
here:

| Command                         | Description                                                                                                            |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `zig build run`                 | Runs Ghostty                                                                                                           |
| `zig build run-valgrind`        | Runs Ghostty under Valgrind to detect memory misuses                                                                   |
| `zig build test`                | Runs unit tests (accepts `-Dtest-filter=<filter>` to only run tests whose name matches the filter)                     |
| `zig build update-translations` | Updates Ghostty's translation strings (see the [Contributor's Guide on Localizing Ghostty](po/README_CONTRIBUTORS.md)) |
| `zig build dist`                | Builds a source tarball                                                                                                |
| `zig build distcheck`           | Installs and validates a source tarball                                                                                |

## Extra Dependencies

Building Ghostty from a Git checkout on Linux requires some additional
dependencies:

- `blueprint-compiler` (version 0.16.0 or newer)

macOS users don't require any additional dependencies.

## Xcode Version and SDKs

Building the Ghostty macOS app requires that Xcode, the macOS SDK,
and the iOS SDK are all installed.

A common issue is that the incorrect version of Xcode is either
installed or selected. Use the `xcode-select` command to
ensure that the correct version of Xcode is selected:

```shell-session
sudo xcode-select --switch /Applications/Xcode-beta.app
```

> [!IMPORTANT]
>
> Main branch development of Ghostty is preparing for the next major
> macOS release, Tahoe (macOS 26). Therefore, the main branch requires
> **Xcode 26 and the macOS 26 SDK**.
>
> You do not need to be running on macOS 26 to build Ghostty, you can
> still use Xcode 26 beta on macOS 15 stable.

## Linting

### Prettier

Ghostty's docs and resources (not including Zig code) are linted using
[Prettier](https://prettier.io) with out-of-the-box settings. A Prettier CI
check will fail builds with improper formatting. Therefore, if you are
modifying anything Prettier will lint, you may want to install it locally and
run this from the repo root before you commit:

```
prettier --write .
```

Make sure your Prettier version matches the version of Prettier in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

Nix users can use the following command to format with Prettier:

```
nix develop -c prettier --write .
```

### Alejandra

Nix modules are formatted with [Alejandra](https://github.com/kamadorueda/alejandra/). An Alejandra CI check
will fail builds with improper formatting.

Nix users can use the following command to format with Alejandra:

```
nix develop -c alejandra .
```

Non-Nix users should install Alejandra and use the following command to format with Alejandra:

```
alejandra .
```

Make sure your Alejandra version matches the version of Alejandra in [devShell.nix](https://github.com/ghostty-org/ghostty/blob/main/nix/devShell.nix).

### Updating the Zig Cache Fixed-Output Derivation Hash

The Nix package depends on a [fixed-output
derivation](https://nix.dev/manual/nix/stable/language/advanced-attributes.html#adv-attr-outputHash)
that manages the Zig package cache. This allows the package to be built in the
Nix sandbox.

Occasionally (usually when `build.zig.zon` is updated), the hash that
identifies the cache will need to be updated. There are jobs that monitor the
hash in CI, and builds will fail if it drifts.

To update it, you can run the following in the repository root:

```
./nix/build-support/check-zig-cache-hash.sh --update
```

This will write out the `nix/zigCacheHash.nix` file with the updated hash
that can then be committed and pushed to fix the builds.
