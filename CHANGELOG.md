# PowerMark — Change Log & Bug Fixes

**Project:** PowerMark ESP32 IoT Power Monitor  
**Files:** `power_monitor_with_ble_provisioning.ino` · `index.html`  
**Platform:** ESP32 + HiveMQ MQTT · Single-file HTML/JS dashboard

---

## Session 1 — Remove Triple-Tap PIN Gate for MQTT Config

### Problem
MQTT broker configuration was locked behind a triple-tap gesture on the version row in Settings, followed by a PIN entry (`Diyalo@IoT`). If the client changed their phone or the app was reinstalled, access to MQTT settings was permanently lost with no recovery path.

### Changes — `index.html`

**Removed:**
- `sheet-pin` bottom sheet (Installer Access PIN entry UI)
- All PIN-related CSS: `.pin-icon-wrap`, `.pin-icon-circle`, `.pin-input-wrap`, `.pin-eye-btn`, `.pin-error`, `.send-result`
- `const INSTALLER_PASS = 'Diyalo@IoT'`
- Variables: `configUnlocked`, `appVersionTapCount`, `appVersionTapTimer`, `pinEyeVisible`
- Functions: `requestConfigAccess()`, `submitPin()`, `togglePinEye()`, `handleAppVersionTap()`
- `pin-input` Enter keypress listener from `init()`
- `onclick="handleAppVersionTap(event)"` from the version row (version text kept, `cursor:default`)

**Added:**
- `openMqttSheet()` — directly calls `loadMqttConfig()` then `openSheet('sheet-mqtt')`
- **MQTT Config** row in the Connection settings section (lock icon, cyan accent)
- Both connection pill buttons (header + sidebar) changed from `onclick="requestConfigAccess()"` to `onclick="openMqttSheet()"`

---

## Session 2 — Reorder Settings Sections

### Problem
The Connection section appeared before the Data section in Settings, which felt illogical — users need to configure data behaviour before worrying about connectivity.

### Changes — `index.html`

- Merged two separate `settings-list` wrapper `<div>`s into one unified list
- New section order: **Display → Data → Connection → About**
- Desktop grid changed from `grid-template-columns: 1fr 1fr` to `grid-template-columns: 1fr; max-width: 600px` so all sections flow in a single consistent column on all screen sizes

---

## Session 3 — History Select & Delete Feature

### Problem
The Report tab had no way to delete old daily reports from local history. All 30 stored reports accumulated with no management UI.

### Changes — `index.html`

**HTML added:**
- Select toggle button in the history section header (`id="history-select-toggle"`)
- Toolbar below the header (`id="history-toolbar"`) showing selected count, All/None toggle, and a red Delete button (`id="history-delete-btn"`)

**CSS added:**
- `.history-item.selected` — cyan highlight for selected rows
- `.history-checkbox` — custom checkbox with cyan fill and checkmark
- `.history-toolbar` — flex bar, hidden by default; `.show` makes it visible
- `.history-toolbar-btn` — base button style; `.danger` variant for Delete
- `.history-select-btn` — Select button; `.active` turns it cyan

**JS added/modified:**
- `historySelectMode` and `historySelected` (Set) state variables
- `renderReport(r)` — now delegates to `renderHistoryList()` instead of inline rendering
- `renderHistoryList()` — standalone function; renders normal clickable rows or checkbox rows depending on `historySelectMode`
- `toggleHistorySelectMode()` — toggles mode, clears selection, updates button label
- `toggleHistoryItem(idx, dateKey)` — adds/removes from `historySelected`
- `selectAllHistory()` — selects all or clears all
- `updateHistoryToolbar()` — updates count, delete button state, All/None label
- `deleteSelectedHistory()` — filters `reportHistory`, saves to localStorage, reloads first remaining report or hides report panel if empty

---

## Session 4 — Fix History Visibility Bug

### Problem
The history section (including Select/Delete controls) was nested inside `#report-content`, which has class `hidden` until a report loads. Users visiting the Report tab without an active MQTT session never saw their stored history.

### Changes — `index.html`

1. History section moved outside `#report-content` — now a direct child of `#panel-report`, always visible
2. `switchTab()` — added `renderHistoryList()` call when switching to the `'report'` tab
3. `init()` — added `else renderHistoryList()` branch so history renders on startup even when no report has loaded yet

