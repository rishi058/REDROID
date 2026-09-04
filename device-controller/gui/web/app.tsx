import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react"
import {
  ActivityIcon,
  BookOpenIcon,
  GripIcon,
  MenuIcon,
  MoonIcon,
  PlugIcon,
  SmartphoneIcon,
  SunIcon,
  UnplugIcon,
} from "lucide-react"
import {
  BitmapVideoFrameRenderer,
  WebCodecsVideoDecoder,
} from "@yume-chan/scrcpy-decoder-webcodecs"
import {
  ScrcpyVideoCodecId,
  type ScrcpyMediaStreamPacket,
} from "@yume-chan/scrcpy"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Separator } from "@/components/ui/separator"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet"
import { Spinner } from "@/components/ui/spinner"
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

const PHONE_ASPECT_RATIO = 9 / 16
const MIN_PHONE_WIDTH = 220
const MAX_PHONE_WIDTH = 720
const DEFAULT_PHONE_WIDTH = 380
const PHONE_WIDTH_STEP = 24

type ConnectionState = "idle" | "connecting" | "connected" | "error"

type GuiSession = {
  id: string
  websocket_path: string
}

type ApiError = {
  error?: {
    code?: string
    message?: string
  }
}

function viewportMaximum(): number {
  if (typeof window === "undefined") return DEFAULT_PHONE_WIDTH
  const widthLimit = window.innerWidth - 32
  // Reserve the fixed header, main padding, bezel, and resize handle so the
  // complete phone remains visible without introducing a page scrollbar.
  const heightLimit = (window.innerHeight - 96) * PHONE_ASPECT_RATIO
  return Math.max(MIN_PHONE_WIDTH, Math.min(MAX_PHONE_WIDTH, widthLimit, heightLimit))
}

function clampPhoneWidth(width: number): number {
  return Math.round(Math.max(MIN_PHONE_WIDTH, Math.min(viewportMaximum(), width)))
}

function AppHeader({
  connectionState,
  dark,
  onThemeToggle,
  onDisconnect,
}: {
  connectionState: ConnectionState
  dark: boolean
  onThemeToggle: () => void
  onDisconnect: () => void
}) {
  const connected = connectionState === "connected"
  const statusLabel = connected
    ? "Live"
    : connectionState === "connecting"
      ? "Connecting"
      : "Offline"

  const links = (
    <>
      <Button variant="ghost" asChild>
        <a href="/docs" target="_blank" rel="noreferrer">
          <BookOpenIcon data-icon="inline-start" />
          API docs
        </a>
      </Button>
      <Button variant="ghost" asChild>
        <a href="/healthz" target="_blank" rel="noreferrer">
          <ActivityIcon data-icon="inline-start" />
          Health
        </a>
      </Button>
    </>
  )

  return (
    <header className="sticky top-0 border-b bg-background/90 backdrop-blur-xl">
      <div className="mx-auto flex h-14 max-w-7xl items-center gap-3 px-4 sm:px-6">
        <div className="flex min-w-0 items-center gap-3">
          <div className="flex size-8 shrink-0 items-center justify-center rounded-lg border bg-card shadow-sm">
            <SmartphoneIcon aria-hidden="true" />
          </div>
          <div className="min-w-0 leading-tight">
            <p className="truncate text-sm font-semibold">ReDroid Control</p>
            <p className="hidden truncate text-xs text-muted-foreground sm:block">
              Android 14 · Local WSL
            </p>
          </div>
        </div>

        <Badge variant={connected ? "default" : "secondary"} className="ml-auto hidden sm:inline-flex">
          <span className="size-1.5 rounded-full bg-current" aria-hidden="true" />
          {statusLabel}
        </Badge>

        <nav className="hidden items-center gap-1 md:flex" aria-label="Primary navigation">
          {links}
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                aria-label={dark ? "Use light theme" : "Use dark theme"}
                onClick={onThemeToggle}
              >
                {dark ? <SunIcon /> : <MoonIcon />}
              </Button>
            </TooltipTrigger>
            <TooltipContent>{dark ? "Light theme" : "Dark theme"}</TooltipContent>
          </Tooltip>
          {connected && (
            <Tooltip>
              <TooltipTrigger asChild>
                <Button variant="ghost" size="icon" aria-label="Disconnect device" onClick={onDisconnect}>
                  <UnplugIcon />
                </Button>
              </TooltipTrigger>
              <TooltipContent>Disconnect</TooltipContent>
            </Tooltip>
          )}
        </nav>

        <Sheet>
          <SheetTrigger asChild>
            <Button variant="outline" size="icon" className="md:hidden" aria-label="Open navigation">
              <MenuIcon />
            </Button>
          </SheetTrigger>
          <SheetContent side="right">
            <SheetHeader>
              <SheetTitle>ReDroid Control</SheetTitle>
              <SheetDescription>Device navigation and appearance</SheetDescription>
            </SheetHeader>
            <Separator />
            <nav className="flex flex-col gap-2 px-4" aria-label="Mobile navigation">
              {links}
              <Button variant="ghost" className="justify-start" onClick={onThemeToggle}>
                {dark ? <SunIcon data-icon="inline-start" /> : <MoonIcon data-icon="inline-start" />}
                {dark ? "Light theme" : "Dark theme"}
              </Button>
              {connected && (
                <Button variant="ghost" className="justify-start" onClick={onDisconnect}>
                  <UnplugIcon data-icon="inline-start" />
                  Disconnect
                </Button>
              )}
            </nav>
          </SheetContent>
        </Sheet>
      </div>
    </header>
  )
}

