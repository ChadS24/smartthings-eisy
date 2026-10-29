# eISY Insteon SmartThings Edge Driver

This package contains a local SmartThings Edge driver for Universal Devices eISY / IoX controllers with Insteon nodes.

## What It Does

- Creates one `eISY Controller` bridge device during SmartThings discovery.
- Adds a `Scan for devices` button on the `eISY Controller` device that scans eISY and creates supported child devices.
- Uses controller preferences for eISY host, protocol, port, username, password, and ignored node patterns.
- Reads eISY nodes from `/rest/nodes` and status from `/rest/status`.
- Auto-creates supported Insteon child devices:
  - switches
  - dimmers
  - keypads as multi-component devices, with a level control on KeypadLinc dimmers, and a 6-button layout for 6-button KeypadLincs
  - mini remotes and RemoteLincs as multi-button remotes
  - fan controllers
  - outlets
  - motion sensors, with dusk/dawn and low battery on Insteon Motion Sensors, plus tamper, temperature and light level on the Motion Sensor II
  - contact sensors
  - Smoke Bridges as smoke and carbon monoxide detectors, with low battery
  - IOLinc as a relay plus sensor multi-component device
- Skips non-Insteon eISY nodes, including node-server, Matter, Z-Wave, and Zigbee nodes.
- Splits FanLinc modules into separate SmartThings devices for the light dimmer and fan motor.
- Gives each load of a multi-load module, such as a dual outlet, its own SmartThings device.
- Adds eISY scenes listed by name or ID in the controller's `Scene IDs` setting as switches. A scene is on while any of its members is on, matching PyISY.
- Keypad secondary buttons display their eISY names and current on/off status with a read-only custom status capability.
- Keypad and remote buttons report presses for SmartThings routines (see Buttons below).
- Reports thermostat humidity for thermostats that measure it.
- Turns a fan on at the speed it last ran at.
- Marks a device offline while the eISY reports an Insteon communication error for it, when its node is removed from the eISY (or its scene from `Scene IDs`), when a sensor with a heartbeat has sent none for 25 hours, and marks the controller and all devices offline when the eISY has been unreachable for 60 seconds.
- Shows the live-update connection's status on the controller.
- Sends local commands through `/rest/nodes/<node>/cmd/...`.
- Uses a `/rest/subscribe` WebSocket connection for live updates, over TLS when the protocol is HTTPS. Automatic polling fallback is disabled to protect v3 hubs with large Insteon installations.

## Custom Capabilities

The driver uses four custom capabilities in the `oftentrust07380` namespace. Each must be created in that namespace before a driver package that uses it can be uploaded. `scanForDevices` and `keypadButtonStatus` already exist. To add the connection status and dusk/dawn capabilities, run from the repository root:

```bash
smartthings capabilities:create -n oftentrust07380 -i capabilities/eisy-connection-status.json
smartthings capabilities:presentation:create oftentrust07380.eisyconnectionstatus --capability-version 1 -i capabilities/eisy-connection-status-presentation.json
smartthings capabilities:create -n oftentrust07380 -i capabilities/dusk-dawn.json
smartthings capabilities:presentation:create oftentrust07380.duskdawn --capability-version 1 -i capabilities/dusk-dawn-presentation.json
```

SmartThings gives each new capability an English translation that reuses its internal name, and the app shows that translation as the card title, so a card reads `eisyConnectionStatus` instead of `Live updates`. To show readable titles and values, apply the English translations:

```bash
smartthings capabilities:translations:upsert oftentrust07380.eisyconnectionstatus --capability-version 1 -i capabilities/eisy-connection-status-translation-en.json
smartthings capabilities:translations:upsert oftentrust07380.scanfordevices --capability-version 1 -i capabilities/scan-for-devices-translation-en.json
smartthings capabilities:translations:upsert oftentrust07380.duskdawn --capability-version 1 -i capabilities/dusk-dawn-translation-en.json
smartthings capabilities:translations:upsert oftentrust07380.keypadbuttonstatus --capability-version 1 -i capabilities/keypad-button-status-translation-en.json
```

Translations change only display text, so they take effect without a driver update; the app may need restarting to show them.

The controller uses its own layout, `presentations/eisy-controller-device-config.json`, which shows the connection status once, as the controller's status, instead of a second time as a separate card. `profiles/eisy-controller.yaml` refers to it by its `vid`. After changing the layout, create it again and put the `vid` it returns in the profile:

