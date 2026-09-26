# CommandManager

CommandManager turns recurring command-line tasks into reusable workflows you can run with a single command. Use it to automate routines such as building and testing a project, checking a Git repository, or syncing and generating assets.

Define your workflows as named functions in a JSON configuration, then run an entry point with `cm MyFunction`. Functions combine commands, reusable helper functions, and built-in operations into an ordered sequence of steps. Parameters, shared settings, conditional steps, and captured command output let you adapt a workflow to different inputs without duplicating its definition.

CommandManager is written in Swift and runs on macOS. It handles the details of passing arguments, managing working directories and environment variables, and showing which commands are running. If a step fails, the workflow stops so later steps do not run on an unsuccessful result.

## Requirements

- macOS 12 or later.
- Swift 6 or later on `PATH` to build, install, or run from source. The installed executable does not invoke the Swift compiler.
- Git for the Git assertion built-ins.

Apple's Xcode Command Line Tools include Swift and Git. If needed, install them with `xcode-select --install`.

## Install

From this repository, run:

```sh
make install
```

This builds a release executable and installs it as `~/.local/bin/cm`. It does not create or overwrite your configuration. To choose another installation prefix, use `make install PREFIX=/your/prefix`; the executable is placed in that prefix's `bin` directory.

Ensure `~/.local/bin` is on your `PATH`. For the default macOS shell, add this line to `~/.zshrc` if it is not already configured, then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

You can also run from the repository with `swift run cm`, for example `swift run cm --help`. The former single-file `swift cm.swift` and `./cm.swift` entry points have been replaced by the package executable.

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

- `cm` shows the current version (`0.4`) and lists the available entry points and their descriptions.
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

Options belong before the function name. Everything after the function name is a function argument. For functions without declared boolean options, values such as `--help` or `--config` remain literal arguments. For example, `cm Hello --help` greets the literal name `--help`; use `cm --help Hello` for help about the function.

Names are case sensitive. Functions accept exactly the number of positional arguments declared by their `parameters` array. Functions can additionally declare boolean `options` as described below. Quote arguments containing spaces as you normally would in your shell:

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
| `options` | No | Object mapping boolean option names to help descriptions. Defaults to `{}`. |
| `requireAnyOption` | No | Show function help without running steps when no declared option is selected. Defaults to `false`; applies to CLI entry points. |

Function names allow letters, digits, underscores, and hyphens, starting with a letter or underscore: `[A-Za-z_][A-Za-z0-9_-]*`. For example, `brew-update` is a valid entry point or helper name. Parameter and setting names use `[A-Za-z_][A-Za-z0-9_]*`; each list must be unique, and a function cannot use the same name for a parameter and a setting.

The `icons-sync` example exports `FIGMA_TOKEN` and then runs the icon synchronization and generation commands as separate steps, without invoking a shell. Settings are substituted exactly like parameters, but only in a function that lists them. Called functions declare their own settings; settings are not inherited from their caller. Store configuration files containing secrets with appropriate filesystem permissions.

An entry point can call other entry points or internal functions. A function without `"entryPoint": true` is internal: it cannot be invoked directly with `cm` and is omitted from the entry point list. This separates the public commands you use from the helpers they share.

Use standard JSON: comments and trailing commas are not supported.

## Step types

Every step has exactly one of `command`, `function`, or `builtin`, plus an optional `args` array. Arguments are strings or explicit array expansions for commands and function calls. Omitted `args` means `[]`. Steps also support `when`, `saveAs`, `capture`, `sensitive`, and `label` as described below.

### Run a command

```json
{
  "command": "swift",
  "args": ["build", "--configuration", "release"]
}
```

Executables are resolved using `PATH`, or you can specify an executable path. Commands inherit the environment and standard input, output, and error streams. Each command runs in its current function's working directory, inherited by nested function calls.

Interactive commands share the terminal's foreground process group with `cm`, so confirmation prompts can read your input normally. Terminal signals such as Ctrl+C reach the command as well as `cm`.

Before each configured command runs, CommandManager writes a grey `❯ ` prefix followed by its executable and expanded arguments in green to standard output. The color resets before the command's own output. Arguments are displayed with shell-style quoting when needed, including empty values, spaces, and special characters. For example, the greeting command for `cm Hello "Bruno Smith"` shows the expanded name as `'Bruno Smith'`. Every nonempty setting value and registered sensitive runtime value in a printed command is replaced with `*****`; the command still receives the original value. These echoes, including their ANSI color sequences, are also present when output is redirected. Internal Git checks performed by built-ins are not echoed.

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

Use `${parameter}`, a declared `${setting}`, an option name, or a previously saved runtime value inside any step argument to insert the corresponding scalar value. A placeholder can be the whole string or part of it:

```json
{
  "command": "/usr/bin/printf",
  "args": ["%s\n", "Building ${package}", "Price: $$5", "$${package}"]
}
```

For a function with a `package` parameter, these arguments contain the package value, the literal text `Price: $5`, and the literal text `${package}` respectively. `$$` escapes a dollar sign. Dollar signs that do not begin `${...}` or `$$`, such as `$HOME` or `$1`, are preserved literally.

