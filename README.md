# CommandManager

CommandManager is a small command runner written in Swift. Describe reusable functions in a JSON file, then run an entry point with `cm MyFunction`. Each function runs its steps in order and stops as soon as a command, another function, or a built-in operation fails.

A step can run an executable, call another function from the configuration, or call a special function implemented in Swift. Commands use separate executable and argument fields, so arguments containing spaces stay intact.

## Requirements

- macOS 12 or later with Swift 5.9 or later on `PATH` to run the script.
- Git for the Git assertion built-ins.

Apple's Xcode Command Line Tools include Swift and Git. If needed, install them with `xcode-select --install`.

## Install

From this repository, run:

```sh
make install
```

This installs the executable Swift script as `~/.local/bin/cm`. It does not create or overwrite your configuration. To choose another installation prefix, use `make install PREFIX=/your/prefix`; the executable is placed in that prefix's `bin` directory.

Alternatively, install the script manually:

```sh
install -d "$HOME/.local/bin"
install -m 755 cm.swift "$HOME/.local/bin/cm"
```

Ensure `~/.local/bin` is on your `PATH`. For the default macOS shell, add this line to `~/.zshrc` if it is not already configured, then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

You can also run the script from the repository with `swift cm.swift` or `./cm.swift`.

## Configuration location

The default configuration is:

```text
~/Library/Application Support/CommandManager/cm.json
```

This uses macOS's Application Support directory for application configuration. CommandManager reads this file each time it runs. It does not search the current directory or parent directories for configuration files.

Start with the [example configuration](examples/cm.json). These commands preserve an existing configuration:

```sh
config_dir="$HOME/Library/Application Support/CommandManager"
install -d "$config_dir"
if [ ! -e "$config_dir/cm.json" ]; then
  cp examples/cm.json "$config_dir/cm.json"
fi
```

If the default file is missing, `cm` prints setup guidance. To use a different file for one invocation, pass `--config` before the function name:

```sh
cm --config ./examples/cm.json Hello Bruno
```

An explicitly selected configuration must exist. Relative configuration paths are resolved from the directory where `cm` starts.

### Minimum required version

The optional root-level `minimumVersion` field specifies the oldest compatible CommandManager version:

```json
{
  "minimumVersion": "0.3",
  "functions": {}
}
```

Use a string in `major.minor` or `major.minor.patch` form, with nonnegative integer components. Versions are compared numerically: `0.10` is newer than `0.2`, and `0.2` equals `0.2.0`. Prerelease and build suffixes are not supported. If the requirement exceeds the running version, `cm` reports the required and installed versions and exits before executing any commands, including when help is requested. Omitting the field keeps existing configurations valid; an explicit `null` or a malformed version is an error.

## Quick start

The example configuration defines three entry points:

```sh
cm
cm Hello Bruno
cm GitStatus
cm CheckPackage CommandManager
cm icons-sync
```

- `cm` shows the current version (`0.3`) and lists the available entry points and their descriptions.
- `Hello` prints a greeting using a required `name` argument.
- `GitStatus` prints a short Git status when run inside a Git working tree.
- `CheckPackage` enters the named folder, verifies that it is a Git repository root, then builds and tests its Swift package. Run it from the named folder itself or its immediate parent.
- `icons-sync` exports the configured Figma token, syncs Figma icons, and generates Unify icons.

This repository includes `Package.swift`, so `cm CheckPackage CommandManager` builds and tests CommandManager. Replace `CommandManager` with another Swift package's folder name to check that package instead.

## CLI

```text
cm [--config PATH] [--help | -h] [FUNCTION [ARGUMENTS...]]
```

| Invocation | Behavior |
| --- | --- |
| `cm` | Show the version, help, and entry points. |
| `cm --help` | Show the version, help, and entry points. |
| `cm --help Hello` | Show the description and required arguments for `Hello`. |
| `cm Hello Bruno` | Run `Hello` with `name` set to `Bruno`. |
| `cm --config ./cm.json Hello Bruno` | Run using the specified configuration. |

Options belong before the function name. Everything after the function name is a function argument, including values such as `--help` or `--config`. For example, `cm Hello --help` greets the literal name `--help`; use `cm --help Hello` for help about the function.