function App() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const websocketRef = useRef<WebSocket | undefined>(undefined)
  const decoderRef = useRef<WebCodecsVideoDecoder | undefined>(undefined)
  const decoderWriterRef = useRef<WritableStreamDefaultWriter<ScrcpyMediaStreamPacket> | undefined>(undefined)
  const sessionRef = useRef<GuiSession | undefined>(undefined)
  const apiKeyRef = useRef("")
  const resizeStartRef = useRef<{ x: number; y: number; width: number } | undefined>(undefined)
  const lastPointerMoveRef = useRef(0)

  const [apiKey, setApiKey] = useState("")
  const [connectionState, setConnectionState] = useState<ConnectionState>("idle")
  const [status, setStatus] = useState("Ready to connect")
  const [takeoverAvailable, setTakeoverAvailable] = useState(false)
  const [phoneWidth, setPhoneWidth] = useState(() => clampPhoneWidth(DEFAULT_PHONE_WIDTH))
  const [dark, setDark] = useState(() => localStorage.getItem("redroid-theme") !== "light")

  useEffect(() => {
    document.documentElement.classList.toggle("dark", dark)
    localStorage.setItem("redroid-theme", dark ? "dark" : "light")
  }, [dark])

  useEffect(() => {
    const clampToViewport = () => setPhoneWidth((width) => clampPhoneWidth(width))
    window.addEventListener("resize", clampToViewport)
    return () => window.removeEventListener("resize", clampToViewport)
  }, [])

  useEffect(() => {
    return () => {
      websocketRef.current?.close()
      decoderWriterRef.current?.releaseLock()
      decoderRef.current?.dispose()
    }
  }, [])

  const ensureDecoder = useCallback(() => {
    if (decoderWriterRef.current) return
    if (!("VideoDecoder" in window)) {
      throw new Error("This browser does not support WebCodecs VideoDecoder")
    }
    const canvas = canvasRef.current
    if (!canvas) throw new Error("Android display is unavailable")
    const decoder = new WebCodecsVideoDecoder({
      codec: ScrcpyVideoCodecId.H264,
      renderer: new BitmapVideoFrameRenderer(canvas),
    })
    decoderRef.current = decoder
    decoderWriterRef.current = decoder.writable.getWriter()
  }, [])

  const requestHeaders = useCallback(() => {
    const headers: Record<string, string> = { "content-type": "application/json" }
    if (apiKeyRef.current) headers["x-api-key"] = apiKeyRef.current
    return headers
  }, [])

  const disconnect = useCallback(async () => {
    const session = sessionRef.current
    sessionRef.current = undefined
    websocketRef.current?.close()
    websocketRef.current = undefined
    if (session) {
      await fetch(`/v1/gui/sessions/${session.id}`, {
        method: "DELETE",
        headers: requestHeaders(),
        credentials: "same-origin",
      }).catch(() => undefined)
    }
    setConnectionState("idle")
    setStatus("Disconnected")
  }, [requestHeaders])

  const createSession = useCallback(async (forceTakeover = false) => {
    setConnectionState("connecting")
    setStatus(forceTakeover ? "Taking control…" : "Starting secure stream…")
    setTakeoverAvailable(false)
    apiKeyRef.current = apiKey

    try {
      ensureDecoder()
      const endpoint = forceTakeover
        ? "/v1/gui/controller/takeover"
        : "/v1/gui/sessions"
      const response = await fetch(endpoint, {
        method: "POST",
        headers: requestHeaders(),
        credentials: "same-origin",
        body: JSON.stringify({
          role: "controller",
          codec: "h264",
          webcodecs: "VideoDecoder" in window,
        }),
      })
      if (!response.ok) {
        const body = await response.json() as ApiError
        if (response.status === 409 && body.error?.code === "gui_lease_unavailable") {
          setTakeoverAvailable(true)
        }
        throw new Error(body.error?.message ?? "Could not create GUI session")
      }

      const session = await response.json() as GuiSession
      sessionRef.current = session
      const socket = new WebSocket(
        `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${session.websocket_path}`
      )
      websocketRef.current = socket
      socket.binaryType = "arraybuffer"
      socket.onopen = () => {
        setPhoneWidth(viewportMaximum())
        setConnectionState("connected")
        setStatus("Live control session")
      }
      socket.onclose = () => {
        websocketRef.current = undefined
        setConnectionState("idle")
        setStatus("Connection closed")
      }
      socket.onerror = () => {
        setConnectionState("error")
        setStatus("WebSocket connection failed")
      }
      socket.onmessage = ({ data }) => {
        const writer = decoderWriterRef.current
        if (!(data instanceof ArrayBuffer) || data.byteLength < 10 || !writer) return
        const bytes = new Uint8Array(data)
        const flags = bytes[0] ?? 0
        const packet: ScrcpyMediaStreamPacket = flags & 2
          ? { type: "configuration", data: bytes.subarray(9) }
          : {
              type: "data",
              keyframe: Boolean(flags & 1),
              pts: new DataView(data).getBigUint64(1),
              data: bytes.subarray(9),
            }
        void writer.write(packet).catch((error: Error) => {
          setConnectionState("error")
          setStatus(`Decoder error: ${error.message}`)
        })
      }
    } catch (error) {
      setConnectionState("error")
      setStatus(error instanceof Error ? error.message : "GUI initialization failed")
    }
  }, [apiKey, ensureDecoder, requestHeaders])

  const send = useCallback((event: object) => {
    if (websocketRef.current?.readyState === WebSocket.OPEN) {
      websocketRef.current.send(JSON.stringify(event))
    }
  }, [])

  const sendPointer = useCallback((
    event: ReactPointerEvent<HTMLCanvasElement>,
    action: "down" | "move" | "up"
  ) => {
    if (connectionState !== "connected") return
    const canvas = event.currentTarget
    const bounds = canvas.getBoundingClientRect()
    send({
      type: "touch",
      action,
      x: Math.round((event.clientX - bounds.left) * canvas.width / bounds.width),
      y: Math.round((event.clientY - bounds.top) * canvas.height / bounds.height),
      pointer_id: event.pointerId,
      screen_width: canvas.width,
      screen_height: canvas.height,
    })
  }, [connectionState, send])

  useEffect(() => {
    const androidKeyCode = (event: KeyboardEvent): number | undefined => {
      const fixed: Record<string, number> = {
        Escape: 4,
        Home: 3,
        Backspace: 67,
        Enter: 66,
        ArrowUp: 19,
        ArrowDown: 20,
        ArrowLeft: 21,
        ArrowRight: 22,
        Tab: 61,
        Space: 62,
        Delete: 112,
      }
      if (event.key in fixed) return fixed[event.key]
      if (/^Key[A-Z]$/.test(event.code)) return 29 + event.code.charCodeAt(3) - 65
      if (/^Digit[0-9]$/.test(event.code)) return 7 + Number(event.code.slice(5))
      return undefined
    }
    const key = (event: KeyboardEvent, action: "down" | "up") => {
      const keycode = androidKeyCode(event)
      if (connectionState !== "connected" || keycode === undefined || (action === "down" && event.repeat)) return
      event.preventDefault()
      send({ type: "key", action, keycode })
    }
    const keyDown = (event: KeyboardEvent) => key(event, "down")
    const keyUp = (event: KeyboardEvent) => key(event, "up")
    window.addEventListener("keydown", keyDown)
    window.addEventListener("keyup", keyUp)
    return () => {
      window.removeEventListener("keydown", keyDown)
      window.removeEventListener("keyup", keyUp)
    }
  }, [connectionState, send])

  const resizeFromHandle = (event: ReactPointerEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.currentTarget.setPointerCapture(event.pointerId)
    resizeStartRef.current = { x: event.clientX, y: event.clientY, width: phoneWidth }
  }

  const resizePhone = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const start = resizeStartRef.current
    if (!start || !event.currentTarget.hasPointerCapture(event.pointerId)) return
    const horizontal = event.clientX - start.x
    const vertical = (event.clientY - start.y) * PHONE_ASPECT_RATIO
    setPhoneWidth(clampPhoneWidth(start.width + Math.max(horizontal, vertical)))
  }

  const stopResize = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    resizeStartRef.current = undefined
  }

  const resizeWithKeyboard = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "ArrowUp" || event.key === "ArrowRight") {
      event.preventDefault()
      setPhoneWidth((width) => clampPhoneWidth(width + PHONE_WIDTH_STEP))
    } else if (event.key === "ArrowDown" || event.key === "ArrowLeft") {
      event.preventDefault()
      setPhoneWidth((width) => clampPhoneWidth(width - PHONE_WIDTH_STEP))
    } else if (event.key === "Home") {
      event.preventDefault()
      setPhoneWidth(MIN_PHONE_WIDTH)
    } else if (event.key === "End") {
      event.preventDefault()
      setPhoneWidth(viewportMaximum())
    }
  }

  return (
    <TooltipProvider>
      <div className="min-h-dvh bg-background text-foreground">
        <AppHeader
          connectionState={connectionState}
          dark={dark}
          onThemeToggle={() => setDark((value) => !value)}
          onDisconnect={() => void disconnect()}
        />

        <main className="relative mx-auto flex h-[calc(100dvh-3.5rem)] max-w-7xl items-center justify-center overflow-hidden px-4 py-1 sm:px-6">
          {connectionState !== "connected" && (
            <section className="w-full max-w-md rounded-2xl border bg-card/85 p-5 shadow-xl backdrop-blur" aria-label="Connect to device">
              <div className="mb-5 flex items-center gap-3">
                <div className="flex size-10 items-center justify-center rounded-xl border bg-muted">
                  <SmartphoneIcon aria-hidden="true" />
                </div>
                <div>
                  <h1 className="font-heading text-base font-semibold">Connect to ReDroid</h1>
                  <p className="text-sm text-muted-foreground">Open a secure interactive session</p>
                </div>
              </div>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="api-key">API key</FieldLabel>
                  <Input
                    id="api-key"
                    type="password"
                    autoComplete="off"
                    placeholder="Optional while local auth is disabled"
                    value={apiKey}
                    onChange={(event) => setApiKey(event.target.value)}
                    disabled={connectionState === "connecting"}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") void createSession(false)
                    }}
                  />
                </Field>
                <Button className="w-full" onClick={() => void createSession(false)} disabled={connectionState === "connecting"}>
                  {connectionState === "connecting" ? <Spinner data-icon="inline-start" /> : <PlugIcon data-icon="inline-start" />}
                  Connect
                </Button>
                {takeoverAvailable && (
                  <Button className="w-full" variant="destructive" onClick={() => void createSession(true)}>
                    Disconnect existing controller and use here
                  </Button>
                )}
              </FieldGroup>
              <p className="mt-4 text-center text-sm text-muted-foreground" role="status" aria-live="polite">
                {status}
              </p>
            </section>
          )}

          <section
            className={cn(
              "relative size-full items-center justify-center",
              connectionState === "connected" ? "flex" : "hidden"
            )}
            aria-label="Android device"
          >
            <div
              className="phone-frame relative rounded-[2.35rem] border bg-card p-1.5 shadow-2xl"
              style={{ width: phoneWidth }}
            >
              <div className="pointer-events-none absolute top-2 left-1/2 z-10 h-1.5 w-12 -translate-x-1/2 rounded-full bg-foreground/25" />
              <div className="aspect-[9/16] w-full overflow-hidden rounded-[2rem] bg-black">
                <canvas
                  ref={canvasRef}
                  width={720}
                  height={1280}
                  aria-label="Interactive Android screen"
                  className="block size-full touch-none select-none"
                  onContextMenu={(event) => event.preventDefault()}
                  onPointerDown={(event) => {
                    event.currentTarget.setPointerCapture(event.pointerId)
                    sendPointer(event, "down")
                  }}
                  onPointerMove={(event) => {
                    const now = performance.now()
                    if (event.buttons && now - lastPointerMoveRef.current >= 33) {
                      lastPointerMoveRef.current = now
                      sendPointer(event, "move")
                    }
                  }}
                  onPointerUp={(event) => sendPointer(event, "up")}
                  onPointerCancel={(event) => sendPointer(event, "up")}
                />
              </div>
              <button
                type="button"
                aria-label="Resize phone"
                role="slider"
                aria-orientation="vertical"
                aria-valuemin={MIN_PHONE_WIDTH}
                aria-valuemax={Math.round(viewportMaximum())}
                aria-valuenow={phoneWidth}
                className="absolute -right-3 -bottom-3 flex size-9 touch-none items-end justify-end rounded-full border bg-background p-1.5 text-muted-foreground shadow-lg outline-none hover:text-foreground focus-visible:ring-3 focus-visible:ring-ring/50"
                onPointerDown={resizeFromHandle}
                onPointerMove={resizePhone}
                onPointerUp={stopResize}
                onPointerCancel={stopResize}
                onKeyDown={resizeWithKeyboard}
              >
                <GripIcon aria-hidden="true" />
              </button>
            </div>
          </section>
          <p className="sr-only" role="status" aria-live="polite">{status}</p>
        </main>
      </div>
    </TooltipProvider>
  )
}

export { App }
