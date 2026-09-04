import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import { App } from "@/app"
import "@/index.css"

const root = document.querySelector("#root")

if (!root) {
  throw new Error("Application root is missing")
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>
)