Names are case sensitive. Functions accept exactly the number of arguments declared by their `parameters` array. Quote arguments containing spaces as you normally would in your shell:

```sh
cm Hello "Bruno Smith"
```

## Define functions and settings

The root object contains a `functions` object and can contain a `settings` array. Settings are named string values shared by the configuration, but a function must declare the settings it uses:

```json
{
  "settings": [
    { "name": "FIGMA_TOKEN", "value": "replace-with-your-token" }
  ],
  "functions": {
    "icons-sync": {
      "description": "Sync Figma icons and generate Unify icons.",
      "entryPoint": true,
      "settings": ["FIGMA_TOKEN"],
      "steps": [
        {
          "builtin": "export",
          "args": ["FIGMA_TOKEN", "${FIGMA_TOKEN}"]
        },
        {
          "command": "node",
          "args": ["scripts/sync-figma-icons.mjs"]
        },
        {
          "command": "npx",
          "args": ["nx", "run", "unify:generate-unify-icons"]
        }
      ]
    }
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `description` | Yes | A nonempty description displayed in help. |
| `entryPoint` | No | `true` allows direct CLI invocation. Defaults to `false`. |
| `parameters` | No | Ordered names of required positional arguments. Defaults to `[]`. |
| `settings` | No | Names of root-level settings available to this function. Defaults to `[]`. |
| `steps` | Yes | Steps to run in order. |

Function names allow letters, digits, underscores, and hyphens, starting with a letter or underscore: `[A-Za-z_][A-Za-z0-9_-]*`. For example, `brew-update` is a valid entry point or helper name. Parameter and setting names use `[A-Za-z_][A-Za-z0-9_]*`; each list must be unique, and a function cannot use the same name for a parameter and a setting.

The `icons-sync` example exports `FIGMA_TOKEN` and then runs the icon synchronization and generation commands as separate steps, without invoking a shell. Settings are substituted exactly like parameters, but only in a function that lists them. Called functions declare their own settings; settings are not inherited from their caller. Store configuration files containing secrets with appropriate filesystem permissions.

An entry point can call other entry points or internal functions. A function without `"entryPoint": true` is internal: it cannot be invoked directly with `cm` and is omitted from the entry point list. This separates the public commands you use from the helpers they share.

Use standard JSON: comments and trailing commas are not supported.

## Step types

Every step has exactly one of `command`, `function`, or `builtin`, plus an optional `args` array of strings. Omitted `args` means `[]`.

### Run a command

```json
{
  "command": "swift",
  "args": ["build", "--configuration", "release"]
}
```

Executables are resolved using `PATH`, or you can specify an executable path. Commands inherit the environment and standard input, output, and error streams. Each command runs in the entry point's current working directory, shared across its function calls.

Interactive commands share the terminal's foreground process group with `cm`, so confirmation prompts can read your input normally. Terminal signals such as Ctrl+C reach the command as well as `cm`.

Before each configured command runs, CommandManager writes a grey `❯ ` prefix followed by its executable and expanded arguments in green to standard output. The color resets before the command's own output. Arguments are displayed with shell-style quoting when needed, including empty values, spaces, and special characters. For example, the greeting command for `cm Hello "Bruno Smith"` shows the expanded name as `'Bruno Smith'`. Every nonempty setting value in a printed command is replaced with `*****`; the command still receives the original value. These echoes, including their ANSI color sequences, are also present when output is redirected. Internal Git checks performed by built-ins are not echoed.

Arguments are passed directly to the executable. Spaces, `*`, `~`, pipes, redirection, and environment variable syntax have no special shell meaning. For example, `"args": ["*.swift"]` passes one literal argument, and `"args": ["~/Downloads"]` does not expand to your home directory. JSON still requires its own escaping, such as `\n` for a newline.

When shell behavior is needed, invoke a shell explicitly:

```json
{
  "command": "/bin/zsh",
  "args": ["-c", "printf '%s\\n' \"$$1\" | /usr/bin/wc -c", "cm-shell", "${name}"]
}
```

Here `$$1` becomes `$1`, and `name` is passed as a separate shell positional argument. `cm-shell` supplies the shell's `$0`. Keep user values out of the shell program string; pass them as positional arguments and quote their expansions. Normal command steps do not start a shell or load shell startup files.

### Call another configured function

```json
{
  "function": "BuildAndTest",
  "args": []
}
```

To call a helper with required arguments:

```json
{
  "functions": {
    "BuildRelease": {
      "description": "Build a Swift package in release mode.",
      "entryPoint": true,
      "steps": [
        { "function": "Build", "args": ["release"] }
      ]
    },
    "Build": {
      "description": "Build using the requested configuration.",
      "parameters": ["configuration"],
      "steps": [
        { "command": "swift", "args": ["build", "--configuration", "${configuration}"] }
      ]
    }
  }
}
```

The caller supplies the helper's arguments explicitly. A helper sees its own parameters, not the caller's parameters. Function calls are synchronous: the caller continues only after the helper succeeds.

### Call a Swift built-in

```json
{
  "builtin": "assertGitRoot"
}
```

Built-ins implement operations that need access to CommandManager's execution state. Their names are case sensitive and separate from configured function names.

## Arguments and substitution

Use `${parameter}` or a declared `${setting}` inside any step argument to insert the corresponding value. A placeholder can be the whole string or part of it:

```json
{
  "command": "/usr/bin/printf",
  "args": ["%s\n", "Building ${package}", "Price: $$5", "$${package}"]
}
```

For a function with a `package` parameter, these arguments contain the package value, the literal text `Price: $5`, and the literal text `${package}` respectively. `$$` escapes a dollar sign. Dollar signs that do not begin `${...}` or `$$`, such as `$HOME` or `$1`, are preserved literally.

Substitution applies only to `args`, not to executable names, function names, built-in names, or descriptions. Values remain single arguments even when they contain spaces. Substituted values are not expanded again, and there is no implicit environment-variable expansion.

## Built-in functions

### `inFolder` — one folder-name argument

```json
{ "builtin": "inFolder", "args": ["MyPackage"] }
```

`inFolder` changes the working directory for the remaining execution of the entry point. The change applies to the current function, its callers when they resume, and later function calls. Each time this step is reached:

1. If the current directory's name is already `MyPackage`, it does nothing.
2. Otherwise, it enters a direct child directory named `MyPackage`.
3. If that child directory does not exist, the function fails.

The argument must be a single folder name. Empty names, `.`, `..`, absolute paths, and names containing `/` are rejected. It does not search ancestors or arbitrary descendants.

An entry point and all functions it calls share one working directory. A directory change made by a helper persists after that helper returns: later steps in its caller and later sibling functions continue from that directory. Calling `inFolder` several times can descend one folder at a time, whether the calls are in the same function or different functions:

```text
Entry point starts in /work
  inFolder("App")          → /work/App
  Call Prepare
    inFolder("Packages")   → /work/App/Packages
    inFolder("Core")       → /work/App/Packages/Core
    Prepare returns        → /work/App/Packages/Core
  Entry point's next step   → /work/App/Packages/Core
  Call Check
    inFolder("Core")       → /work/App/Packages/Core (already there)
    Check's next command   → /work/App/Packages/Core