Substitution applies only to `args`, not to executable names, function names, built-in names, or descriptions. Values remain single arguments even when they contain spaces. Substituted values are not expanded again, and there is no implicit environment-variable expansion.

## Workflow values and conditions

Declare boolean options as a name-to-description object on a function:

```json
"options": { "build": "Build the package", "check": "Check the package", "all": "Run everything" },
"requireAnyOption": true
```

Invoke with `cm MyFunction --build --check`. Unselected options are false. Names are case sensitive, follow the function-name syntax, and cannot conflict with parameters or declared settings. Unknown `--options` fail. Use `--` to end option parsing when passing a positional value starting with `--`. Functions without declared options retain the previous literal-argument behavior. `--all` has no special built-in meaning: explicitly include it in the relevant conditions. Helper calls may pass declared options in their `args`; helpers do not inherit the caller's option values.

A step's optional `when` is a variable name or a condition object with exactly one of `any`, `all`, or `not`:

```json
{ "function": "Build", "when": { "any": ["build", "all"] } }
```

Conditions can nest. `any` and `all` require nonempty arrays and short-circuit in order. Values must be JSON booleans or the strings `true`/`false`. The condition is evaluated before arguments, so a skipped step does not attempt to resolve its arguments. `label` supplies a human-readable name included in failure diagnostics.

### Save and use values

Value-producing builtins require `saveAs`; it defines a unique function-local identifier:

```json
{ "builtin": "set", "args": ["release-${name}"], "saveAs": "releaseName" }
```

Saved values cannot overwrite parameters, declared settings, options, or earlier outputs. Helpers have their own local values; pass scalar values explicitly through their arguments. Forward references are rejected before execution. A reference to an earlier conditional output is allowed, but fails at runtime if the producing step was skipped. Guard dependent steps with the same condition when needed.

JSON objects and arrays remain structured. Scalar substitution does not serialize them or split them into words. `jsonGet` selects fields; an explicit spread expands a string array into separate arguments:

```json
{ "command": "tool", "args": ["run", { "spread": "extraArgs" }, "--verbose"] }
```

Each array element remains exactly one argument, including empty strings or values containing spaces. Only string arrays can be spread. Commands and configured function calls support spreads; builtins do not. Dynamic function argument counts are checked at runtime.

### Capture command output

Specify both `capture` and `saveAs` on a command:

```json
{ "command": "tool", "args": ["describe", "--json"], "capture": "json", "saveAs": "details" }
```

Capture modes are `text` (exact UTF-8 stdout), `trimmed` (remove leading/trailing whitespace and newlines), and `json` (decode stdout as JSON). Captured stdout is not printed. Stderr and stdin remain attached to the caller, and nonzero exits still abort execution with the original status. Output is collected in a private temporary file, removed on completion or handled failure, avoiding pipe-buffer deadlocks for large output. Uncaptured commands retain their existing terminal behavior.

### Sensitive values

Add `"sensitive": true` to a step that saves a result. Its scalar values are registered for redaction in subsequent command echoes, `log` messages, and execution error messages, including across helper calls. Marking a JSON object sensitive registers its scalar descendants. Settings remain redacted automatically. Redaction applies to CommandManager's messages; it does not filter output or stderr printed by external commands. Avoid passing sensitive values to commands that print them.

## Built-in functions

### `inFolder` — one folder-name argument

```json
{ "builtin": "inFolder", "args": ["MyPackage"] }
```

`inFolder` changes the working directory for the remaining steps of the current function and any functions it calls. When the current function returns, its caller's directory is restored. Each time this step is reached:

1. If the current directory's name is already `MyPackage`, it does nothing.
2. Otherwise, it enters a direct child directory named `MyPackage`.
3. If that child directory does not exist, the function fails.

The argument must be a single folder name. Empty names, `.`, `..`, absolute paths, and names containing `/` are rejected. It does not search ancestors or arbitrary descendants.

Each function starts in its caller's directory. A directory change made by a helper is available to nested calls, but it does not leak back to the caller or sibling functions:

```text
Entry point starts in /work
  Call Prepare
    inFolder("App")        → /work/App
    Prepare's command       → /work/App
    Call Build
      inFolder("Core")     → /work/App/Core
      Build's command       → /work/App/Core
    Build returns           → /work/App
    Prepare's next command  → /work/App
  Prepare returns           → /work
  Call Check
    Check's command         → /work
Entry point finishes; the launching terminal is still in /work
```

A command that runs `cd` inside a shell changes only that shell's directory. Use `inFolder` to affect subsequent steps in the same function and its nested calls. CommandManager does not change the directory of the terminal that launched it.

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

### Workflow builtins

