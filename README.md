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
  - keypads as multi-component devices, with a level control on KeypadLinc dimmers
  - mini remotes and RemoteLincs as multi-button remotes
  - fan controllers
  - outlets
  - motion sensors
  - contact sensors
  - IOLinc as a relay plus sensor multi-component device
- Skips non-Insteon eISY nodes, including node-server, Matter, Z-Wave, and Zigbee nodes.
- Splits FanLinc modules into separate SmartThings devices for the light dimmer and fan motor.
- Adds eISY scenes listed in the controller's `Scene IDs` setting as switches. A scene is on while any of its members is on, matching PyISY.
- Keypad secondary buttons display their eISY names and current on/off status with a read-only custom status capability.
- Keypad and remote buttons report presses for SmartThings routines (see Buttons below).
- Reports thermostat humidity for thermostats that measure it.
- Marks a device offline while the eISY reports an Insteon communication error for it, when its node is removed from the eISY (or its scene from `Scene IDs`), and marks the controller and all devices offline when the eISY has been unreachable for 60 seconds.
- Sends local commands through `/rest/nodes/<node>/cmd/...`.
- Uses a plain-HTTP `/rest/subscribe` WebSocket connection for live updates. Automatic polling fallback is disabled to protect v3 hubs with large Insteon installations.

## Install And Test

1. Enroll and install the driver at https://bestow-regional.api.smartthings.com/invite/d429GWDwQbjo

2. In the SmartThings app, run nearby device discovery. The driver creates `eISY Controller`.

3. Open the controller device settings and enter:

   - eISY host or IP (IP address works best)
   - protocol (HTTP is faster and uses websockets)
   - port (80)
   - username (your eISY username, same as what you use to login to the eISY Admin Console)
   - password

   - scene IDs (optional): a comma-separated list such as `12345, 23456`

4. Tap `Scan for devices` on the controller, or refresh the controller. Supported Insteon nodes and the listed scenes should appear as child devices.

## Scenes

Scenes are opt-in. To find a scene's ID, select the scene in the eISY Admin Console and use the address shown for it, or look up its `<address>` at `http://<eisy>/rest/nodes`. Enter the IDs in the controller's `Scene IDs` setting; saving the setting rescans and creates a switch for each new scene, named after the scene in eISY.

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

A toggle button alternates between `up` and `down`. The first button is the device's main component; the others are `button2` and up, in eISY button order.

## Notes

- eISY/IoX must be reachable from the SmartThings hub on the local network.
- HTTPS REST calls are supported when the hub runtime exposes `ssl.https`.
- The WebSocket subscriber currently supports plain HTTP. HTTPS configurations can still use manual scan and refresh, but they do not receive live WebSocket updates.
- Node classification is heuristic because eISY node metadata varies by device generation and naming. Use `ignoredNodes` to skip unwanted nodes.
- Programs are intentionally out of scope.