---

## Session 5 — Daily Report: Peak Power, Voltage Quality Durations, Average Voltage Fix

### Bug 1 — Peak Power always showed `0W` *(firmware + dashboard)*

**Root cause (firmware):** `publishDailyReport()` never tracked or published a `peak_w` field. No `dayPeakW` variable existed anywhere in the firmware.  
**Root cause (dashboard):** `renderReport()` read `r.peak_w || 0` — a missing key evaluates as falsy so a genuine `0` would also show as `0`, but more importantly the field was simply never present.

**Fix (firmware):**
- Added `float dayPeakW = 0.0f` accumulator
- In `accumulateDaily()`: each loop computes `totalW = v × (i1 + i2)` and updates `dayPeakW` if it is a new maximum
- `dayPeakW` saved/restored in the NVS checkpoint (`"peakw"` key)
- Published as `"peak_w"` in the daily report JSON

**Fix (dashboard):**
- Changed `r.peak_w || 0` to `r.peak_w != null ? r.peak_w : 0` so a genuine zero value is not masked
- Renamed stat card label from "Peak W" to "Peak Power" for clarity

---

### Bug 2 — Average voltage included mains-loss and under/over-voltage readings *(firmware)*

**Root cause:** `accumulateDaily()` guarded voltage averaging with only `if (v > 10.0f)`, so readings at 50 V (mains loss), 150 V (under voltage), and 260 V (over voltage) were all added to `dayVSum`, dragging the reported average away from true steady-state mains quality.

**Fix (firmware):**
- `dayVSum` and `dayVSamples` now only accumulate when `voltageStatus == V_NORMAL` (180–240 V)
- `dayMinV` / `dayMaxV` also restricted to `V_NORMAL` for the same reason

**Fix (dashboard):**
- Stat card label updated to **"Avg V (Normal)"** to make the restriction explicit to the user

---

### Bug 3 — Voltage quality durations completely absent *(firmware + dashboard)*

**Root cause:** The firmware tracked four voltage states (`V_NORMAL`, `V_UNDER_VOLTAGE`, `V_OVER_VOLTAGE`, `V_MAINS_LOSS`) but accumulated no duration for any of them. The daily report had no concept of how long mains was lost or voltage was abnormal.

**Fix (firmware):**
- Added four `unsigned long` duration accumulators: `dayVNormalS`, `dayVUnderS`, `dayVOverS`, `dayVLossS`
- Added `dayLastVStatus` and `dayVStatusStartMs` to track the current segment start
- `accumulateDaily()` detects state changes and flushes elapsed seconds into the correct bucket
- Before publishing, the current open segment is flushed so no time is lost
- All four values saved/restored in the NVS checkpoint
- Published in the daily report JSON under `voltage.normal_s`, `voltage.under_s`, `voltage.over_s`, `voltage.loss_s`

**Fix (dashboard):**
- Added **Voltage Quality** section with a colour-coded proportional bar (green = normal, amber = under, red = over, grey = loss)
- Each state shows duration (`fmtDuration`) and percentage of the day
- Added **Mains Loss** stat card in the Overview row; turns amber when `loss_s > 0`
- Added **Min V** and **Max V** stat cards to the Overview row

---

### Bug 4 — kWh accumulated during mains loss *(firmware)*

**Root cause:** `accumulateDaily()` ran `dayP1kWh += v × i × dt` unconditionally. During a true mains loss the ADC readings are noise rather than real measurements.

**Fix (firmware):**
- kWh accumulation and peak power tracking now only run when `voltageStatus != V_MAINS_LOSS`
- Under-voltage (160–240 V) and over-voltage (>240 V) still accumulate — the load is genuinely consuming energy at those voltages

---

## Session 6 — Pending Report: Retry on MQTT Reconnect

### Problem
If MQTT was disconnected at midnight when `checkMidnight()` fired, the completed day's report was silently discarded. The accumulators were reset and the data was permanently lost — no retry, no local save, no warning.

### Changes — `power_monitor_with_ble_provisioning.ino`

**Added NVS namespace `"pmpend"`** — stores a single pending report as two string keys: `"topic"` and `"payload"`.

**Added `savePendingReport(topic, payload)`:**
- Writes the full JSON payload and its dated topic string to `"pmpend"` NVS
- Shows an LCD message: `Report Saved! / Retry on reconn.`