```bash
smartthings presentation:device-config:create -i presentations/eisy-controller-device-config.json
```

## Install And Test

1. Enroll and install the driver at https://bestow-regional.api.smartthings.com/invite/d429GWDwQbjo

2. In the SmartThings app, run nearby device discovery. The driver creates `eISY Controller`.

3. Open the controller device settings and enter:

   - eISY host or IP (IP address works best)
   - protocol (HTTP or HTTPS; both get live updates)
   - port (80)
   - username (your eISY username, same as what you use to login to the eISY Admin Console)
   - password

   - scene IDs (optional): a comma-separated list of scene names or IDs, such as `Front Downlights, 23456`

4. Tap `Scan for devices` on the controller, or refresh the controller. Supported Insteon nodes and the listed scenes should appear as child devices.

## Keeping Devices In Sync

- The driver rescans on its own when eISY reports devices or scenes added, removed, renamed, moved, or enabled/disabled.
- If eISY can't be reached when the driver starts (for example after a power outage, when the hub boots first), the scan is retried with increasing delays, up to every 5 minutes, and again as soon as the live connection to eISY comes back.
- A device you delete in the SmartThings app stays deleted: automatic rescans don't recreate it. Tapping `Scan for devices` restores every deleted device. To keep a device out for good, add it to `Ignored node patterns`.

## Scenes

Scenes are opt-in. Enter each scene's name (any capitalization) or ID in the controller's `Scene IDs` setting; saving the setting rescans and creates a switch for each new scene, named after the scene in eISY.

- Tapping `Scan for devices` logs every eISY scene's name and ID.
- A name that matches no scene, or several scenes with the same name, is skipped with a warning in the log; the warning lists every scene, so you can use an ID instead.

- Turning the switch on or off sends `DON` / `DOF` to the scene, so members go to their scene on levels.
- The switch is on while any member with a light level is on. Sensors and remotes that control the scene are ignored.
- Removing an ID from the setting does not delete its SmartThings device; delete it in the SmartThings app.

## Buttons

Every keypad button and remote button has the standard SmartThings button capability, so routines can trigger on it. Insteon commands map to button values:

| Press | Button value |
| --- | --- |
| On (`DON`) | `up` |
| Off (`DOF`) | `down` |
| Fast on, double-tap (`DFON`) | `up_2x` |
| Fast off, double-tap (`DFOF`) | `down_2x` |
| Hold to brighten (`FDUP`) | `up_hold` |
| Hold to dim (`FDDOWN`) | `down_hold` |
| Hold on older firmware (`BMAN`) | `held` |

A toggle button alternates between `up` and `down`. The first button is the device's main component; the others are `button2` and up, in eISY button order. On a 6-button KeypadLinc, the main component is the On/Off pair and `button2` to `button5` are buttons A to D.

## Sensors

Insteon sensors spread their readings over several nodes. The driver combines them on one device:

- **Motion Sensor (2842) and Motion Sensor II (2844):** subnode 2 sets dusk/dawn (Dark/Light), and subnode 3 sets the battery level to warning when the battery is low. Until a subnode first reports, the battery level reads normal. On the Motion Sensor II, subnode A (or 10) reports tampering, and the motion node's temperature and light level are shown. Light level is shown only when the eISY reports it in lux.
- **Open/close and leak sensors:** subnode 4 is a heartbeat the sensor sends about once a day. A sensor that sends none for 25 hours is marked offline, and comes back online with its next heartbeat.
- **Smoke Bridge (2982-222):** subnode 1 (Smoke) and subnode 2 (CO) set the smoke and carbon monoxide alarms, subnode 5 (Clear) clears both, and subnode 6 (Low Bat) sets the battery level to warning. The Test, Unknown Message and Malfunction subnodes aren't shown. The eISY can leave Smoke or CO On after an alarm or test has ended; once the driver has seen an all clear, that stale On doesn't bring the alarm back, but before then the driver can't tell it from a real alarm. Querying the Smoke Bridge in the eISY Admin Console turns a stale On off.

## Notes

- eISY/IoX must be reachable from the SmartThings hub on the local network.
- HTTPS REST calls are supported when the hub runtime exposes `ssl.https`.
- With HTTPS, the eISY's certificate is not verified, because the eISY uses a self-signed certificate. This applies to REST calls and the WebSocket.
- Node classification is heuristic because eISY node metadata varies by device generation and naming. Use `ignoredNodes` to skip unwanted nodes.
- Programs are intentionally out of scope.
