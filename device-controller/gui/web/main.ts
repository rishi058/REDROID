const screen = document.querySelector<HTMLCanvasElement>("#screen");
const statusLabel = document.querySelector<HTMLElement>("#status");
const apiKeyInput = document.querySelector<HTMLInputElement>("#api-key");
const connectButton = document.querySelector<HTMLButtonElement>("#connect");
const takeoverButton = document.querySelector<HTMLButtonElement>("#takeover");
if (!screen || !statusLabel || !apiKeyInput || !connectButton || !takeoverButton) throw new Error("GUI elements are missing");
const canvas: HTMLCanvasElement = screen;
const status: HTMLElement = statusLabel;
const apiKeyField: HTMLInputElement = apiKeyInput;
const takeover: HTMLButtonElement = takeoverButton;

import { WebCodecsVideoDecoder, BitmapVideoFrameRenderer } from "@yume-chan/scrcpy-decoder-webcodecs";
import { ScrcpyVideoCodecId, type ScrcpyMediaStreamPacket } from "@yume-chan/scrcpy";

let decoder: WebCodecsVideoDecoder | undefined;
let decoderWriter: WritableStreamDefaultWriter<ScrcpyMediaStreamPacket> | undefined;
let websocket: WebSocket | undefined;

function setStatus(value: string): void { status.textContent = value; }

function startDecoder(): void {
  if (decoderWriter) return;
  if (!("VideoDecoder" in window)) throw new Error("This browser does not support WebCodecs VideoDecoder");
  decoder = new WebCodecsVideoDecoder({ codec: ScrcpyVideoCodecId.H264, renderer: new BitmapVideoFrameRenderer(canvas) });
  decoderWriter = decoder.writable.getWriter();
}

function send(event: object): void { if (websocket?.readyState === WebSocket.OPEN) websocket.send(JSON.stringify(event)); }

async function createSession(forceTakeover = false): Promise<void> {
  const apiKey = apiKeyField.value;
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (apiKey) headers["x-api-key"] = apiKey;
  const endpoint = forceTakeover ? "/v1/gui/controller/takeover" : "/v1/gui/sessions";
  const response = await fetch(endpoint, {
    method: "POST", headers, credentials: "same-origin",
    body: JSON.stringify({ role: "controller", codec: "h264", webcodecs: "VideoDecoder" in window }),
  });
  if (!response.ok) {
    const error = await response.json() as { error?: { code?: string; message?: string } };
    if (response.status === 409 && error.error?.code === "gui_lease_unavailable") {
      takeover.hidden = false;
    }
    throw new Error(error.error?.message ?? "Could not create GUI session");
  }
  takeover.hidden = true;
  apiKeyField.value = "";
  const session = await response.json() as { websocket_path: string };
  websocket = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${session.websocket_path}`);
  websocket.binaryType = "arraybuffer";
  websocket.onopen = () => setStatus("Connected");
  websocket.onclose = () => setStatus("Disconnected");
  websocket.onmessage = ({ data }) => {
    const writer = decoderWriter;
    if (!(data instanceof ArrayBuffer) || data.byteLength < 10 || !writer) return;
    const bytes = new Uint8Array(data);
    const flags = bytes[0] ?? 0;
    const packet: ScrcpyMediaStreamPacket = (flags & 2)
      ? { type: "configuration", data: bytes.subarray(9) }
      : { type: "data", keyframe: Boolean(flags & 1), pts: new DataView(data).getBigUint64(1), data: bytes.subarray(9) };
    void writer.write(packet).catch((error: Error) => setStatus(`Decoder error: ${error.message}`));
  };
}

canvas.addEventListener("pointerdown", (event) => { canvas.setPointerCapture(event.pointerId); pointer(event, "down"); });
let lastPointerMove = 0;
canvas.addEventListener("pointermove", (event) => {
  const now = performance.now();
  if (event.buttons && now - lastPointerMove >= 33) {
    lastPointerMove = now;
    pointer(event, "move");
  }
});
canvas.addEventListener("pointerup", (event) => pointer(event, "up"));
function pointer(event: PointerEvent, action: "down" | "move" | "up"): void {
  const bounds = canvas.getBoundingClientRect();
  send({
    type: "touch",
    action,
    x: Math.round((event.clientX - bounds.left) * canvas.width / bounds.width),
    y: Math.round((event.clientY - bounds.top) * canvas.height / bounds.height),
    pointer_id: event.pointerId,
    screen_width: canvas.width,
    screen_height: canvas.height,
  });
}
function androidKeyCode(event: KeyboardEvent): number | undefined {
  const fixed: Record<string, number> = {
    Escape: 4, Home: 3, Backspace: 67, Enter: 66,
    ArrowUp: 19, ArrowDown: 20, ArrowLeft: 21, ArrowRight: 22,
    Tab: 61, Space: 62, Delete: 112,
  };
  if (event.key in fixed) return fixed[event.key];
  if (/^Key[A-Z]$/.test(event.code)) return 29 + event.code.charCodeAt(3) - 65;
  if (/^Digit[0-9]$/.test(event.code)) return 7 + Number(event.code.slice(5));
  return undefined;
}
window.addEventListener("keydown", (event) => {
  const keycode = androidKeyCode(event);
  if (!event.repeat && keycode !== undefined) {
    event.preventDefault();
    send({ type: "key", action: "down", keycode });
  }
});
window.addEventListener("keyup", (event) => {
  const keycode = androidKeyCode(event);
  if (keycode !== undefined) {
    event.preventDefault();
    send({ type: "key", action: "up", keycode });
  }
});

connectButton.addEventListener("click", () => {
  try { startDecoder(); void createSession().catch((error: unknown) => setStatus(error instanceof Error ? error.message : "GUI initialization failed")); }
  catch (error) { setStatus(error instanceof Error ? error.message : "GUI initialization failed"); }
});

takeover.addEventListener("click", () => {
  takeover.disabled = true;
  setStatus("Disconnecting the existing controller…");
  try {
    startDecoder();
    void createSession(true)
      .catch((error: unknown) => setStatus(error instanceof Error ? error.message : "GUI takeover failed"))
      .finally(() => { takeover.disabled = false; });
  } catch (error) {
    takeover.disabled = false;
    setStatus(error instanceof Error ? error.message : "GUI takeover failed");
  }
});