| Builtin | Arguments | Result / behavior |
| --- | --- | --- |
| `set` | value | Save the substituted string using `saveAs`. |
| `inDirectory` | path | Enter an existing absolute or relative directory; restore the caller's directory on function return. |
| `pathJoin` | base, component… | Save a joined path. Requires a nonempty base; later components must be nonempty relative paths. Does not check existence or expand `~`. |
| `assertPath` | path, kind | Require a regular `file` or a `directory`. |
| `gitRoot` | none | Save the current Git working tree root, including linked worktrees. |
| `assertDirectChild` | child, parent | Require existing directories and verify direct parentage after resolving symlinks. |
| `assertGitClean` | none | Require a Git working tree with no staged, unstaged, or untracked changes. Ignored files do not count. |
| `readJson` | path | Read and save a JSON value. |
| `jsonGet` | variable name, JSON pointer | Select and save a required JSON value; missing, null, and whitespace-only strings fail. |
| `log` | message | Print a message with sensitive values redacted. |

All value-producing builtins require `saveAs`; other builtins reject it. Paths resolve relative to the current function's directory. The new Git builtins, like existing Git assertions, ignore `GIT_*` environment overrides. `assertGitClean` checks the entire working tree even when called from a subdirectory.

`jsonGet` uses a literal variable name as its first argument, not `${...}`. Its second argument uses JSON pointer syntax: `/items/0/id`, `/posthog-api-key`, or an empty string for the entire value. Escape a key's `/` as `~1` and `~` as `~0`. Array indices are zero-based. Objects and arrays can be selected for further extraction or expansion.

```json
{ "builtin": "readJson", "args": ["settings.json"], "saveAs": "settingsData", "sensitive": true }
```

```json
{ "builtin": "jsonGet", "args": ["settingsData", "/service/token"], "saveAs": "token" }
```

## Validation and failures

CommandManager validates the whole configuration before running any step, including functions that are not entry points. It rejects unknown fields, invalid names and types, explicit `null` values, duplicate or unknown settings, settings that were not declared by the function using them, unknown function or built-in references, incorrect argument counts, unknown parameter references, and recursive call cycles. Executable names, argument strings, and setting values must not contain NUL characters. Direct recursion and cycles involving several functions are not supported.

Every step must succeed before the next begins. A command with a nonzero exit status aborts the current function and every caller; later steps do not run. CommandManager preserves the failing command's exit status. Configuration errors and built-in failures also exit unsuccessfully with a diagnostic.

Directory changes are scoped to the function that makes them and its nested calls; a caller's directory is restored when a helper returns. Other effects are not rolled back: files written by an earlier command remain if a later command fails. There are no automatic retries, parallel steps, or continue-on-error options.

## Add a built-in in Swift

Configured functions require no Swift changes. To add a new state-aware built-in, edit `Sources/cm/Execution/Builtins.swift`:

1. Add the operation to the `Builtin` enum and update `argumentCount` and `returnsValue`.
2. Add its execution case in `BuiltinExecutor.execute`.
3. Implement the operation using the supplied directory URL and `CommandError` for failures. Return a `RuntimeValue` for value-producing operations. Directory changes affect the current function and nested calls.
4. Add tests for success, invalid arguments, and relevant failures.
5. Reinstall with `make install` to update your installed copy.

The new operation can then be referenced by a `"builtin"` step. CommandManager does not load external Swift plugins from the configuration.

## Source layout

The executable target lives in `Sources/cm/`. Each file owns a specific responsibility:

| File | Responsibility |
| --- | --- |
| `main.swift` | Start the CLI and translate failures into exit statuses. |
| `CLI/CLI.swift` | Parse CLI options, display help, and invoke the entry point. |
| `Configuration/Configuration.swift` | Define functions/settings and validate the configuration and call graph. |
| `Configuration/ConfigurationIO.swift` | Locate and decode configuration files with strict JSON diagnostics. |
| `Workflow/Workflow.swift` | Decode steps, conditions, and argument expansions. |
| `Workflow/RuntimeValue.swift` | Store structured results and render argument templates. |
| `Execution/Runner.swift` | Execute function sequences with scoped variables, directories, and environment. |
| `Execution/Builtins.swift` | Define and execute builtin operations, including filesystem and Git checks. |
| `Execution/CommandExecution.swift` | Execute configured commands, capture output, and check exit statuses. |
| `Execution/ProcessExecution.swift` | Resolve executables and launch/wait for processes with terminal and signal handling. |
| `CLI/Output.swift` | Format command echoes and redact sensitive values. |
| `CommandError.swift`, `Version.swift` | Shared errors, argument-count checks, and version compatibility. |

The runner delegates builtin and external-command execution to separate executors. Their implementation helpers stay private to their files. All files compile into one executable; no source files or plugins are loaded at runtime.

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
```

`swift test --disable-xctest` builds the `cm` executable as a test dependency and runs integration tests, including a smoke test that runs a copy of the executable outside the source tree. Tests use temporary configurations and working directories, so they do not need to edit your personal configuration. XCTest and third-party test dependencies are not needed.

`Package.swift` uses Swift tools version 6.0. `swift build` builds the debug executable; `make build` builds the release executable. `make install` builds and installs the release executable, preserving existing configuration. Reinstall after changing source files.

`make format` formats `Sources/`, `Package.swift`, and the Swift tests with `xcrun swift-format`. `make check` checks their formatting and runs the tests.

Keep function bodies free of empty lines.

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
