# deepseek-harness-harmony

Run `dsh` on HarmonyOS devices via `hdc`.

## Usage

```bash
./scripts/run-dsh-harmony.sh --help
./scripts/run-dsh-harmony.sh --version
./scripts/run-dsh-harmony.sh <dsh-arguments...>
```

To target a specific device, set `HDC_SERIAL`:

```bash
HDC_SERIAL=<serial> ./scripts/run-dsh-harmony.sh --version
```

## Requirements

- `hdc` installed and available on `PATH`
- At least one connected HarmonyOS target (`hdc list targets`)
- `dsh` installed on the HarmonyOS target

## Local smoke test

```bash
./tests/run-dsh-harmony-smoke.sh
```
