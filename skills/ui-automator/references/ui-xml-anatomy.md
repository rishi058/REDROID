# uiautomator Dump XML Anatomy

## File structure

```xml
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout"
        package="com.example" content-desc="" checkable="false" checked="false"
        clickable="false" enabled="true" focusable="false" focused="false"
        scrollable="false" long-clickable="false" password="false" selected="false"
        bounds="[0,0][720,1280]">
    <node ... />   <!-- nested children -->
  </node>
</hierarchy>
```

Single physical line (no pretty-printing) — always parse with regex or XML parser,
never with line-based tools.

## Node attributes that matter

| Attribute | Meaning | Automation use |
|---|---|---|
| `text` | Visible label (TextView/Button text, EditText content) | Primary tap/search target |
| `content-desc` | Accessibility label; **icons often have ONLY this** | Tap targets for icon buttons ("Show JSON response", "More options", Pass/Fail icons) |
| `resource-id` | e.g. `com.android.vending:id/0_resource_name_obfuscated` | Stable-ish selector; Play Store obfuscates them |
| `class` | Widget type: TextView, Button, ImageView, EditText... | Filter candidates |
| `bounds` | `[x1,y1][x2,y2]` top-left / bottom-right pixels | Tap center = `((x1+x2)/2, (y1+y2)/2)` |
| `clickable` | Whether tapping this node does anything | Prefer clickable nodes when a text node's parent is the row |
| `scrollable` | The container scrolls (swipe it, not the item) | Find scroll direction/extent |
| `enabled`, `selected`, `checked`, `password` | State flags | Verify UI state assertions |

## Coordinate system

- Origin = top-left of the display; y grows downward. Rotation appears in
  `<hierarchy rotation="N">` — dump again after rotating.
- Screen size from `wm size` (this project: `720x1280`).
- Status bar occupies roughly y=0–48; nav gestures the bottom ~56px. Rows near
  y>1224 may be cut off by the screen edge — scroll first.

## Common patterns

### Text visible but tap does nothing
The `text` node is often a child of a clickable parent row. Tapping the text's
center usually still works (touch delegates to parent) — but if not, find the
parent `<node>` whose bounds contain the child and are `clickable="true"`.

### Icon-only buttons
No `text`; look at `content-desc` ("Show JSON response") or match by
`resource-id` + `class="android.widget.ImageView"` + position (`list_top_nodes.py`
for header rows, typically y < 160).

### Bottom sheets / dialogs
Rendered as additional windows inside the same hierarchy after the sheet opens.
If a dump shows the underlying page only, the sheet didn't open — re-tap and wait.

### Lists that virtualize
Long lists render only visible rows; items below the fold don't exist in the
dump until you scroll. Swipe, re-dump, re-parse — never assume an item is absent
globally because it's absent in one dump.
