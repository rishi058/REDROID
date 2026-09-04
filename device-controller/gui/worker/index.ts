/**
 * Stdio-only boundary for FastAPI. This process intentionally never starts an
 * HTTP/TCP listener. The Tango adapter is isolated here so browser clients can
 * never receive an ADB transport.
 */
import { createReadStream } from "node:fs";
import { Readable } from "node:stream";
import { createInterface } from "node:readline";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { AdbServerClient } from "@yume-chan/adb";
import { AdbServerNodeTcpConnector } from "@yume-chan/adb-server-node-tcp";
import { AdbScrcpyClient, AdbScrcpyOptions3_3_3 } from "@yume-chan/adb-scrcpy";
import {
  AndroidKeyEventAction,
  AndroidMotionEventAction,
  AndroidMotionEventButton,
  ScrcpyPointerId,
  type AndroidKeyCode,
  type ScrcpyControlMessageWriter,
} from "@yume-chan/scrcpy";
import { verifyScrcpyServer } from "./scrcpy-server.js";

type Input =
  | { type: "touch"; action: "down" | "move" | "up"; x: number; y: number; pointer_id: number; screen_width: number; screen_height: number }
  | { type: "key"; action: "down" | "up"; keycode: number };
type Command = { method: "input"; event: Input };

function emit(event: object): void {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

let client: AdbScrcpyClient<AdbScrcpyOptions3_3_3<true>> | undefined;
let controller: ScrcpyControlMessageWriter | undefined;
let videoWidth = 720;
let videoHeight = 1280;
const androidWidth = Number(process.env.ANDROID_DISPLAY_WIDTH ?? "720");
const androidHeight = Number(process.env.ANDROID_DISPLAY_HEIGHT ?? "1280");
const touchInjectionMode = process.env.TOUCH_INJECTION_MODE ?? "adb";
const execFileAsync = promisify(execFile);

async function injectAdbTouch(event: Extract<Input, { type: "touch" }>): Promise<void> {
  const x = Math.max(0, Math.min(androidWidth - 1, Math.round(event.x * androidWidth / event.screen_width)));
  const y = Math.max(0, Math.min(androidHeight - 1, Math.round(event.y * androidHeight / event.screen_height)));
  await execFileAsync("adb", [
    "-s", process.env.DEFAULT_ADB_SERIAL ?? "redroid:5555",
    "shell", "input", "touchscreen", "-d", "0", "motionevent",
    event.action.toUpperCase(), String(x), String(y),
  ], { timeout: 2_000, maxBuffer: 8_192 });
}

async function sendInput(event: Input): Promise<void> {
  if (!controller) throw new Error("scrcpy control channel is not ready");
  if (event.type === "key") {
    await controller.injectKeyCode({
      action: event.action === "down" ? AndroidKeyEventAction.Down : AndroidKeyEventAction.Up,
      keyCode: event.keycode as AndroidKeyCode,
      repeat: 0,
      metaState: 0,
    });
    return;
  }
  // ReDroid's Android 14 DisplayManager mirror reports touch NONE and ignores
  // scrcpy positional events aimed at the mirror display. The Android input
  // command targets physical display 0 and preserves DOWN/MOVE/UP semantics.
  if (touchInjectionMode === "adb") {
    await injectAdbTouch(event);
    return;
  }
  const action = event.action === "down" ? AndroidMotionEventAction.Down
    : event.action === "move" ? AndroidMotionEventAction.Move : AndroidMotionEventAction.Up;
  await controller.injectTouch({
    action,
    pointerId: ScrcpyPointerId.Finger,
    pointerX: event.x,
    pointerY: event.y,
    videoWidth: event.screen_width,
    videoHeight: event.screen_height,
    pressure: event.action === "up" ? 0 : 1,
    actionButton: AndroidMotionEventButton.None,
    buttons: AndroidMotionEventButton.None,
  });
}

async function pumpVideo(): Promise<void> {
  if (!client) throw new Error("scrcpy client was not initialized");
  const video = await client.videoStream;
  videoWidth = video.width || videoWidth;
  videoHeight = video.height || videoHeight;
  emit({ event: "ready", codec: "h264", width: videoWidth, height: videoHeight });
  const reader = video.stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return;
      if (value.type === "configuration") {
        emit({ event: "configuration", data: Buffer.from(value.data).toString("base64") });
      } else {
        emit({
          event: "video",
          data: Buffer.from(value.data).toString("base64"),
          keyframe: value.keyframe === true,
          timestamp_us: value.pts?.toString() ?? "0",
        });
      }
    }
  } finally {
    reader.releaseLock();
  }
}

async function main(): Promise<void> {
  const serverPath = process.env.SCRCPY_SERVER_PATH ?? "/opt/scrcpy/scrcpy-server-v3.3.3";
  verifyScrcpyServer(serverPath);
  const adbServer = new AdbServerClient(new AdbServerNodeTcpConnector({
    host: process.env.ADB_SERVER_HOST ?? "127.0.0.1",
    port: Number(process.env.ADB_SERVER_PORT ?? "5037"),
  }));
  const adb = await adbServer.createAdb({ serial: process.env.DEFAULT_ADB_SERIAL ?? "redroid:5555" });
  const options = new AdbScrcpyOptions3_3_3({
    video: true, audio: false, control: true, videoCodec: "h264", maxSize: 720,
    maxFps: 24, videoBitRate: 4_000_000, sendFrameMeta: true, cleanup: true,
  });
  await AdbScrcpyClient.pushServer(adb, Readable.toWeb(createReadStream(serverPath)) as never);
  client = await AdbScrcpyClient.start(adb, "/data/local/tmp/scrcpy-server.jar", options);
  controller = client.controller;
  if (!controller) throw new Error("scrcpy did not create a control channel");
  await Promise.race([pumpVideo(), client.exited.then(() => { throw new Error("scrcpy server exited"); })]);
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let inputQueue = Promise.resolve();
input.on("line", (line) => {
  try {
    const message = JSON.parse(line) as Command;
    if (message.method !== "input") throw new Error("unsupported worker method");
    inputQueue = inputQueue.then(() => sendInput(message.event)).catch((error: unknown) => {
      emit({ event: "error", message: error instanceof Error ? error.message : "input failed" });
    });
  } catch {
    emit({ event: "error", message: "invalid worker command" });
  }
});
let stopping = false;
async function stop(exitCode: number): Promise<void> {
  if (stopping) return;
  stopping = true;
  input.close();
  process.stdin.pause();
  try {
    await client?.close();
  } finally {
    process.exitCode = exitCode;
  }
}

void main().then(
  () => stop(0),
  async (error: unknown) => {
    emit({ event: "error", message: error instanceof Error ? error.message : "worker initialization failed" });
    await stop(1);
  },
);

process.once("SIGTERM", () => { void stop(0); });
process.once("SIGINT", () => { void stop(0); });