**Added `tryPublishPendingReport()`:**
- Called automatically after every successful MQTT (re)connect
- Reads `"pmpend"` from NVS; if present, publishes to both `energy/daily/YYYY-MM-DD` (retained) and `energy/daily/latest` (retained)
- On success: clears `"pmpend"` and shows `Pending Report / Published OK!` on LCD
- On failure: leaves `"pmpend"` intact and retries on the next reconnect

**Modified missed-midnight path in `checkMidnight()`:**
- Builds the complete report payload (same format as `publishDailyReport()`) with `generated_at: "offline"`
- Calls `savePendingReport()` instead of dropping the data
- Still resets all day accumulators so the new day starts clean

**Modified `handleMQTT()`:**
- Calls `tryPublishPendingReport()` after every successful reconnect

**Modified `setup()`:**
- Calls `tryPublishPendingReport()` after the initial successful MQTT connect — catches the case where the device rebooted after a missed midnight

> **Known limitation:** Only one pending report is stored at a time. If MQTT is offline for two consecutive midnights the second night's data overwrites the first. In practice the WiFi watchdog performs a hard reset after 5 minutes offline, making this scenario unlikely.

### Changes — `index.html`

**`renderReport()`:**
- `report-gen` now displays the actual `generated_at` timestamp from the report JSON rather than always showing the current time
- When `generated_at === "offline"`, shows `⚠ Delivered late — MQTT was offline at midnight` in amber

**`renderHistoryList()`:**
- History list items with `generated_at === "offline"` display a small `⚠ late` amber badge next to the date

**`handleDailyReport()`:**
- Event log entry appends `· ⚠ delivered late` when the received report has `generated_at === "offline"`

---

## Accumulator Reference (firmware)

| Variable | Type | Description |
|---|---|---|
| `dayP1kWh` | `float` | CT1 energy accumulated today (kWh) |
| `dayP2kWh` | `float` | CT2 energy accumulated today (kWh) |
| `dayPeakW` | `float` | Peak instantaneous total power today (W) |
| `dayMinV` | `float` | Minimum voltage during V_NORMAL periods |
| `dayMaxV` | `float` | Maximum voltage during V_NORMAL periods |
| `dayVSum` | `float` | Sum of voltage samples during V_NORMAL (for avg) |
| `dayVSamples` | `int` | Count of V_NORMAL voltage samples |
| `dayVNormalS` | `unsigned long` | Seconds in V_NORMAL today |
| `dayVUnderS` | `unsigned long` | Seconds in V_UNDER_VOLTAGE today |
| `dayVOverS` | `unsigned long` | Seconds in V_OVER_VOLTAGE today |
| `dayVLossS` | `unsigned long` | Seconds in V_MAINS_LOSS today |

## Voltage Accumulation Rules

| Condition | Range | kWh | Peak W | Min/Max/Avg V |
|---|---|---|---|---|
| `V_MAINS_LOSS` | < 160 V | ❌ | ❌ | ❌ |
| `V_UNDER_VOLTAGE` | 160–180 V | ✅ | ✅ | ❌ |
| `V_NORMAL` | 180–240 V | ✅ | ✅ | ✅ |
| `V_OVER_VOLTAGE` | > 240 V | ✅ | ✅ | ❌ |

## Daily Report JSON Schema (current)

```json
{
  "report_date": "2026-03-12",
  "generated_at": "2026-03-13 00:00:04",
  "voltage": {
    "min": 214.3,
    "max": 238.1,
    "avg": 226.4,
    "normal_s": 82440,
    "under_s": 1200,
    "over_s": 0,
    "loss_s": 2760
  },
  "energy": {
    "ct1_kWh": 3.2410,
    "ct2_kWh": 1.8820,
    "total_kWh": 5.1230
  },
  "peak_w": 4180.0,
  "ct1": {
    "name": "Main Motor",
    "run_s": 28800,
    "idle_s": 14400,
    "off_s": 43200,
    "off_thr": 0.50,
    "idle_thr": 2.00,
    "max_thr": 15.00
  },
  "ct2": {
    "name": "Saw Machine",
    "run_s": 18000,
    "idle_s": 7200,
    "off_s": 61200,
    "off_thr": 0.50,
    "idle_thr": 2.00,
    "max_thr": 15.00
  }
}
```
