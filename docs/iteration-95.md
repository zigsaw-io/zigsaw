# Iteration 95: The camera, and what else a run reaches

Started 2026-11-13, from "plan to implement hardware / device permissions". Until now an app's
permissions said nothing about hardware. A probe first tried each kind of device under each
sandbox, and the answer was narrower than the plan hoped: **one device, the camera, can be given
and taken away**, and only under `--sandbox=appcontainer`. That is what this iteration builds. The
rest is findings: the microphone opens in every sandbox, and USB, HID and Bluetooth devices in no
container. zigsaw is **0.95.0**. No image changes, so there's nothing to publish. How it's used is
in [the README](../README.md#devices), what was found in
[findings.md](findings.md#devices-iteration-95).

State at the start: 94 had landed (`8022a20`, Reproduce 43244069408 and Release v0.94.0 green).

## Outcome

- **`"permissions": { "devices": ["camera"] }`** in a recipe, and **`--device=camera`** /
  **`--nodevice=camera`** on `run` and `override` (also `--global`), layered as `--allow-host`
  and `--noallow-host` are.
- **Under `appcontainer`, a run with the camera holds Windows' capability for it**, and a run
  without it gets no camera. The run's relay never holds it.
- **Under `low`, a run with the camera gets a note**: Windows opens the camera for no program at
  low integrity. **Under `soft`**, a note says the list isn't enforced, when you changed it.
- **Installing says "permits your camera"**, and an update that adds the camera asks first.
- **A recipe naming another device is refused.** An image from a later zigsaw that names one runs
  without it, with a note.
- **`tests/devprobe.zig`** (`zig build devprobe`) reports what each sandbox reaches of a
  machine's devices, and is the suite's test app.

## The probe, and the gate

`zigsaw-devprobe report`, here (Windows 11 26300, unelevated):

| | host | low | container | + capability by name | + capability by class |
|---|---|---|---|---|---|
| camera, a frame through Media Foundation | ok | denied | denied | denied | **ok** |
| camera, its driver opened directly | ok | denied | denied | denied | denied |
| microphone | sound | sound | sound | sound | sound |
| speakers, GPU, printer | ok | ok | ok | | |
| Bluetooth | ok | ok | none seen | none seen | none seen |
| HID, USB | ok | ok | denied | denied | denied |
| serial, smart card, location | none here | | | | |

The gate was a container without the capability refused and one with it let in. Only the
camera's Media Foundation row passes, and only with the capability as the SID of the camera's
device class, not the one Windows derives from the name `webcam`.

## Decisions

Yours, by the question dialog, all the ones I recommended:

- **Devices: what the probe proves.** That came to one.
- **Under `low` and `soft`, tell and don't enforce.**
- **The probe may open the real camera and microphone**, warned first each time.

Mine:

- **No `microphone` device.** A name that takes nothing away under any sandbox would promise
  what zigsaw can't keep. The README and gaps.md say that no sandbox keeps an app from it.
- **No names for USB, HID, Bluetooth or serial.** A container can't open them whatever it holds.
  An app that needs one says it can't run under `appcontainer`, with the `unsupported` there is.
- **A note under `low` for an app with the camera.** This wasn't in the plan, which didn't
  expect Windows to refuse the camera there. Without the note such an app just shows no picture.
- **The class SID is written out in `appcontainer.zig`**, with its GUID beside it. The GUID is
  Windows' own for cameras and doesn't change; the probe reads it from the registry to check.
- **Unknown names pass in a pulled image and not in a recipe**, as the plan had it. The first is
  how `filesystem` treats a later zigsaw's folders.
- **The checks are C** (`tests/devprobe/checks.c`), built by zig against the Windows headers it
  ships. Media Foundation and WASAPI are COM tables I'd rather not declare by hand. The probe's
  driver is Zig, with a spawner of its own: netprobe's is tied to its sockets, so the plan's
  shared file would have meant rewriting netprobe.

## Files

- `src/oci.zig`: `Device`, `isDeviceName`, `Permissions.devices`, its checks, its words, and
  what an update adds.
- `src/override.zig`: `devices` / `nodevices` in the settings, `devicesOf`.
- `src/main.zig`: `--device`, `--nodevice`, the help.
- `src/recipe.zig`: a recipe's devices must be ones this zigsaw knows.
- `src/appcontainer.zig`: `deviceCapability`.
- `src/run.zig`: the run's devices, the capability after the app's own, the notes.
- `tests/devprobe.zig`, `tests/devprobe/checks.c`, `build.zig`: the probe.
- `tests/devices.sh` (new, CI after hosts.sh).

## Results

| what | result |
|---|---|
| unit tests (`zig build test`) | pass |
| `tests/devices.sh` (new) | 20 ok |
| `DEVICES_REAL=1 tests/devices.sh`, with the real camera through zigsaw | 26 ok: a frame under `appcontainer` with the device and under `soft`; none without the device, after `--nodevice`, or under `low` |
| `tests/hosts.sh`, `tests/network.sh`, `tests/limits.sh`, `tests/sandbox.sh` (TMPDIR on D:), `tests/shims.sh` | 21, 26, 68, 142 and 57 ok; 0 failed |
| the package | `zigsaw.exe` `f1f97b36`, `zigsaw-relay.exe` `ae662bd0`, 0.95.0; Defender finds nothing in its six programs |

## Not checked

- **A real app with a camera.** The app in every row is the probe. No published image has
  `devices`, and none was run against the camera. Which of them capture through Media
  Foundation and which through DirectShow isn't known: the second kind gets no camera in a
  container even with the device.
- **Other machines.** One laptop, one camera, Windows 11 26300. Windows 10, Server, a USB
  camera, a camera with Windows' switches off: not seen. The runner has no camera, so CI's rows
  read the run's token and the probe's report there says "none".
- **Serial ports, smart cards, location**: none on this machine.
- **The update question and a pulled image with an unknown device** are checked by unit tests
  only. The suite builds its apps locally, where neither comes up.
- **A standard user.** The suite ran as this account, which is an administrator's, unelevated.
- `tests/matrix.sh`, `upgrade.sh`, `rollback.sh` and the GUI suites weren't run.

## Yours to do

- Commit and push. I read the Reproduce run, `tests/devices.sh` and the probe's rows on the
  runner first.
- The tag `v0.95.0` is yours; I read the Release run after it.
