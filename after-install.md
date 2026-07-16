# zhc-fabric installed

You just configured the **inference** endpoint Hermes will use for committee votes
(base URL, model, optional API key). Next:

## 1. Start the sidecar

```bash
# Preferred: wizard writes local config + starts the process
~/.hermes/plugins/zhc-fabric/scripts/setup.sh

# Or start with env already set from install:
~/.hermes/plugins/zhc-fabric/scripts/install-sidecar.sh start
```

## 2. Smoke test

```bash
~/.hermes/plugins/zhc-fabric/scripts/smoke.sh
```

## 3. Use from Hermes

- Restart the gateway if it was already running: `hermes gateway restart`
- In chat: `/fabric status` then ask for a committee / `fabric_consensus`

## Reconfigure later

```bash
~/.hermes/plugins/zhc-fabric/scripts/setup.sh
# or edit:  $HERMES_HOME/zhc-fabric/sidecar.env
# or:       hermes config env-path  (ZHC_FABRIC_DEFAULT_* vars)
```

Local models usually need **URL + model only** (empty API key). Cloud providers need a key.