Entry point finishes; the launching terminal is still in /work
```

A command that runs `cd` inside a shell changes only that shell's directory. Use `inFolder` to affect subsequent CommandManager steps. The shared directory context lasts until the entry point finishes, whether successfully or with an error. CommandManager does not change the directory of the terminal that launched it.

### `assertGitRoot` — no arguments

```json
{ "builtin": "assertGitRoot" }
```

Succeeds only when the current directory is the root of a Git working tree. Use it before commands that must run from the repository root. It supports regular checkouts and linked Git worktrees.

### `assertGitRepository` — no arguments

```json
{ "builtin": "assertGitRepository" }
```

Succeeds at a Git working tree's root or in one of its subdirectories. Both Git assertions reject bare repositories and Git metadata directories such as `.git`, and fail if Git cannot determine a valid working tree.

Both assertions ignore `GIT_*` environment overrides for their internal checks, so they inspect the actual current directory even when invoked from a Git hook or alias. Configured command steps still inherit the full environment.

### `export` — environment-variable name and value

```json
{ "builtin": "export", "args": ["FIGMA_TOKEN", "${FIGMA_TOKEN}"] }
```

Sets an environment variable for the remaining steps of the current entry point, including called functions. Subsequent command steps inherit it and run directly without a shell. When the entry point finishes, CommandManager restores the variable's previous value or removes it if it was previously absent. The variable name must use `[A-Za-z_][A-Za-z0-9_]*`. This changes CommandManager's execution environment only; it cannot modify the terminal process that launched `cm`.

## Validation and failures

CommandManager validates the whole configuration before running any step, including functions that are not entry points. It rejects unknown fields, invalid names and types, explicit `null` values, duplicate or unknown settings, settings that were not declared by the function using them, unknown function or built-in references, incorrect argument counts, unknown parameter references, and recursive call cycles. Executable names, argument strings, and setting values must not contain NUL characters. Direct recursion and cycles involving several functions are not supported.

Every step must succeed before the next begins. A command with a nonzero exit status aborts the current function and every caller; later steps do not run. CommandManager preserves the failing command's exit status. Configuration errors and built-in failures also exit unsuccessfully with a diagnostic.

Directory changes persist throughout the entry point's call hierarchy and end when that entry point finishes. Other effects are not rolled back: files written by an earlier command remain if a later command fails. There are no automatic retries, parallel steps, or continue-on-error options.

## Add a built-in in Swift

Configured functions require no Swift changes. To add a new state-aware built-in, edit `cm.swift`:

1. Add the operation to the `Builtin` enum and update its `argumentCount` property.
2. Add its execution case in `Runner.executeBuiltin`.
3. Implement the operation using the supplied directory URL and `CommandError` for failures. Update the shared directory URL when the operation should affect later steps anywhere in the entry point's call hierarchy.
4. Add tests for success, invalid arguments, and relevant failures.
5. Reinstall with `make install` to update your installed copy.

The new operation can then be referenced by a `"builtin"` step. CommandManager does not load external Swift plugins from the configuration.

## Development

Tests use Swift Testing, included with Swift 6 or later, and run through Swift Package Manager:

```sh
swift test --disable-xctest
```

The equivalent `make test` target and other development checks are:

```sh
make test
make format
make check
make complexity
```

`swift test --disable-xctest` builds the `cm` executable as a test dependency and runs integration tests, including a smoke test of the standalone Swift script through the interpreter. Tests use temporary configurations and working directories, so they do not need to edit your personal configuration. XCTest and third-party test dependencies are not needed.

`Package.swift` uses Swift tools version 6.0 and supports testing and an optional compiled executable via `swift build`. `cm.swift` remains a standalone script compatible with Swift 5.9, and `make install` installs that script.

`make format` formats `cm.swift`, `Package.swift`, and the Swift tests with `xcrun swift-format`. `make check` checks their formatting and runs the tests. `make complexity` runs `codem8 --report-complexity -git-branch` and requires the separate `codem8` tool.

The installed `codem8` version does not support Swift. The required complexity command therefore analyzes zero source files in this all-Swift project; it does not validate the complexity of the implementation or tests.

Keep function bodies free of empty lines, and run the branch complexity report after changing code.

To remove the default installation:

```sh
make uninstall
```

Use the same `PREFIX` for uninstalling a custom installation. Uninstall removes the executable and preserves your configuration.

## GitHub checks and CodeRabbit

The [CI workflow](.github/workflows/ci.yml) checks Swift formatting and runs the Swift tests on pull requests and pushes.

[.coderabbit.yaml](.coderabbit.yaml) configures the CodeRabbit GitHub app that already has access to this repository. Reviews run automatically when a pull request is ready for review (not a draft), for every target branch. New pushes receive incremental reviews, and commit-count auto-pausing is disabled. Summaries, review status, and chat replies are enabled.

CodeRabbit can request changes for actionable feedback and approve pull requests once the latest commit has been reviewed, required review threads are resolved, and no Pre-Merge Checks are failing. This is enabled by `reviews.request_changes_workflow: true`.

CodeRabbit reads this configuration directly through its GitHub app, so its review workflow does not need a separate GitHub Actions job or an additional API key. See [CodeRabbit's configuration guide](https://docs.coderabbit.ai/getting-started/yaml-configuration). To request a review manually, comment `@coderabbitai review` on the pull request.

## License

See [LICENSE](LICENSE).
